local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")

local describe, it = runner.describe, runner.it
local time = modules.load("lib/time.luau")

describe("time.parseIso", function()
	it("parses UTC with microseconds, truncated to ms", function()
		assert.equal(time.parseIso("2026-10-10T22:50:00.082044+00:00"), 1791672600082)
		assert.equal(time.parseIso("2026-10-06T19:06:04.770890+00:00"), 1791313564770)
		assert.equal(time.parseIso("2026-10-10T20:00:00Z"), 1791662400000)
	end)

	it("applies offsets", function()
		assert.equal(time.parseIso("2026-10-10T19:50:00-03:00"), 1791672600000)
		assert.equal(time.parseIso("2026-10-11T01:50:00+0300"), 1791672600000)
	end)

	it("handles the epoch and leap days", function()
		assert.equal(time.parseIso("1970-01-01T00:00:00Z"), 0)
		assert.equal(time.parseIso("2000-02-29T12:00:00Z"), 951825600000)
	end)

	it("returns nil for junk", function()
		assert.equal(time.parseIso(nil), nil)
		assert.equal(time.parseIso(""), nil)
		assert.equal(time.parseIso("2026-10-10"), nil)
		assert.equal(time.parseIso("2026-13-10T00:00:00Z"), nil)
		assert.equal(time.parseIso("2026-10-10T00:00:00"), nil)
		assert.equal(time.parseIso(42), nil)
	end)
end)
