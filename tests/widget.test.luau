local assert = require("./support/assert")
local runner = require("./support/runner")
local mock = require("./support/noctalia_mock")
local entry = require("./support/entry")

local describe, it = runner.describe, runner.it
local H = 3600000

local VIEW = {
	now = 3 * H,
	barKey = "claude",
	sources = {
		{ key = "claude", provider = "claude", name = "", frozen = false, email = "", stale = true, error = "network", code = 0, retryAt = 0, inFlight = false,
			snapshot = { provider = "claude", plan = "max", windows = { { id = "session", percent = 47, startMs = 0, endMs = 5 * H } }, products = {}, fetchedAt = 0 } },
		{ key = "grok", provider = "grok", name = "", frozen = false, email = "", stale = false, error = "", code = 0, retryAt = 0, inFlight = false },
	},
}

local function lastRender(loaded)
	local calls = mock.calls(loaded.env, "barWidget.render")
	return calls[#calls][1]
end

describe("widget", function()
	it("renders glyph and a dash before the service publishes", function()
		local w = entry.load("widget.luau", {})
		local tree = lastRender(w)
		assert.equal(tree.type, "row")
		assert.equal(tree.children[1].props.name, "asterisk")
		assert.equal(tree.children[2].props.text, "—")
	end)

	it("renders label, dimmed when stale, and a colored progress bar", function()
		local w = entry.load("widget.luau", {})
		w.env.noctalia.state.set("view", VIEW)
		local tree = lastRender(w)
		assert.equal(tree.children[2].props.text, "47% · 2h0m")
		assert.equal(tree.children[2].props.opacity, 0.6)
		local bar = tree.children[3]
		assert.equal(bar.type, "progress")
		assert.equal(bar.props.progress, 0.47)
		assert.equal(bar.props.fill, "primary")
		assert.equal(bar.props.width, 40)
		local tips = mock.calls(w.env, "barWidget.setTooltip")
		assert.deepEqual(tips[#tips][1][1], { "window.session", "47% · panel.resets t=2h0m" })
	end)

	it("stacks glyph and progress on a vertical bar", function()
		local w = entry.load("widget.luau", { vertical = true })
		w.env.noctalia.state.set("view", VIEW)
		local tree = lastRender(w)
		assert.equal(tree.type, "column")
		assert.equal(#tree.children, 2)
		assert.equal(tree.children[2].type, "progress")
	end)

	it("toggles the panel on click and asks the service to cycle on middle click", function()
		local w = entry.load("widget.luau", {})
		w.call("onClick")
		assert.deepEqual(mock.calls(w.env, "noctalia.togglePanel")[1], { "nandomoreirame/aibar:panel" })
		w.call("onMiddleClick")
		w.call("onMiddleClick")
		assert.equal(w.env.noctalia.state.get("cmd.cycle"), 2)
	end)

	it("uses the current noctalia.tr on every render", function()
		local w = entry.load("widget.luau", {})
		w.env.noctalia.tr = function(key)
			return "T:" .. key
		end
		w.env.noctalia.state.set("view", VIEW)
		local tips = mock.calls(w.env, "barWidget.setTooltip")
		assert.equal(tips[#tips][1][1][1], "T:window.session")
	end)
end)
