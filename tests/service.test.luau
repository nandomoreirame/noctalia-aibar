local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")
local entry = require("./support/entry")

local describe, it = runner.describe, runner.it

local NOW = 1791662400000
local CLAUDE_URL = "https://api.anthropic.com/api/oauth/usage"
local GROK_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
local DATA = "/mock/plugin-data"

local CLAUDE_CRED = '{"claudeAiOauth":{"accessToken":"SECRET-CLAUDE","expiresAt":1891662400000,"subscriptionType":"max"}}'
local GROK_AUTH = '{"https://auth.x.ai":{"key":"SECRET-GROK","email":"u@x.dev"}}'
local CLAUDE_JSON = '{"oauthAccount":{"accountUuid":"u1","emailAddress":"a@x.dev"}}'
local CLAUDE_BODY = modules.text("tests/fixtures/claude-usage.json")
local GROK_BODY = modules.text("tests/fixtures/grok-billing.json")

local function boot(opts)
	opts = opts or {}
	local config = { bar_provider = "claude", poll_minutes = 5, notify_threshold = 97, claude_user_agent = "claude-cli/9.9.9 (external, cli)", claude_accounts = {} }
	for k, v in opts.config or {} do
		config[k] = v
	end
	local fs = { ["~/.claude/.credentials.json"] = CLAUDE_CRED, ["~/.grok/auth.json"] = GROK_AUTH, ["~/.claude.json"] = CLAUDE_JSON }
	for k, v in opts.fs or {} do
		fs[k] = if v == false then nil else v
	end
	return entry.load("service.luau", { config = config, fs = fs, now = opts.now or NOW })
end

local function requests(loaded, url)
	local out = {}
	for i, call in mock.pendingHttp(loaded.env) do
		if url == nil or call.request.url == url then
			table.insert(out, i)
		end
	end
	return out
end

local function view(loaded)
	return loaded.env.noctalia.state.get("view")
end

local function sourceOf(loaded, key)
	for _, s in view(loaded).sources do
		if s.key == key then
			return s
		end
	end
	return nil
end

local function has(list, needle)
	for _, v in list do
		if v == needle then
			return true
		end
	end
	return false
end

describe("service polling", function()
	it("polls Claude and Grok at start with the CLI headers", function()
		local s = boot()
		local calls = mock.pendingHttp(s.env)
		assert.equal(#calls, 2)
		local c = calls[requests(s, CLAUDE_URL)[1]].request
		assert.equal(c.method, "GET")
		assert.equal(has(c.headers, "Authorization: Bearer SECRET-CLAUDE"), true)
		assert.equal(has(c.headers, "anthropic-beta: oauth-2025-04-20"), true)
		assert.equal(has(c.headers, "User-Agent: claude-cli/9.9.9 (external, cli)"), true)
		local g = calls[requests(s, GROK_URL)[1]].request
		assert.equal(has(g.headers, "Authorization: Bearer SECRET-GROK"), true)
		assert.equal(has(g.headers, "X-XAI-Token-Auth: xai-grok-cli"), true)
		assert.equal(sourceOf(s, "claude").inFlight, true)
		assert.deepEqual(mock.calls(s.env, "noctalia.setUpdateInterval")[1], { 30000 })
	end)

	it("publishes snapshots and the account email on 200", function()
		local s = boot()
		mock.respond(s.env, 1, { ok = true, status = 200, body = CLAUDE_BODY })
		mock.respond(s.env, requests(s, GROK_URL)[1], { ok = true, status = 200, body = GROK_BODY })
		local c = sourceOf(s, "claude")
		assert.equal(c.snapshot.windows[1].percent, 47)
		assert.equal(c.email, "a@x.dev")
		assert.equal(c.stale, false)
		assert.equal(c.inFlight, false)
		assert.equal(sourceOf(s, "grok").snapshot.windows[1].percent, 63)
		assert.equal(view(s).barKey, "claude")
	end)

	it("reports credential errors without a request", function()
		local s = boot({ fs = { ["~/.claude/.credentials.json"] = false, ["~/.grok/auth.json"] = "{}" } })
		assert.equal(#mock.pendingHttp(s.env), 0)
		assert.equal(sourceOf(s, "claude").error, "claude-login")
		assert.equal(sourceOf(s, "grok").error, "grok-login")
	end)

	it("keeps the last snapshot stale on a network error", function()
		local s = boot()
		mock.respond(s.env, 1, { ok = true, status = 200, body = CLAUDE_BODY })
		mock.setNow(s.env, NOW + 5 * 60000)
		s.call("update")
		local again = requests(s, CLAUDE_URL)
		assert.equal(#again, 2)
		mock.respond(s.env, again[2], { ok = false, status = 0, body = "" })
		local c = sourceOf(s, "claude")
		assert.equal(c.stale, true)
		assert.equal(c.error, "network")
		assert.equal(c.snapshot.windows[1].percent, 47)
	end)

	it("maps 401 to auth, bad bodies to parse, and backs off after 429", function()
		local s = boot()
		mock.respond(s.env, requests(s, GROK_URL)[1], { ok = true, status = 401, body = "" })
		assert.equal(sourceOf(s, "grok").error, "auth")
		mock.respond(s.env, requests(s, CLAUDE_URL)[1], { ok = true, status = 429, body = "" })
		assert.equal(sourceOf(s, "claude").error, "rate-limited")
		mock.setNow(s.env, NOW + 5 * 60000 - 1)
		s.call("onIpc", "refresh")
		assert.equal(#requests(s, CLAUDE_URL), 1)
		local g = requests(s, GROK_URL)
		mock.respond(s.env, g[#g], { ok = true, status = 200, body = "<html>" })
		assert.equal(sourceOf(s, "grok").error, "parse")
	end)

	it("drops a late answer once a newer request replaced it", function()
		local s = boot()
		mock.setNow(s.env, NOW + 31000)
		s.call("onIpc", "refresh")
		local c = requests(s, CLAUDE_URL)
		assert.equal(#c, 2)
		mock.respond(s.env, c[1], { ok = true, status = 200, body = CLAUDE_BODY })
		assert.equal(sourceOf(s, "claude").snapshot, nil)
		mock.respond(s.env, c[2], { ok = true, status = 200, body = CLAUDE_BODY })
		assert.equal(sourceOf(s, "claude").snapshot.windows[1].percent, 47)
	end)
end)

describe("service cache", function()
	it("restores cached snapshots as stale at start", function()
		local cached = '{"byAccount":{"u1":{"provider":"claude","plan":"max","windows":[{"id":"weekly","percent":20,"startMs":1791597600082,"endMs":1792202400082}],"products":[],"fetchedAt":1}}}'
		local s = boot({ fs = { [DATA .. "/snapshots.json"] = cached } })
		local c = sourceOf(s, "claude")
		assert.equal(c.stale, true)
		assert.equal(c.snapshot.windows[1].percent, 20)
	end)

	it("saves usage by account id after a success", function()
		local s = boot()
		mock.respond(s.env, 1, { ok = true, status = 200, body = CLAUDE_BODY })
		local saved = s.env.noctalia.readFile(DATA .. "/snapshots.json")
		local data = mock.json.decode(saved)
		assert.equal(data.byAccount.u1.windows[1].percent, 47)
	end)
end)

describe("service secrecy", function()
	it("never puts a token in state, logs, files or notifications", function()
		local s = boot({ config = { notify_threshold = 10 } })
		mock.respond(s.env, requests(s, CLAUDE_URL)[1], { ok = true, status = 200, body = CLAUDE_BODY })
		mock.respond(s.env, requests(s, GROK_URL)[1], { ok = true, status = 500, body = "" })
		s.call("onIpc", "cycle")
		local function clean(value)
			local text = if typeof(value) == "string" then value else (mock.json.encode(value) or "")
			return string.find(text, "SECRET", 1, true) == nil
		end
		for _, path in { "noctalia.state.set", "noctalia.log", "noctalia.writeFile", "noctalia.notify" } do
			for _, args in mock.calls(s.env, path) do
				for _, arg in args do
					if typeof(arg) ~= "function" and not clean(arg) then
						error(path .. " leaked a token")
					end
				end
			end
		end
		assert.equal(#mock.calls(s.env, "noctalia.notify") > 0, true)
	end)
end)
