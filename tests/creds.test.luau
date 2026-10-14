local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")

local describe, it = runner.describe, runner.it
local creds = modules.load("lib/creds.luau")
local NOW = 1800000000000

local function file(o)
	return { claudeAiOauth = o }
end

describe("creds.claudeToken", function()
	it("returns the token and plan when not expired", function()
		assert.deepEqual(creds.claudeToken(file({ accessToken = "AT", expiresAt = NOW + 3600000, subscriptionType = "max" }), NOW), { ok = true, token = "AT", plan = "max" })
	end)

	it("treats a token expiring within a minute as expired", function()
		assert.deepEqual(creds.claudeToken(file({ accessToken = "AT", expiresAt = NOW + 30000 }), NOW), { ok = false, error = "claude-expired" })
	end)

	it("reports login for missing or malformed data", function()
		assert.deepEqual(creds.claudeToken(nil, NOW), { ok = false, error = "claude-login" })
		assert.deepEqual(creds.claudeToken("text", NOW), { ok = false, error = "claude-login" })
		assert.deepEqual(creds.claudeToken(file({ expiresAt = NOW + 3600000 }), NOW), { ok = false, error = "claude-login" })
	end)
end)

describe("creds.grokKey", function()
	it("takes the alphabetically first issuer with a key, trimmed", function()
		local data = { b = { key = "K2" }, ["https://auth.x.ai"] = { key = "  K1  " }, a = { email = "x" } }
		assert.deepEqual(creds.grokKey(data), { ok = true, key = "K2" })
		assert.deepEqual(creds.grokKey({ ["https://auth.x.ai"] = { key = "  K1  " } }), { ok = true, key = "K1" })
	end)

	it("reports login when there is no key", function()
		assert.deepEqual(creds.grokKey(nil), { ok = false, error = "grok-login" })
		assert.deepEqual(creds.grokKey({ a = { key = "" } }), { ok = false, error = "grok-login" })
		assert.deepEqual(creds.grokKey({ { key = "K" } }), { ok = false, error = "grok-login" })
	end)
end)
