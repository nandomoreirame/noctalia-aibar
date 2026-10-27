local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")
local h = require("./support/service_helpers")

local describe, it = runner.describe, runner.it

local DATA = "/mock/plugin-data"
local CODEX_URL = "https://chatgpt.com/backend-api/wham/usage"
local CODEX_AUTH = '{"auth_mode":"chatgpt","tokens":{"access_token":"SECRET-CODEX","account_id":"acct-1","refresh_token":"SECRET-REFRESH"}}'

-- No token may reach the published view or a log line.
local function assertNoSecret(s)
	local text = mock.json.encode(h.view(s))
	assert.equal(string.find(text, "SECRET", 1, true), nil)
	for _, call in mock.calls(s.env, "noctalia.log") do
		assert.equal(string.find(tostring(call[1]), "SECRET", 1, true), nil)
	end
end

describe("service codex", function()
	it("polls Codex with its token and account id and caches the windows", function()
		local s = h.boot({ config = { show_codex = true }, fs = { ["~/.codex/auth.json"] = CODEX_AUTH } })
		local i = h.requests(s, CODEX_URL)[1]
		assert.equal(mock.pendingHttp(s.env)[i].request.method, "GET")
		assert.equal(h.header(s, i, "Authorization"), "Authorization: Bearer SECRET-CODEX")
		assert.equal(h.header(s, i, "ChatGPT-Account-Id"), "ChatGPT-Account-Id: acct-1")
		assert.equal(h.header(s, i, "User-Agent"), "User-Agent: codex-cli")
		mock.respond(s.env, i, { ok = true, status = 200, body = modules.text("tests/fixtures/codex-usage.json") })
		local c = h.sourceOf(s, "codex")
		assert.equal(c.snapshot.windows[1].percent, 96)
		assert.equal(c.snapshot.plan, "plus")
		assert.equal(mock.json.decode(s.env.noctalia.readFile(DATA .. "/snapshots.json")).codex.plan, "plus")
		assertNoSecret(s)
	end)

	it("reports a missing login without a request and maps 401 to auth", function()
		local s = h.boot({ config = { show_codex = true } })
		assert.equal(h.sourceOf(s, "codex").error, "codex-login")
		assert.equal(#h.requests(s, CODEX_URL), 0)
		local t = h.boot({ config = { show_codex = true }, fs = { ["~/.codex/auth.json"] = CODEX_AUTH } })
		mock.respond(t.env, h.requests(t, CODEX_URL)[1], { ok = true, status = 401, body = "" })
		assert.equal(h.sourceOf(t, "codex").error, "auth")
		assertNoSecret(t)
	end)

	it("restores the cached Codex snapshot stale at boot", function()
		local cached = '{"byAccount":{},"codex":{"provider":"codex","plan":"plus","windows":[{"id":"session","percent":50}],"products":[],"fetchedAt":1}}'
		local s = h.boot({ config = { show_codex = true }, fs = { [DATA .. "/snapshots.json"] = cached } })
		local c = h.sourceOf(s, "codex")
		assert.equal(c.snapshot.windows[1].percent, 50)
		assert.equal(c.stale, true)
	end)
end)

local CURSOR_DB = "/mock/home/.config/Cursor/User/globalStorage/state.vscdb"
local CURSOR_ARGV = "sqlite3 -readonly " .. CURSOR_DB .. " SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"
local CURSOR_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"

local function run(exitCode, stdout)
	return { exitCode = exitCode, stdout = stdout, stderr = "", timedOut = false, stdoutTruncated = false, stderrTruncated = false }
end

describe("service cursor", function()
	it("reads the token with sqlite3 and posts the usage RPC", function()
		local s = h.boot({ config = { show_cursor = true }, commands = { "sqlite3" }, async = { [CURSOR_ARGV] = run(0, "SECRET-CURSOR\n") } })
		local calls = mock.calls(s.env, "noctalia.runAsync")
		assert.equal(#calls, 1)
		for _, part in calls[1][1] do
			assert.equal(string.find(part, "SECRET", 1, true), nil)
		end
		local i = h.requests(s, CURSOR_URL)[1]
		local req = mock.pendingHttp(s.env)[i].request
		assert.equal(req.method, "POST")
		assert.equal(req.body, "{}")
		assert.equal(h.header(s, i, "Authorization"), "Authorization: Bearer SECRET-CURSOR")
		assert.equal(h.header(s, i, "Connect-Protocol-Version"), "Connect-Protocol-Version: 1")
		assert.equal(h.header(s, i, "Content-Type"), "Content-Type: application/json")
		mock.respond(s.env, i, { ok = true, status = 200, body = modules.text("tests/fixtures/cursor-usage.json") })
		local c = h.sourceOf(s, "cursor")
		assert.equal(c.snapshot.windows[1].periodType, "monthly")
		assert.equal(c.snapshot.products[1].name, "Auto")
		assertNoSecret(s)
	end)

	it("reports a missing sqlite3 or Cursor session without a request", function()
		local s = h.boot({ config = { show_cursor = true } })
		assert.equal(h.sourceOf(s, "cursor").error, "cursor-sqlite")
		assert.equal(#mock.calls(s.env, "noctalia.runAsync"), 0)
		local t = h.boot({ config = { show_cursor = true }, commands = { "sqlite3" }, async = { [CURSOR_ARGV] = run(1, "") } })
		assert.equal(h.sourceOf(t, "cursor").error, "cursor-login")
		assert.equal(#h.requests(t, CURSOR_URL), 0)
		assertNoSecret(t)
	end)
end)

local AGY_ARGV = "agy -p /quota --output-format json"
local AGY_BODY = modules.text("tests/fixtures/agy-quota.json")

describe("service agy", function()
	it("runs agy /quota without HTTP and publishes one window per bucket", function()
		local s = h.boot({ config = { show_agy = true }, commands = { "agy" }, async = { [AGY_ARGV] = run(0, AGY_BODY) } })
		local a = h.sourceOf(s, "agy")
		assert.equal(#a.snapshot.windows, 5)
		assert.equal(a.snapshot.windows[5].percent, 100)
		assert.equal(a.error, "")
		assert.equal(#mock.pendingHttp(s.env), 2) -- Claude and Grok only
		assert.equal(mock.json.decode(s.env.noctalia.readFile(DATA .. "/snapshots.json")).agy.primary, "max")
	end)

	it("backs off after a failed run and reports a missing agy", function()
		local s = h.boot({ config = { show_agy = true }, commands = { "agy" }, async = { [AGY_ARGV] = run(3, "") } })
		local a = h.sourceOf(s, "agy")
		assert.equal(a.error, "agy-login")
		assert.equal(a.retryAt, h.NOW + 5 * 60000)
		s.env.noctalia.state.set("cmd.refresh", 1)
		assert.equal(#mock.calls(s.env, "noctalia.runAsync"), 1)
		local t = h.boot({ config = { show_agy = true } })
		assert.equal(h.sourceOf(t, "agy").error, "agy-missing")
	end)

	it("names the agy group in a threshold notification", function()
		local s = h.boot({ config = { show_agy = true, notify_threshold = 97 }, commands = { "agy" }, async = { [AGY_ARGV] = run(0, AGY_BODY) } })
		local n = mock.calls(s.env, "noctalia.notify")
		assert.equal(#n, 1)
		assert.equal(n[1][1], "notify.title n=100 provider=provider.agy window=Gemini 4 Argon · window.weekly")
	end)

	it("treats unreadable output as a failed run", function()
		local s = h.boot({ config = { show_agy = true }, commands = { "agy" }, async = { [AGY_ARGV] = run(0, "not json") } })
		assert.equal(h.sourceOf(s, "agy").error, "agy-login")
	end)
end)
