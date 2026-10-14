local assert = require("./support/assert")
local runner = require("./support/runner")
local mock = require("./support/noctalia_mock")
local h = require("./support/service_helpers")

local describe, it = runner.describe, runner.it
local DATA = "/mock/plugin-data"

describe("service file changes", function()
	it("re-polls a source whose credentials changed", function()
		local s = h.boot()
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 200, body = h.CLAUDE_BODY })
		mock.setFile(s.env, "~/.claude/.credentials.json", h.CLAUDE_CRED, 2)
		s.call("update")
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 2)
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 2)
	end)

	it("switches to the swapped account, drops the old answer and re-polls", function()
		local s = h.boot()
		local first = h.requests(s, h.CLAUDE_URL)[1]
		mock.setFile(s.env, "~/.claude.json", '{"oauthAccount":{"accountUuid":"u2","emailAddress":"b@x.dev"}}', 2)
		s.call("update")
		s.call("update")
		local c = h.requests(s, h.CLAUDE_URL)
		assert.equal(#c, 2)
		assert.equal(h.sourceOf(s, "claude").email, "b@x.dev")
		mock.respond(s.env, first, { ok = true, status = 200, body = h.CLAUDE_BODY })
		assert.equal(h.sourceOf(s, "claude").snapshot, nil)
		mock.respond(s.env, c[2], { ok = true, status = 200, body = h.CLAUDE_BODY })
		assert.equal(h.sourceOf(s, "claude").snapshot.windows[1].percent, 47)
	end)

	it("polls frozen accounts from their own dir", function()
		local s = h.boot({
			config = { claude_accounts = { "Frozen=~/.claude-freeze" } },
			fs = {
				["~/.claude-freeze/.credentials.json"] = '{"claudeAiOauth":{"accessToken":"SECRET-F","expiresAt":1891662400000}}',
				["~/.claude-freeze/.claude.json"] = '{"oauthAccount":{"accountUuid":"u9","emailAddress":"f@x.dev"}}',
			},
		})
		assert.equal(#h.requests(s, h.CLAUDE_URL), 2)
		local frozen = h.sourceOf(s, "claude:frozen")
		assert.equal(frozen.frozen, true)
		assert.equal(frozen.email, "f@x.dev")
	end)

	it("keeps a credential change that arrives while a request is in flight", function()
		local s = h.boot()
		mock.setFile(s.env, "~/.claude/.credentials.json", h.CLAUDE_CRED, 2)
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 1)
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 401, body = "" })
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 2)
	end)

	it("polls a swapped account only with its own token", function()
		local s = h.boot()
		mock.setFile(s.env, "~/.claude.json", '{"oauthAccount":{"accountUuid":"u2","emailAddress":"b@x.dev"}}', 2)
		s.call("update")
		assert.equal(h.sourceOf(s, "claude").email, "b@x.dev")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 1)
		mock.setFile(s.env, "~/.claude/.credentials.json", '{"claudeAiOauth":{"accessToken":"SECRET-B","expiresAt":1891662400000}}', 2)
		s.call("update")
		s.call("update")
		local c = h.requests(s, h.CLAUDE_URL)
		assert.equal(#c, 2)
		local headers = mock.pendingHttp(s.env)[c[2]].request.headers
		local found = false
		for _, line in headers do
			if line == "Authorization: Bearer SECRET-B" then
				found = true
			end
		end
		assert.equal(found, true)
	end)

	it("keeps the answer of a request started before the account was known", function()
		local s = h.boot({ fs = { ["~/.claude.json"] = false } })
		mock.setFile(s.env, "~/.claude.json", h.CLAUDE_JSON, 2)
		s.call("update")
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 200, body = h.CLAUDE_BODY })
		local c = h.sourceOf(s, "claude")
		assert.equal(c.inFlight, false)
		assert.equal(c.snapshot.windows[1].percent, 47)
		local saved = mock.json.decode(s.env.noctalia.readFile("/mock/plugin-data/snapshots.json"))
		assert.equal(saved.byAccount.u1.windows[1].percent, 47)
	end)
end)

describe("service commands and selection", function()
	it("cycles the bar source on cmd.cycle and persists it", function()
		local s = h.boot()
		s.env.noctalia.state.set("cmd.cycle", 1)
		assert.equal(h.view(s).barKey, "grok")
		assert.equal(mock.json.decode(s.env.noctalia.readFile(DATA .. "/selection.json")).key, "grok")
		s.call("onIpc", "cycle")
		assert.equal(h.view(s).barKey, "claude")
	end)

	it("restores the persisted choice at start", function()
		local s = h.boot({ fs = { [DATA .. "/selection.json"] = '{"key":"grok"}' } })
		assert.equal(h.view(s).barKey, "grok")
	end)

	it("lets a changed bar_provider setting override the choice", function()
		local s = h.boot({ fs = { [DATA .. "/selection.json"] = '{"key":"grok"}' } })
		s.call("onConfigChanged")
		assert.equal(h.view(s).barKey, "grok")
		mock.setConfig(s.env, "bar_provider", "grok")
		s.call("onConfigChanged")
		mock.setConfig(s.env, "bar_provider", "claude")
		s.call("onConfigChanged")
		assert.equal(h.view(s).barKey, "claude")
	end)

	it("falls back to bar_provider when the chosen account is removed", function()
		local s = h.boot({
			config = { bar_provider = "grok", claude_accounts = { "Work=~/.claude-w" } },
			fs = { ["~/.claude-w/.credentials.json"] = h.CLAUDE_CRED },
		})
		s.env.noctalia.state.set("cmd.cycle", 1)
		s.env.noctalia.state.set("cmd.cycle", 2)
		assert.equal(h.view(s).barKey, "claude:work")
		mock.setConfig(s.env, "claude_accounts", {})
		s.call("onConfigChanged")
		assert.equal(h.view(s).barKey, "grok")
		assert.equal(mock.json.decode(s.env.noctalia.readFile("/mock/plugin-data/selection.json")).key, "grok")
	end)

	it("refreshes every source on cmd.refresh", function()
		local s = h.boot()
		mock.respond(s.env, 1, { ok = true, status = 200, body = h.CLAUDE_BODY })
		mock.respond(s.env, 2, { ok = true, status = 200, body = h.GROK_BODY })
		s.env.noctalia.state.set("cmd.refresh", 1)
		assert.equal(#mock.pendingHttp(s.env), 4)
	end)
end)

describe("service notifications", function()
	it("notifies once per crossing", function()
		local s = h.boot({ config = { notify_threshold = 40 } })
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 200, body = h.CLAUDE_BODY })
		local calls = mock.calls(s.env, "noctalia.notify")
		assert.equal(#calls, 1)
		assert.equal(string.find(calls[1][1], "notify.title", 1, true) ~= nil, true)
		assert.equal(string.find(calls[1][1], "window=window.session", 1, true) ~= nil, true)
		mock.setNow(s.env, h.NOW + 5 * 60000)
		s.call("update")
		local again = h.requests(s, h.CLAUDE_URL)
		mock.respond(s.env, again[#again], { ok = true, status = 200, body = h.CLAUDE_BODY })
		assert.equal(#mock.calls(s.env, "noctalia.notify"), 1)
	end)

	it("is silent at threshold 0", function()
		local s = h.boot({ config = { notify_threshold = 0 } })
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 200, body = h.CLAUDE_BODY })
		assert.equal(#mock.calls(s.env, "noctalia.notify"), 0)
		assert.equal(#mock.calls(s.env, "noctalia.notifyError"), 0)
	end)
end)

describe("service file fingerprints", function()
	it("ignores sub-millisecond mtime jitter", function()
		local s = h.boot()
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 200, body = h.CLAUDE_BODY })
		mock.setFile(s.env, "~/.claude/.credentials.json", h.CLAUDE_CRED, 1 + 1e-7)
		s.call("update")
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 1)
	end)

	it("ignores a downward wobble at a whole second", function()
		local s = h.boot()
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 200, body = h.CLAUDE_BODY })
		mock.setFile(s.env, "~/.claude/.credentials.json", h.CLAUDE_CRED, 1 - 1e-7)
		s.call("update")
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 1)
	end)

	it("notices a rewrite that keeps the mtime but changes the size", function()
		local s = h.boot()
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 200, body = h.CLAUDE_BODY })
		mock.setFile(s.env, "~/.claude/.credentials.json", h.CLAUDE_CRED .. " ", 1)
		s.call("update")
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 2)
	end)
end)

describe("service settings changes", function()
	local function answered()
		local s = h.boot({
			config = { claude_accounts = { "Work=~/.claude-a" } },
			fs = {
				["~/.claude-a/.credentials.json"] = '{"claudeAiOauth":{"accessToken":"SECRET-A","expiresAt":1891662400000}}',
				["~/.claude-a/.claude.json"] = '{"oauthAccount":{"accountUuid":"u7","emailAddress":"w@x.dev"}}',
				["~/.claude-b/.credentials.json"] = '{"claudeAiOauth":{"accessToken":"SECRET-B","expiresAt":1891662400000}}',
				["~/.claude-n/.credentials.json"] = '{"claudeAiOauth":{"accessToken":"SECRET-N","expiresAt":1891662400000}}',
			},
		})
		for i = 1, #mock.pendingHttp(s.env) do
			mock.respond(s.env, i, { ok = true, status = 500, body = "" })
		end
		return s
	end

	it("does not poll when an unrelated setting changes", function()
		local s = answered()
		local before = #mock.pendingHttp(s.env)
		mock.setConfig(s.env, "notify_threshold", 50)
		s.call("onConfigChanged")
		assert.equal(#mock.pendingHttp(s.env), before)
	end)

	it("polls only an added account", function()
		local s = answered()
		local before = #mock.pendingHttp(s.env)
		mock.setConfig(s.env, "claude_accounts", { "Work=~/.claude-a", "New=~/.claude-n" })
		s.call("onConfigChanged")
		local calls = mock.pendingHttp(s.env)
		assert.equal(#calls, before + 1)
		local found = false
		for _, line in calls[#calls].request.headers do
			if line == "Authorization: Bearer SECRET-N" then
				found = true
			end
		end
		assert.equal(found, true)
	end)

	it("resets an account whose dir changed", function()
		local s = answered()
		assert.equal(h.sourceOf(s, "claude:work").email, "w@x.dev")
		mock.setConfig(s.env, "claude_accounts", { "Work=~/.claude-b" })
		s.call("onConfigChanged")
		local work = h.sourceOf(s, "claude:work")
		assert.equal(work.email, "")
		assert.equal(work.error, "")
		local calls = mock.pendingHttp(s.env)
		local found = false
		for _, line in calls[#calls].request.headers do
			if line == "Authorization: Bearer SECRET-B" then
				found = true
			end
		end
		assert.equal(found, true)
	end)
end)
