local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")

local describe, it = runner.describe, runner.it
local cursor = modules.load("lib/cursor.luau")
local NOW = 1793110000000

local function fixture(name)
	return mock.json.decode(modules.text("tests/fixtures/" .. name))
end

describe("cursor.parseUsage", function()
	it("maps the billing cycle to a monthly period with Auto and API products", function()
		local r = cursor.parseUsage(fixture("cursor-usage.json"), NOW)
		assert.equal(r.ok, true)
		assert.deepEqual(r.snapshot.windows, { { id = "period", periodType = "monthly", percent = 15.5, startMs = 1791224760450, endMs = 1793903160450 } })
		assert.deepEqual(r.snapshot.products, { { name = "Auto", percent = 12.5 }, { name = "API", percent = 3 } })
		assert.equal(r.snapshot.provider, "cursor")
		assert.equal(r.snapshot.plan, "")
		assert.equal(r.snapshot.fetchedAt, NOW)
	end)

	it("reads dropped zero fields as 0%", function()
		local r = cursor.parseUsage({ billingCycleStart = "1", billingCycleEnd = "2", planUsage = {} }, NOW)
		assert.equal(r.snapshot.windows[1].percent, 0)
		assert.deepEqual(r.snapshot.products, { { name = "Auto", percent = 0 }, { name = "API", percent = 0 } })
	end)

	it("refuses garbage", function()
		assert.deepEqual(cursor.parseUsage(nil, NOW), { ok = false, error = "parse" })
		assert.deepEqual(cursor.parseUsage({ displayMessage = "x" }, NOW), { ok = false, error = "parse" })
	end)
end)

describe("cursor token", function()
	it("builds a read-only sqlite3 argv that never holds the token", function()
		local db = "/mock/home/.config/Cursor/User/globalStorage/state.vscdb"
		assert.deepEqual(cursor.tokenArgv(db), { "sqlite3", "-readonly", db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'" })
		assert.equal(cursor.DB_PATH, "~/.config/Cursor/User/globalStorage/state.vscdb")
	end)

	it("trims the token and refuses failures", function()
		assert.deepEqual(cursor.tokenFrom({ exitCode = 0, stdout = "tok.en\n" }), { ok = true, token = "tok.en" })
		assert.deepEqual(cursor.tokenFrom({ exitCode = 0, stdout = "\n" }), { ok = false, error = "cursor-login" })
		assert.deepEqual(cursor.tokenFrom({ exitCode = 0, stdout = "a b" }), { ok = false, error = "cursor-login" })
		assert.deepEqual(cursor.tokenFrom({ exitCode = 1, stdout = "x" }), { ok = false, error = "cursor-login" })
		assert.deepEqual(cursor.tokenFrom(nil), { ok = false, error = "cursor-login" })
	end)
end)
