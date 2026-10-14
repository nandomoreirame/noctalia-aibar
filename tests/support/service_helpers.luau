local modules = require("./modules")
local mock = require("./noctalia_mock")
local entry = require("./entry")

local H = {}

H.NOW = 1791662400000
H.CLAUDE_URL = "https://api.anthropic.com/api/oauth/usage"
H.GROK_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"

H.CLAUDE_CRED = '{"claudeAiOauth":{"accessToken":"SECRET-CLAUDE","expiresAt":1891662400000,"subscriptionType":"max"}}'
H.GROK_AUTH = '{"https://auth.x.ai":{"key":"SECRET-GROK","email":"u@x.dev"}}'
H.CLAUDE_JSON = '{"oauthAccount":{"accountUuid":"u1","emailAddress":"a@x.dev"}}'
H.CLAUDE_BODY = modules.text("tests/fixtures/claude-usage.json")
H.GROK_BODY = modules.text("tests/fixtures/grok-billing.json")

function H.boot(opts)
	opts = opts or {}
	local config = { bar_provider = "claude", poll_minutes = 5, notify_threshold = 97, claude_user_agent = "claude-cli/9.9.9 (external, cli)", claude_accounts = {} }
	for k, v in opts.config or {} do
		config[k] = v
	end
	local fs = { ["~/.claude/.credentials.json"] = H.CLAUDE_CRED, ["~/.grok/auth.json"] = H.GROK_AUTH, ["~/.claude.json"] = H.CLAUDE_JSON }
	for k, v in opts.fs or {} do
		fs[k] = if v == false then nil else v
	end
	return entry.load("service.luau", { config = config, fs = fs, now = opts.now or H.NOW })
end

function H.requests(loaded, url)
	local out = {}
	for i, call in mock.pendingHttp(loaded.env) do
		if url == nil or call.request.url == url then
			table.insert(out, i)
		end
	end
	return out
end

function H.view(loaded)
	return loaded.env.noctalia.state.get("view")
end

function H.sourceOf(loaded, key)
	for _, s in H.view(loaded).sources do
		if s.key == key then
			return s
		end
	end
	return nil
end

return H
