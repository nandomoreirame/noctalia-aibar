local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")
local h = require("./support/service_helpers")
local entry = require("./support/entry")

local describe, it = runner.describe, runner.it
local creds = modules.load("lib/creds.luau")
local URL = "https://opencode.ai/zen/go/v1/usage"
local PATH = "~/.local/share/opencode/auth.json"
local AUTH = '{"opencode-go":{"type":"api","key":"SECRET-GO"}}'
local BODY = '{"usage":{"rolling":{"status":"ok","percent":12,"resetsAt":"2026-11-01T05:00:00Z"},"weekly":{"status":"ok","percent":24,"resetsAt":"2026-11-02T00:00:00Z"},"monthly":{"status":"rate-limited","percent":100,"resetsAt":"2026-11-30T00:00:00Z"}}}'
local opencode = modules.load("lib/opencode.luau")
local present = modules.load("lib/present.luau")
local DB = "~/.local/share/opencode/opencode.db"
local QUERY = "SELECT value FROM credential WHERE integration_id IN ('opencode', 'opencode-go') ORDER BY CASE integration_id WHEN 'opencode' THEN 0 ELSE 1 END, active DESC, time_created DESC, id DESC LIMIT 1"
local ARGV = "sqlite3 -readonly /mock/home/.local/share/opencode/opencode.db " .. QUERY
local OAUTH = '{"type":"oauth","access":"SECRET-ACCESS","refresh":"SECRET-REFRESH","expires":1891662400000,"metadata":{"orgID":"org-test","server":"https://opencode.ai/console"}}'

local function result(stdout, fields)
	local r = { exitCode = 0, stdout = stdout, stderr = "", timedOut = false, stdoutTruncated = false, stderrTruncated = false }
	for k, v in fields or {} do r[k] = v end
	return r
end

describe("OpenCode v2 SQLite session", function()
	it("reads the existing active OAuth session and sends its workspace and User-Agent", function()
		local s = h.boot({ config = { show_opencode = true }, fs = { [DB] = "database" }, commands = { "sqlite3" }, async = { [ARGV] = result(OAUTH) } })
		local ids = h.requests(s, URL)
		assert.equal(#ids, 1)
		if #ids == 0 then return end
		assert.equal(h.header(s, ids[1], "Authorization"), "Authorization: Bearer SECRET-ACCESS")
		assert.equal(h.header(s, ids[1], "x-org-id"), "x-org-id: org-test")
		assert.equal(h.header(s, ids[1], "User-Agent"), "User-Agent: opencode/2.2.1")
		mock.respond(s.env, ids[1], { status = 200, body = BODY })
		assert.equal(h.sourceOf(s, "opencode").snapshot.windows[1].percent, 12)
		for _, name in { "noctalia.log", "noctalia.writeFile", "noctalia.notify", "noctalia.runAsync" } do
			for _, call in mock.calls(s.env, name) do
				local text = if name == "noctalia.runAsync" then mock.json.encode(call[1]) else mock.json.encode(call)
				assert.equal(string.find(text, "SECRET", 1, true), nil)
			end
		end
		assert.equal(string.find(mock.json.encode(h.view(s)), "SECRET", 1, true), nil)
	end)

	it("does not refresh an expired session or use a stale legacy key instead", function()
		local expired = mock.json.decode(OAUTH)
		expired.expires = h.NOW - 1
		local s = h.boot({ config = { show_opencode = true }, fs = { [DB] = "database", [PATH] = AUTH }, commands = { "sqlite3" }, async = { [ARGV] = result(mock.json.encode(expired)) } })
		assert.equal(h.sourceOf(s, "opencode").error, "opencode-expired")
		assert.equal(#h.requests(s, URL), 0)
	end)

	it("reports missing sqlite3 and unreadable database output without HTTP", function()
		local missing = h.boot({ config = { show_opencode = true }, fs = { [DB] = "database" } })
		assert.equal(h.sourceOf(missing, "opencode").error, "opencode-sqlite")
		for _, response in { result("not json"), result(""), result(OAUTH, { exitCode = 1 }), result(OAUTH, { stdoutTruncated = true }), result(OAUTH, { timedOut = true }) } do
			local s = h.boot({ config = { show_opencode = true }, fs = { [DB] = "database" }, commands = { "sqlite3" }, async = { [ARGV] = response } })
			assert.equal(h.sourceOf(s, "opencode").error, "opencode-login")
			assert.equal(#h.requests(s, URL), 0)
		end
	end)

	it("rejects header injection in OAuth tokens and workspace metadata", function()
		for _, field in { "access", "orgID" } do
			local value = mock.json.decode(OAUTH)
			if field == "access" then value.access = "bad\r\nInjected: yes" else value.metadata.orgID = "bad\r\nInjected: yes" end
			local s = h.boot({ config = { show_opencode = true }, fs = { [DB] = "database" }, commands = { "sqlite3" }, async = { [ARGV] = result(mock.json.encode(value)) } })
			assert.equal(h.sourceOf(s, "opencode").error, "opencode-login")
			assert.equal(#h.requests(s, URL), 0)
		end
	end)
end)

describe("OpenCode quota parser and presentation", function()
	it("rejects incomplete, nonfinite and invalid windows", function()
		assert.equal(opencode.parseUsage(nil, h.NOW).ok, false)
		assert.equal(opencode.parseUsage({}, h.NOW).ok, false)
		for _, change in { { "percent", -1 }, { "percent", math.huge }, { "percent", 0/0 }, { "percent", "12" }, { "resetsAt", "invalid" }, { "status", "unknown" } } do
			local data = mock.json.decode(BODY)
			data.usage.rolling[change[1]] = change[2]
			assert.deepEqual(opencode.parseUsage(data, h.NOW), { ok = false, error = "parse" })
		end
	end)

	it("keeps zero usage and chooses the most consumed shared window for the bar", function()
		local data = mock.json.decode(BODY)
		data.usage.rolling.percent = 0
		local snapshot = opencode.parseUsage(data, h.NOW).snapshot
		assert.equal(snapshot.windows[1].percent, 0)
		local source = { key = "opencode", provider = "opencode", snapshot = snapshot, error = "" }
		local function tr(key) return key end
		local bar = present.bar({ now = h.NOW, barKey = "opencode", sources = { source } }, tr)
		assert.equal(bar.fraction, 1)
		assert.equal(bar.glyph, "code")
		assert.equal(present.card(source, h.NOW, tr).rows[3].label, "window.period-monthly")
	end)

	it("renders the Go panel with all three windows", function()
		local p = entry.load("panel.luau", {})
		p.env.noctalia.state.set("view", { now = h.NOW, barKey = "opencode", sources = {
			{ key = "opencode", provider = "opencode", snapshot = opencode.parseUsage(mock.json.decode(BODY), h.NOW).snapshot, error = "" },
		} })
		p.call("onOpen")
		local calls = mock.calls(p.env, "panel.render")
		local labels = {}
		local function walk(node)
			if node.props and node.props.text then labels[node.props.text] = true end
			for _, child in node.children or {} do walk(child) end
		end
		walk(calls[#calls][1])
		for _, label in { "provider.opencode", "window.session", "window.weekly", "window.period-monthly", "12%", "24%", "100%" } do
			assert.equal(labels[label], true)
		end
	end)
end)

describe("OpenCode credentials", function()
	it("reads only the Go API entry and rejects malformed headers", function()
		assert.equal(typeof(creds.opencodeKey), "function")
		if typeof(creds.opencodeKey) ~= "function" then return end
		assert.deepEqual(creds.opencodeKey(mock.json.decode(AUTH)), { ok = true, key = "SECRET-GO" })
		for _, data in { {}, { opencode = { type = "api", key = "zen" } }, { ["opencode-go"] = { type = "oauth", key = "wrong" } }, { ["opencode-go"] = { type = "api", key = "bad\r\nHeader: value" } } } do
			assert.deepEqual(creds.opencodeKey(data), { ok = false, error = "opencode-login" })
		end
	end)
end)

describe("service OpenCode", function()
	it("reads Go credentials and publishes all three shared windows without secrets", function()
		local s = h.boot({ config = { show_opencode = true, bar_provider = "opencode" }, fs = { [PATH] = AUTH } })
		local ids = h.requests(s, URL)
		assert.equal(#ids, 1)
		if #ids == 0 then return end
		local i = ids[1]
		assert.equal(h.header(s, i, "Authorization"), "Authorization: Bearer SECRET-GO")
		assert.equal(mock.pendingHttp(s.env)[i].request.method, "GET")
		mock.respond(s.env, i, { status = 200, body = BODY })
		local source = h.sourceOf(s, "opencode")
		assert.equal(source.error, "")
		assert.equal(h.view(s).barKey, "opencode")
		assert.equal(#source.snapshot.windows, 3)
		assert.equal(source.snapshot.windows[1].id, "session")
		assert.equal(source.snapshot.windows[1].percent, 12)
		assert.equal(source.snapshot.windows[1].endMs, 1793509200000)
		assert.equal(source.snapshot.windows[3].id, "period")
		assert.equal(source.snapshot.windows[3].periodType, "monthly")
		assert.equal(source.snapshot.windows[3].startMs, nil) -- no invented billing anchor
		assert.equal(source.snapshot.primary, "max")
		assert.deepEqual(source.snapshot.products, {}) -- endpoint has no model breakdown
		assert.equal(string.find(mock.json.encode(h.view(s)), "SECRET", 1, true), nil)
		for _, call in mock.calls(s.env, "noctalia.writeFile") do
			assert.equal(string.find(call[2], "SECRET", 1, true), nil)
		end
	end)

	it("shows a missing login and obeys the visibility setting", function()
		local s = h.boot({ config = { show_opencode = true } })
		local source = h.sourceOf(s, "opencode")
		assert.equal(source ~= nil, true)
		if source then assert.equal(source.error, "opencode-login") end
		assert.equal(#h.requests(s, URL), 0)
		local hidden = h.boot({ config = { show_opencode = false }, fs = { [PATH] = AUTH } })
		assert.equal(h.sourceOf(hidden, "opencode"), nil)
		assert.equal(#h.requests(hidden, URL), 0)
	end)

	it("preserves cached usage after authentication and malformed response failures", function()
		for _, response in { { status = 401, body = "" }, { status = 403, body = "" }, { status = 200, body = '{"usage":{"rolling":{"percent":"12"}}}' } } do
			local s = h.boot({ config = { show_opencode = true }, fs = { [PATH] = AUTH } })
			local ids = h.requests(s, URL)
			assert.equal(#ids, 1)
			if #ids == 0 then continue end
			mock.respond(s.env, ids[1], { status = 200, body = BODY })
			s.env.noctalia.state.set("cmd.refresh", 1)
			local requests = h.requests(s, URL)
			mock.respond(s.env, requests[#requests], response)
			local source = h.sourceOf(s, "opencode")
			assert.equal(source.stale, true)
			assert.equal(source.snapshot.windows[1].percent, 12)
			assert.equal(source.error, if response.status == 200 then "parse" else "auth")
		end
	end)
end)
