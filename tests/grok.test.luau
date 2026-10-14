local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")

local describe, it = runner.describe, runner.it
local grok = modules.load("lib/grok.luau")
local NOW = 1791662400000

local function fixture(name)
	return mock.json.decode(modules.text("tests/fixtures/" .. name))
end

describe("grok.parseBilling", function()
	it("maps the credits response to a period window and products", function()
		local r = grok.parseBilling(fixture("grok-billing.json"), NOW)
		assert.equal(r.ok, true)
		assert.deepEqual(r.snapshot.windows, { { id = "period", periodType = "weekly", percent = 63, startMs = 1791313564770, endMs = 1791918364770 } })
		assert.deepEqual(r.snapshot.products, { { name = "GrokBuild", percent = 63 } })
		assert.equal(r.snapshot.provider, "grok")
		assert.equal(r.snapshot.fetchedAt, NOW)
	end)

	it("reads a monthly period and a missing period", function()
		local monthly = { config = { creditUsagePercent = 5, currentPeriod = { type = "USAGE_PERIOD_TYPE_MONTHLY", start = "2026-10-01T00:00:00Z", ["end"] = "2026-11-01T00:00:00Z" } } }
		local w = grok.parseBilling(monthly, NOW).snapshot.windows[1]
		assert.equal(w.periodType, "monthly")
		assert.equal(w.endMs, 1793491200000)
		local bare = grok.parseBilling({ config = { creditUsagePercent = 5 } }, NOW).snapshot.windows[1]
		assert.deepEqual(bare, { id = "period", periodType = "weekly", percent = 5 })
	end)

	it("refuses the legacy shape and garbage", function()
		assert.deepEqual(grok.parseBilling(fixture("grok-billing-legacy.json"), NOW), { ok = false, error = "grok-format" })
		assert.deepEqual(grok.parseBilling(nil, NOW), { ok = false, error = "parse" })
		assert.deepEqual(grok.parseBilling({ nope = 1 }, NOW), { ok = false, error = "parse" })
	end)

	it("reads a fresh period without creditUsagePercent as 0%", function()
		local r = grok.parseBilling(fixture("grok-billing-zero.json"), NOW)
		assert.equal(r.ok, true)
		local w = r.snapshot.windows[1]
		assert.equal(w.percent, 0)
		assert.equal(w.periodType, "weekly")
		assert.equal(w.endMs, 1792523164770)
		assert.deepEqual(r.snapshot.products, {})
	end)
end)
