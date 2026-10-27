local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")

local describe, it = runner.describe, runner.it
local codex = modules.load("lib/codex.luau")
local NOW = 1793110000000

local function fixture(name)
	return mock.json.decode(modules.text("tests/fixtures/" .. name))
end

describe("codex.parseUsage", function()
	it("maps the 5h and weekly windows and the plan", function()
		local r = codex.parseUsage(fixture("codex-usage.json"), NOW)
		assert.equal(r.ok, true)
		assert.deepEqual(r.snapshot.windows, {
			{ id = "session", percent = 96, startMs = 1793107633000, endMs = 1793125633000 },
			{ id = "weekly", percent = 33, startMs = 1793028562000, endMs = 1793633362000 },
		})
		assert.equal(r.snapshot.plan, "plus")
		assert.equal(r.snapshot.provider, "codex")
		assert.deepEqual(r.snapshot.products, {})
		assert.equal(r.snapshot.fetchedAt, NOW)
	end)

	it("falls back to reset_after_seconds and classifies a weekly-only plan", function()
		local data = { plan_type = "free", rate_limit = { primary_window = { used_percent = 10, limit_window_seconds = 604800, reset_after_seconds = 60 } } }
		local r = codex.parseUsage(data, NOW)
		assert.deepEqual(r.snapshot.windows, {
			{ id = "weekly", percent = 10, startMs = NOW + 60000 - 604800000, endMs = NOW + 60000 },
		})
		assert.equal(r.snapshot.plan, "free")
	end)

	it("adds named additional limits as grouped windows", function()
		local data = {
			rate_limit = { primary_window = { used_percent = 1, limit_window_seconds = 18000, reset_at = 100 } },
			additional_rate_limits = { { limit_name = "GPT-6 Astra", rate_limit = { primary_window = { used_percent = 80, limit_window_seconds = 18000, reset_at = 200 } } } },
		}
		assert.deepEqual(codex.parseUsage(data, NOW).snapshot.windows, {
			{ id = "session", percent = 1, startMs = 100000 - 18000000, endMs = 100000 },
			{ id = "extra:gpt-6-astra:session", group = "GPT-6 Astra", span = "session", percent = 80, startMs = 200000 - 18000000, endMs = 200000 },
		})
	end)

	it("keys extra limits by name, not by position, and falls back to the feature or index", function()
		local function extra(fields)
			fields.rate_limit = { primary_window = { used_percent = 5, limit_window_seconds = 18000, reset_at = 1 }, secondary_window = { used_percent = 6, limit_window_seconds = 604800, reset_at = 2 } }
			return fields
		end
		local data = { additional_rate_limits = { "junk", extra({ limit_name = "", metered_feature = "Code Review" }), extra({}), { limit_name = "empty" } } }
		local ids, groups = {}, {}
		for _, w in codex.parseUsage(data, NOW).snapshot.windows do
			table.insert(ids, w.id)
			table.insert(groups, w.group)
		end
		assert.deepEqual(ids, { "extra:code-review:session", "extra:code-review:weekly", "extra:3:session", "extra:3:weekly" })
		assert.deepEqual(groups, { "Code Review", "Code Review", "#3", "#3" })
	end)

	it("classifies spans by length at the edges and by slot without a length", function()
		local function spanFor(seconds, slot)
			local window = { used_percent = 1, limit_window_seconds = seconds, reset_at = 10 }
			local limit = if slot == "primary" then { primary_window = window } else { secondary_window = window }
			return codex.parseUsage({ rate_limit = limit }, NOW).snapshot.windows[1].id
		end
		assert.equal(spanFor(21600, "secondary"), "session")
		assert.equal(spanFor(518400, "primary"), "weekly")
		assert.equal(spanFor(86400, "primary"), "session")
		assert.equal(spanFor(86400, "secondary"), "weekly")
		assert.equal(spanFor(nil, "primary"), "session")
		assert.equal(spanFor(nil, "secondary"), "weekly")
	end)

	it("never gives two windows of one block the same id", function()
		local data = { rate_limit = {
			primary_window = { used_percent = 1, limit_window_seconds = 604800, reset_at = 10 },
			secondary_window = { used_percent = 2, reset_at = 20 },
		} }
		local w = codex.parseUsage(data, NOW).snapshot.windows
		assert.equal(w[1].id, "weekly")
		assert.equal(w[2].id, "weekly-2")
	end)

	it("keeps a window without a reset unbounded and defaults the plan", function()
		local r = codex.parseUsage({ rate_limit = { primary_window = { used_percent = 7, limit_window_seconds = 18000 } } }, NOW)
		assert.deepEqual(r.snapshot.windows, { { id = "session", percent = 7 } })
		assert.equal(r.snapshot.plan, "")
	end)

	it("refuses garbage and a body without windows", function()
		assert.deepEqual(codex.parseUsage(nil, NOW), { ok = false, error = "parse" })
		assert.deepEqual(codex.parseUsage("x", NOW), { ok = false, error = "parse" })
		assert.deepEqual(codex.parseUsage({ plan_type = "plus", rate_limit = {} }, NOW), { ok = false, error = "parse" })
		assert.deepEqual(codex.parseUsage({ rate_limit = { primary_window = { used_percent = "5" } } }, NOW), { ok = false, error = "parse" })
	end)
end)
