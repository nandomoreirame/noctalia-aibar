local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")

local describe, it = runner.describe, runner.it
local claude = modules.load("lib/claude.luau")
local fixture = mock.json.decode(modules.text("tests/fixtures/claude-usage.json"))
local NOW = 1791662400000

describe("claude.parseUsage", function()
	it("maps the real response to session and weekly windows", function()
		local r = claude.parseUsage(fixture, "max", NOW)
		assert.equal(r.ok, true)
		local s = r.snapshot
		assert.equal(s.provider, "claude")
		assert.equal(s.plan, "max")
		assert.equal(#s.windows, 2)
		assert.equal(s.windows[1].id, "session")
		assert.equal(s.windows[2].id, "weekly")
		assert.equal(s.windows[1].percent, 47)
		assert.equal(s.windows[1].endMs, 1791672600082)
		assert.equal(s.windows[1].startMs, 1791672600082 - claude.WINDOW_MS.session)
		assert.equal(s.windows[2].endMs, 1792202400082)
		assert.equal(s.fetchedAt, NOW)
		assert.deepEqual(s.products, {})
	end)

	it("maps extra usage in major units", function()
		assert.deepEqual(claude.parseUsage(fixture, "", NOW).snapshot.extra, { enabled = false, used = 33.5, limit = 90, percent = 37.22222222222222, currency = "BRL" })
	end)

	it("adds model-scoped weekly windows only when present", function()
		local body = {
			five_hour = { utilization = 10, resets_at = "2026-10-10T22:00:00Z" },
			seven_day_opus = { utilization = 5, resets_at = "2026-10-15T00:00:00Z" },
		}
		local ws = claude.parseUsage(body, "", NOW).snapshot.windows
		assert.equal(#ws, 2)
		assert.equal(ws[1].id, "session")
		assert.equal(ws[2].id, "weekly-opus")
		assert.equal(ws[2].endMs, 1792022400000)
	end)

	it("keeps a window without a reset time unbounded", function()
		local w = claude.parseUsage({ five_hour = { utilization = 3 } }, "", NOW).snapshot.windows[1]
		assert.equal(w.startMs, nil)
		assert.equal(w.endMs, nil)
	end)

	it("is an error when nothing usable comes back", function()
		assert.deepEqual(claude.parseUsage({}, "", NOW), { ok = false, error = "parse" })
		assert.deepEqual(claude.parseUsage(nil, "", NOW), { ok = false, error = "parse" })
		assert.deepEqual(claude.parseUsage("<html>", "", NOW), { ok = false, error = "parse" })
	end)
end)
