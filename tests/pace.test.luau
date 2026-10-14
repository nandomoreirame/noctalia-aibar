local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")

local describe, it = runner.describe, runner.it
local pace = modules.load("lib/pace.luau")
local H = 3600000

describe("pace.pace", function()
	it("compares used percent with elapsed percent", function()
		assert.deepEqual(pace.pace({ percent = 60, startMs = 0, endMs = 10 * H }, 4 * H), { elapsed = 40, delta = 20 })
	end)

	it("clamps elapsed and handles missing bounds", function()
		assert.equal(pace.pace({ percent = 10, startMs = 0, endMs = H }, 2 * H).elapsed, 100)
		assert.deepEqual(pace.pace({ percent = 10 }, H), {})
	end)
end)

describe("pace.status", function()
	it("is critical from 90, ahead above 10 points, ok otherwise", function()
		assert.equal(pace.status({ percent = 90, startMs = 0, endMs = 10 * H }, 9 * H), "critical")
		assert.equal(pace.status({ percent = 60, startMs = 0, endMs = 10 * H }, 4 * H), "ahead")
		assert.equal(pace.status({ percent = 45, startMs = 0, endMs = 10 * H }, 4 * H), "ok")
		assert.equal(pace.status({ percent = 45 }, 0), "ok")
		assert.equal(pace.status(nil, 0), "ok")
	end)
end)

describe("pace.primaryWindow", function()
	it("is session for Claude and period for Grok", function()
		assert.equal(pace.primaryWindow({ windows = { { id = "weekly" }, { id = "session" } } }).id, "session")
		assert.equal(pace.primaryWindow({ windows = { { id = "period" } } }).id, "period")
		assert.equal(pace.primaryWindow({ windows = { { id = "weekly" } } }).id, "weekly")
		assert.equal(pace.primaryWindow(nil), nil)
	end)
end)

describe("pace.exhausted", function()
	it("finds the exhausted window that resets last", function()
		local week = { id = "weekly", percent = 100, startMs = 0, endMs = 50 * H }
		local session = { id = "session", percent = 100, startMs = 0, endMs = 2 * H }
		assert.equal(pace.exhausted({ windows = { session, week } }, H), week)
		assert.equal(pace.exhausted({ windows = { session, { id = "weekly", percent = 99.4, endMs = 50 * H } } }, H), session)
	end)

	it("ignores windows that already reset or have no end", function()
		assert.equal(pace.exhausted({ windows = { { id = "session", percent = 100, endMs = H } } }, H), nil)
		assert.equal(pace.exhausted({ windows = { { id = "period", percent = 100 } } }, 0), nil)
		assert.equal(pace.exhausted(nil, 0), nil)
	end)
end)

describe("pace.project", function()
	it("shows windows whose reset passed as 0% without bounds", function()
		local snap = { provider = "claude", windows = {
			{ id = "session", percent = 80, startMs = 0, endMs = H },
			{ id = "weekly", percent = 97, startMs = 0, endMs = 100 * H },
		} }
		local out = pace.project(snap, 2 * H)
		assert.deepEqual(out.windows[1], { id = "session", percent = 0 })
		assert.equal(out.windows[2], snap.windows[2])
		assert.equal(snap.windows[1].percent, 80)
	end)

	it("returns the same snapshot when nothing reset, and passes junk through", function()
		local snap = { windows = { { id = "session", percent = 5, startMs = 0, endMs = H } } }
		assert.equal(pace.project(snap, 0), snap)
		assert.equal(pace.project(nil, 0), nil)
		assert.equal(pace.project({ windows = { { id = "x", percent = 5 } } }, H).windows[1].percent, 5)
	end)
end)
