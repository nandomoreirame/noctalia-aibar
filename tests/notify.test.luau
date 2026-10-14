local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")

local describe, it = runner.describe, runner.it
local notify = modules.load("lib/notify.luau")

local function snap(p, endMs)
	return { provider = "claude", windows = { { id = "session", percent = p, endMs = endMs } } }
end

describe("notify.crossings", function()
	it("fires once when a window crosses the threshold upward", function()
		local a = notify.crossings(snap(98, 1000), {}, 97)
		assert.deepEqual(a.fire, { { provider = "claude", id = "session", percent = 98, endMs = 1000 } })
		assert.deepEqual(notify.crossings(snap(99, 1000), a.armed, 97).fire, {})
	end)

	it("re-arms after dropping below or after a reset", function()
		local a = notify.crossings(snap(98, 1000), {}, 97)
		local low = notify.crossings(snap(10, 1000), a.armed, 97)
		assert.equal(#notify.crossings(snap(98, 1000), low.armed, 97).fire, 1)
		assert.equal(#notify.crossings(snap(98, 2000), a.armed, 97).fire, 1)
	end)

	it("fires once for a window without an end", function()
		local a = notify.crossings(snap(98, nil), {}, 97)
		assert.equal(#a.fire, 1)
		assert.equal(#notify.crossings(snap(99, nil), a.armed, 97).fire, 0)
	end)

	it("arms each source of a provider separately", function()
		local a = notify.crossings(snap(98, 1000), {}, 97, "claude")
		local b = notify.crossings(snap(98, 1000), a.armed, 97, "claude:work")
		assert.equal(#b.fire, 1)
		assert.equal(b.armed["claude|session"], 1000)
		assert.equal(b.armed["claude:work|session"], 1000)
	end)

	it("is off at threshold 0 and without a snapshot", function()
		assert.deepEqual(notify.crossings(snap(100, 1000), {}, 0).fire, {})
		assert.deepEqual(notify.crossings(nil, {}, 97).fire, {})
	end)
end)
