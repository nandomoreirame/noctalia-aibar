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

	it("shows each provider's glyph, plan, grouped labels and products", function()
		local snap = { provider = "agy", plan = "", primary = "max", windows = { { id = "gemini-5h", group = "Gemini Models", span = "session", percent = 40, startMs = 0, endMs = 5 * H } }, products = {}, fetchedAt = 0 }
		local c = present.card(source({ key = "agy", provider = "agy", snapshot = snap }), H, tr)
		assert.equal(c.glyph, "brand-google")
		assert.equal(c.title, "provider.agy")
		assert.equal(c.rows[1].label, "Gemini Models · window.session")
		local codex = present.card(source({ key = "codex", provider = "codex", snapshot = { provider = "codex", plan = "plus", windows = {}, products = {}, fetchedAt = 0 } }), 0, tr)
		assert.equal(codex.glyph, "brand-openai")
		assert.equal(codex.plan, "Plus")
		local cur = present.card(source({ key = "cursor", provider = "cursor", snapshot = { provider = "cursor", plan = "", windows = {}, products = { { name = "Auto", percent = 12.5 } }, fetchedAt = 0 } }), 0, tr)
		assert.equal(cur.glyph, "pointer")
		assert.deepEqual(cur.products, { { name = "Auto", percentText = "13%" } })
	end)

	it("shows the most-used agy window in the bar with its group", function()
		local snap = { provider = "agy", primary = "max", windows = {
			{ id = "a", group = "G", span = "session", percent = 10, startMs = 0, endMs = 5 * H },
			{ id = "b", group = "Argon", span = "weekly", percent = 100, startMs = 0, endMs = 168 * H },
		}, products = {}, fetchedAt = 0 }
		local m = present.bar({ now = H, barKey = "agy", sources = { source({ key = "agy", provider = "agy", snapshot = snap }) } }, tr)
		assert.equal(m.glyph, "brand-google")
		assert.equal(m.label, "100% · 6d23h")
		assert.equal(m.tooltip[2][1], "Argon · window.weekly")
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
		assert.equal(c.rows[1].elapsed, 0.4)
		assert.equal(c.rows[2].fill, "error")
		assert.equal(c.extra.detail, "33.50 / 90.00 BRL")
		assert.equal(c.extra.elapsed, nil)
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
		source({ key = "codex", provider = "codex", error = "codex-login" }),
	} }

	it("lists one tab per provider in source order and shows the selected one", function()
		local m = present.panel(v, 1, tr, "codex")
		assert.equal(m.title, "panel.title")
		assert.equal(m.refresh, "panel.refresh")
		assert.equal(m.busy, true)
		assert.deepEqual(m.providers, {
			{ key = "claude", source = "claude", label = "Claude", selected = false },
			{ key = "grok", source = "grok", label = "Grok", selected = false },
			{ key = "codex", source = "codex", label = "Codex", selected = true },
		})
		assert.equal(m.section.title, "provider.codex")
		assert.equal(m.section.error, "error.codex-login")
		assert.deepEqual(m.tabs, {})
	end)

	it("keeps the Claude accounts as sub-tabs of the Claude tab", function()
		local m = present.panel(v, 2, tr, "claude")
		assert.deepEqual(m.tabs, { { key = "claude", label = "panel.active", selected = false }, { key = "claude:f", label = "F", selected = true } })
		assert.equal(m.section.badge.text, "panel.frozen")
		assert.equal(present.panel(v, 9, tr, "claude").tabs[2].selected, true)
	end)

	it("falls back to the first provider and hides sub-tabs with one Claude account", function()
		local single = { now = 0, barKey = "claude", sources = { source({}), source({ key = "grok", provider = "grok" }) } }
		local m = present.panel(single, 1, tr, "cursor")
		assert.equal(m.providers[1].selected, true)
		assert.equal(m.section.title, "provider.claude")
		assert.deepEqual(m.tabs, {})
		assert.equal(m.busy, false)
	end)

	it("is empty before the first view", function()
		local m = present.panel(nil, 1, tr)
		assert.equal(m.section, nil)
		assert.deepEqual(m.providers, {})
		assert.deepEqual(m.tabs, {})
	end)

	it("finds the account of the bar source among the Claude accounts", function()
		assert.equal(present.accountIndex(v, "claude:f"), 2)
		assert.equal(present.accountIndex(v, "claude"), 1)
		assert.equal(present.accountIndex(v, "codex"), 1)
		assert.equal(present.accountIndex(nil, "claude:f"), 1)
	end)

	it("builds a select command that changes even for the same key", function()
		assert.deepEqual(present.selectCommand(nil, "grok"), { key = "grok", n = 1 })
		assert.deepEqual(present.selectCommand({ key = "grok", n = 4 }, "grok"), { key = "grok", n = 5 })
		assert.deepEqual(present.selectCommand("junk", "codex"), { key = "codex", n = 1 })
	end)

	it("opens on the provider of the bar source", function()
		assert.equal(present.providerOf(v, "codex"), "codex")
		assert.equal(present.providerOf(v, "claude:f"), "claude")
		assert.equal(present.providerOf(nil, "x"), "claude")
	end)
end)

describe("present helpers", function()
	it("wraps a host translator, passing vars only when given", function()
		local seen = {}
		local t = present.translator(function(...)
			seen = { ... }
			return "x"
		end)
		assert.equal(t("a.b"), "x")
		assert.equal(#seen, 1)
		t("a.b", { n = 1 })
		assert.equal(#seen, 2)
	end)

	it("bumps a command counter from any stored value", function()
		assert.equal(present.bump(nil), 1)
		assert.equal(present.bump(4), 5)
		assert.equal(present.bump("2"), 3)
	end)
end)
