local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")

local describe, it = runner.describe, runner.it
local view = modules.load("lib/view.luau")
local accounts = modules.load("lib/accounts.luau")
local H = 3600000

local SOURCES = accounts.sources(accounts.parseAccounts({ "Frozen=~/.claude-freeze" }))

describe("view.build", function()
	it("lists every source with its state, identity and a projected snapshot", function()
		local snap = { provider = "claude", windows = { { id = "session", percent = 80, startMs = 0, endMs = H } } }
		local v = view.build(SOURCES, { claude = { snapshot = snap, stale = true, error = "network", code = 0, retryAt = 0, inFlight = false } }, { claude = { uuid = "u1", email = "a@x.dev" } }, "grok", 2 * H)
		assert.equal(v.now, 2 * H)
		assert.equal(v.barKey, "grok")
		assert.equal(#v.sources, 3)
		local c = v.sources[1]
		assert.equal(c.key, "claude")
		assert.equal(c.email, "a@x.dev")
		assert.equal(c.stale, true)
		assert.equal(c.error, "network")
		assert.equal(c.snapshot.windows[1].percent, 0)
		assert.equal(v.sources[2].frozen, true)
		assert.equal(v.sources[2].name, "Frozen")
		assert.equal(v.sources[3].snapshot, nil)
		assert.equal(v.sources[3].error, "")
		assert.equal(v.sources[3].inFlight, false)
	end)
end)

describe("view.initialKey", function()
	it("prefers a persisted key that still exists", function()
		assert.equal(view.initialKey(SOURCES, "claude:frozen", "grok"), "claude:frozen")
		assert.equal(view.initialKey(SOURCES, "claude:gone", "grok"), "grok")
		assert.equal(view.initialKey(SOURCES, nil, "grok"), "grok")
		assert.equal(view.initialKey(SOURCES, nil, "bogus"), "claude")
		assert.equal(view.initialKey(SOURCES, nil, nil), "claude")
	end)
end)
