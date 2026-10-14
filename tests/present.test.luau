local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")

local describe, it = runner.describe, runner.it
local present = modules.load("lib/present.luau")
local tr = mock.fakeTr
local M = 60000
local H = 60 * M

local function source(fields)
	local s = { key = "claude", provider = "claude", name = "", frozen = false, email = "", stale = false, error = "", code = 0, retryAt = 0, inFlight = false }
	for k, v in fields do
		s[k] = v
	end
	return s
end

local SNAP = {
	provider = "claude",
	plan = "max",
	windows = {
		{ id = "session", percent = 47, startMs = 0, endMs = 5 * H },
		{ id = "weekly", percent = 95, startMs = 0, endMs = 168 * H },
	},
	extra = { enabled = false, used = 33.5, limit = 90, percent = 37.2, currency = "BRL" },
	products = {},
	fetchedAt = 2 * H,
}

describe("present.bar", function()
	it("shows glyph and a dash before the first view", function()
		local m = present.bar(nil, tr)
		assert.equal(m.glyph, "asterisk")
		assert.equal(m.label, "—")
		assert.equal(m.fraction, 0)
		assert.deepEqual(m.tooltip, {})
	end)

	it("shows the primary window of the bar source with status color", function()
		local v = { now = 3 * H, barKey = "claude", sources = { source({ snapshot = SNAP }), source({ key = "grok", provider = "grok" }) } }
		local m = present.bar(v, tr)
		assert.equal(m.label, "47% · 2h0m")
		assert.equal(m.fraction, 0.47)
		assert.equal(m.fill, "primary")
		assert.equal(m.stale, false)
		assert.deepEqual(m.tooltip[1], { "window.session", "47% · panel.resets t=2h0m" })
		assert.deepEqual(m.tooltip[2], { "window.weekly", "95% · panel.resets t=6d21h" })
	end)

	it("names the source in the tooltip when there is more than one Claude account", function()
		local v = { now = 0, barKey = "claude:f", sources = {
			source({}),
			source({ key = "claude:f", name = "F", frozen = true, error = "claude-expired" }),
			source({ key = "grok", provider = "grok" }),
		} }
		local m = present.bar(v, tr)
		assert.deepEqual(m.tooltip, { { "provider.claude · F", "" } })
	end)

	it("colors critical and ahead windows and dims stale data", function()
		local critical = { now = 0, barKey = "grok", sources = { source({ key = "grok", provider = "grok", stale = true, error = "network", snapshot = { provider = "grok", windows = { { id = "period", periodType = "weekly", percent = 92 } } } }) } }
		local m = present.bar(critical, tr)
		assert.equal(m.glyph, "brand-x")
		assert.equal(m.fill, "error")
		assert.equal(m.stale, true)
		assert.deepEqual(m.tooltip[#m.tooltip], { "error.network", "" })
		local ahead = { now = 4 * H, barKey = "claude", sources = { source({ snapshot = { windows = { { id = "session", percent = 60, startMs = 0, endMs = 10 * H } } } }) } }
		assert.equal(present.bar(ahead, tr).fill, "tertiary")
	end)
end)

describe("present.card", function()
	it("builds rows with progress, pace and money", function()
		local c = present.card(source({ snapshot = SNAP, email = "a@x.dev" }), 2 * H, tr)
		assert.equal(c.title, "provider.claude")
		assert.equal(c.plan, "Max")
		assert.equal(c.email, "a@x.dev")
		assert.equal(c.updated, "panel.updated-now")
		assert.equal(c.badge, nil)
		assert.equal(#c.rows, 2)
		assert.equal(c.rows[1].label, "window.session")
		assert.equal(c.rows[1].percentText, "47%")
		assert.equal(c.rows[1].fraction, 0.47)
		assert.equal(c.rows[1].detail, "panel.resets t=3h0m · pace.ahead n=7")
		assert.equal(c.rows[2].fill, "error")
		assert.equal(c.extra.detail, "33.50 / 90.00 BRL")
		assert.equal(c.extra.label, "window.extra")
		assert.equal(c.error, "")
		assert.equal(c.empty, "")
	end)

	it("shows the frozen badge and age, and hides login errors of frozen accounts", function()
		local c = present.card(source({ key = "claude:f", name = "F", frozen = true, stale = true, error = "claude-expired", snapshot = SNAP }), 2 * H + 5 * M, tr)
		assert.deepEqual(c.badge, { text = "panel.frozen", color = "primary" })
		assert.equal(c.updated, "panel.updated t=5m")
		assert.equal(c.error, "")
	end)

	it("shows stale badge, no age, and the error for a live account", function()
		local c = present.card(source({ stale = true, error = "network", snapshot = SNAP }), 2 * H, tr)
		assert.deepEqual(c.badge, { text = "panel.stale", color = "error" })
		assert.equal(c.updated, "")
		assert.equal(c.error, "error.network")
	end)

	it("shows no-data only when there is no snapshot and no error", function()
		assert.equal(present.card(source({}), 0, tr).empty, "panel.no-data")
		local failed = present.card(source({ error = "claude-login" }), 0, tr)
		assert.equal(failed.empty, "")
		assert.equal(failed.error, "error.claude-login")
	end)

	it("lists Grok products and a reached limit", function()
		local snap = { provider = "grok", plan = "", windows = { { id = "period", periodType = "monthly", percent = 100, startMs = 0, endMs = 10 * H } }, products = { { name = "GrokBuild", percent = 63 } }, fetchedAt = 0 }
		local c = present.card(source({ key = "grok", provider = "grok", error = "auth", snapshot = snap }), H, tr)
		assert.equal(c.plan, "")
		assert.deepEqual(c.products, { { name = "GrokBuild", percentText = "63%" } })
		assert.equal(c.limit, "panel.limit-reached t=9h0m")
		assert.equal(c.error, "")
	end)
end)

describe("present.panel", function()
	local v = { now = 0, barKey = "claude", sources = {
		source({ email = "a@x.dev" }),
		source({ key = "claude:f", name = "F", frozen = true }),
		source({ key = "grok", provider = "grok", inFlight = true }),
	} }

	it("puts Claude accounts in one card with tabs and the rest in their own cards", function()
		local m = present.panel(v, 2, tr)
		assert.equal(m.title, "panel.title")
		assert.equal(m.refresh, "panel.refresh")
		assert.equal(m.busy, true)
		assert.deepEqual(m.tabs, { { label = "panel.active", selected = false }, { label = "F", selected = true } })
		assert.equal(m.claude.badge.text, "panel.frozen")
		assert.equal(#m.others, 1)
		assert.equal(m.others[1].title, "provider.grok")
	end)

	it("clamps the tab and hides tabs with one Claude account", function()
		assert.equal(present.panel(v, 9, tr).tabs[2].selected, true)
		local single = { now = 0, barKey = "claude", sources = { source({}), source({ key = "grok", provider = "grok" }) } }
		local m = present.panel(single, 1, tr)
		assert.deepEqual(m.tabs, {})
		assert.equal(m.busy, false)
	end)

	it("is empty before the first view", function()
		local m = present.panel(nil, 1, tr)
		assert.equal(m.claude, nil)
		assert.deepEqual(m.others, {})
	end)
end)
