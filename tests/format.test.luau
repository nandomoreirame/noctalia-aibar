local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")

local describe, it = runner.describe, runner.it
local format = modules.load("lib/format.luau")
local M = 60000

describe("format", function()
	it("formats a countdown as d/h/m", function()
		assert.equal(format.countdown(72 * M, 0), "1h12m")
		assert.equal(format.countdown(45 * M, 0), "45m")
		assert.equal(format.countdown((3 * 1440 + 4 * 60 + 30) * M, 0), "3d4h")
		assert.equal(format.countdown(-5, 0), "0m")
		assert.equal(format.countdown(nil, 0), "")
	end)

	it("rounds percent", function()
		assert.equal(format.percentText(47.4), "47%")
		assert.equal(format.percentText(46.5), "47%")
		assert.equal(format.percentText(nil), "—")
	end)

	it("builds the bar text", function()
		assert.equal(format.barText({ percent = 47, endMs = 72 * M }, 0), "47% · 1h12m")
		assert.equal(format.barText({ percent = 47 }, 0), "47%")
		assert.equal(format.barText(nil, 0), "—")
	end)

	it("counts minutes since a fetch and tells how long ago", function()
		assert.equal(format.minutesAgo(0, 30000), 0)
		assert.equal(format.minutesAgo(0, 5 * M + 1), 5)
		assert.equal(format.ago(0, 5 * M), "5m")
		assert.equal(format.ago(0, 125 * M), "2h5m")
		assert.equal(format.ago(0, 3 * 1440 * M), "3d0h")
	end)

	it("maps a window to its i18n key", function()
		assert.equal(format.windowKey({ id = "session" }), "window.session")
		assert.equal(format.windowKey({ id = "weekly-opus" }), "window.weekly-opus")
		assert.equal(format.windowKey({ id = "period", periodType = "monthly" }), "window.period-monthly")
		assert.equal(format.windowKey({ id = "period", periodType = "weekly" }), "window.period-weekly")
		assert.equal(format.windowKey({ id = "period" }), "window.period-weekly")
	end)

	it("maps a request error to an i18n key and its vars", function()
		assert.equal(format.errorMessage(nil, "claude", 0), nil)
		assert.equal(format.errorMessage({ error = "" }, "claude", 0), nil)
		assert.deepEqual(format.errorMessage({ error = "auth" }, "claude", 0), { key = "error.claude-expired" })
		assert.deepEqual(format.errorMessage({ error = "auth" }, "grok", 0), { key = "error.grok-login" })
		assert.deepEqual(format.errorMessage({ error = "http", code = 503 }, "grok", 0), { key = "error.http", vars = { code = 503 } })
		assert.deepEqual(format.errorMessage({ error = "rate-limited", retryAt = 90000 }, "claude", 0), { key = "error.rate-limited", vars = { n = 2 } })
		assert.deepEqual(format.errorMessage({ error = "rate-limited", retryAt = 0 }, "claude", 5 * M), { key = "error.rate-limited", vars = { n = 0 } })
		assert.deepEqual(format.errorMessage({ error = "network" }, "claude", 0), { key = "error.network" })
	end)

	it("hides login errors when quiet, but keeps the others", function()
		for _, e in { "auth", "grok-login", "claude-expired", "claude-login" } do
			assert.equal(format.errorMessage({ error = e }, "grok", 0, true), nil)
		end
		assert.deepEqual(format.errorMessage({ error = "network" }, "grok", 0, true), { key = "error.network" })
		assert.deepEqual(format.errorMessage({ error = "auth" }, "grok", 0, false), { key = "error.grok-login" })
	end)

	it("describes a reached limit with its reset countdown", function()
		assert.deepEqual(format.limitMessage({ percent = 100, endMs = 72 * M }, 0), { key = "panel.limit-reached", vars = { t = "1h12m" } })
		assert.equal(format.limitMessage(nil, 0), nil)
	end)

	it("formats extra usage money with two decimals and the given separator", function()
		local extra = { used = 33.5, limit = 90, currency = "BRL" }
		assert.equal(format.moneyText(extra, ","), "33,50 / 90,00 BRL")
		assert.equal(format.moneyText(extra, "."), "33.50 / 90.00 BRL")
		assert.equal(format.moneyText({ used = 0.1 + 0.2, limit = 5, currency = "" }, "."), "0.30 / 5.00")
		assert.equal(format.moneyText({ used = 1, limit = 2, currency = "USD" }), "1.00 / 2.00 USD")
		assert.equal(format.moneyText(nil, ","), "")
	end)
end)
