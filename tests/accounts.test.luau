local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")

local describe, it = runner.describe, runner.it
local accounts = modules.load("lib/accounts.luau")

local function keys(list)
	local out = {}
	for _, a in list do
		table.insert(out, a.key)
	end
	return out
end

describe("accounts.parseAccounts", function()
	it("reads Name=dir entries from a string list or a string", function()
		assert.deepEqual(accounts.parseAccounts({ "Trabalho=~/.claude-trabalho", " Cliente X = /data/u/.claude-x" }), {
			{ key = "claude:trabalho", name = "Trabalho", dir = "~/.claude-trabalho" },
			{ key = "claude:cliente-x", name = "Cliente X", dir = "/data/u/.claude-x" },
		})
		assert.deepEqual(keys(accounts.parseAccounts("A=~/.a, B=~/.b\n")), { "claude:a", "claude:b" })
	end)

	it("drops a trailing slash from the dir", function()
		assert.equal(accounts.parseAccounts({ "A=~/.claude-a/" })[1].dir, "~/.claude-a")
	end)

	it("ignores empty values and junk", function()
		assert.deepEqual(accounts.parseAccounts({}), {})
		assert.deepEqual(accounts.parseAccounts(nil), {})
		assert.deepEqual(accounts.parseAccounts(42), {})
		assert.deepEqual(accounts.parseAccounts({ "no-equals", "=~/.x", "A=", "A=relative/dir", "!!!=~/.y" }), {})
	end)

	it("rejects dirs that climb out with ..", function()
		assert.deepEqual(accounts.parseAccounts({ "A=~/../etc", "B=/data/u/../x" }), {})
	end)

	it("skips the default dir and duplicate names", function()
		assert.deepEqual(keys(accounts.parseAccounts({ "A=~/.claude", "B=~/.claude/", "C=~/.c1", "c=~/.c2" })), { "claude:c" })
	end)

	it("keeps at most MAX_EXTRA accounts and caps the name length", function()
		local list = {}
		for i = 1, accounts.MAX_EXTRA + 2 do
			table.insert(list, "N" .. i .. "=~/.c" .. i)
		end
		assert.equal(#accounts.parseAccounts(list), accounts.MAX_EXTRA)
		assert.equal(utf8.len(accounts.parseAccounts({ string.rep("A", 40) .. "=~/.c" })[1].name), 24)
		assert.equal(accounts.parseAccounts({ "Café " .. string.rep("x", 30) .. "=~/.c" })[1].name, "Café " .. string.rep("x", 19))
	end)
end)

describe("accounts.sources", function()
	it("lists the default Claude account, the extras, then Grok", function()
		assert.deepEqual(accounts.sources(accounts.parseAccounts({ "Trabalho=~/.claude-trabalho" })), {
			{ key = "claude", provider = "claude", name = "", dir = "", frozen = false },
			{ key = "claude:trabalho", provider = "claude", name = "Trabalho", dir = "~/.claude-trabalho", frozen = true },
			{ key = "grok", provider = "grok", name = "", dir = "", frozen = false },
		})
		assert.deepEqual(keys(accounts.sources(nil)), { "claude", "grok" })
	end)
end)

describe("accounts paths", function()
	it("points at the credential and config files", function()
		assert.equal(accounts.credPath({ provider = "claude", dir = "" }), "~/.claude/.credentials.json")
		assert.equal(accounts.credPath({ provider = "claude", dir = "~/.claude-x" }), "~/.claude-x/.credentials.json")
		assert.equal(accounts.credPath({ provider = "grok", dir = "" }), "~/.grok/auth.json")
		assert.equal(accounts.configPath({ provider = "claude", dir = "" }), "~/.claude.json")
		assert.equal(accounts.configPath({ provider = "claude", dir = "/data/u/.claude-f" }), "/data/u/.claude-f/.claude.json")
	end)
end)

describe("accounts identity", function()
	it("reads the logged account id and email, nothing else", function()
		assert.deepEqual(accounts.accountOf({ oauthAccount = { accountUuid = "u1", emailAddress = "a@x.dev", organizationUuid = "o" }, other = 1 }), { uuid = "u1", email = "a@x.dev" })
		assert.deepEqual(accounts.accountOf({ oauthAccount = { accountUuid = "u1" } }), { uuid = "u1", email = "" })
	end)

	it("is nil without a logged account", function()
		assert.equal(accounts.accountOf(nil), nil)
		assert.equal(accounts.accountOf({}), nil)
		assert.equal(accounts.accountOf({ oauthAccount = { emailAddress = "a@x.dev" } }), nil)
	end)

	it("adopts the first id, resets on a swap and ignores unreadable files", function()
		assert.equal(accounts.accountChange("", "u1"), "adopt")
		assert.equal(accounts.accountChange("u1", "u1"), "none")
		assert.equal(accounts.accountChange("u1", "u2"), "reset")
		assert.equal(accounts.accountChange("u1", ""), "none")
	end)

	it("picks the cached snapshot by account id, else by provider", function()
		local cache = { claude = { legacy = 1 }, grok = { g = 1 }, byAccount = { u1 = { a = 1 } } }
		assert.deepEqual(accounts.cachedSnapshot(cache, "claude", "u1"), { a = 1 })
		assert.deepEqual(accounts.cachedSnapshot(cache, "claude:freeze", "u1"), { a = 1 })
		assert.equal(accounts.cachedSnapshot(cache, "claude", "u2"), nil)
		assert.deepEqual(accounts.cachedSnapshot(cache, "claude", ""), { legacy = 1 })
		assert.deepEqual(accounts.cachedSnapshot(cache, "grok", ""), { g = 1 })
		assert.equal(accounts.cachedSnapshot(cache, "claude:freeze", ""), nil)
		assert.equal(accounts.cachedSnapshot(nil, "claude", "u1"), nil)
	end)
end)

describe("accounts keys", function()
	local list = accounts.sources(accounts.parseAccounts({ "T=~/.claude-t" }))

	it("cycles through every source", function()
		assert.equal(accounts.nextKey(list, "claude"), "claude:t")
		assert.equal(accounts.nextKey(list, "claude:t"), "grok")
		assert.equal(accounts.nextKey(list, "grok"), "claude")
	end)

	it("falls back to the first source for an unknown key", function()
		assert.equal(accounts.nextKey(list, "claude:gone"), "claude")
		assert.equal(accounts.resolveKey(list, "claude:gone"), "claude")
		assert.equal(accounts.resolveKey(list, "grok"), "grok")
	end)
end)

describe("accounts.normalizeKey", function()
	it("slugs the account name after claude: and lowercases the rest", function()
		assert.equal(accounts.normalizeKey("claude:Trabalho Pessoal"), "claude:trabalho-pessoal")
		assert.equal(accounts.normalizeKey(" Claude:work "), "claude:work")
		assert.equal(accounts.normalizeKey("GROK"), "grok")
		assert.equal(accounts.normalizeKey("claude"), "claude")
		assert.equal(accounts.normalizeKey(nil), "")
	end)

	it("caps the account name like parseAccounts", function()
		local key = accounts.parseAccounts({ "Conta Trabalho Principal X=~/.claude-t" })[1].key
		assert.equal(key, "claude:conta-trabalho-principal")
		assert.equal(accounts.normalizeKey("claude:Conta Trabalho Principal X"), key)
	end)
end)
