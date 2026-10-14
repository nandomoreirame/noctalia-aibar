local assert = require("./support/assert")
local runner = require("./support/runner")
local mock = require("./support/noctalia_mock")
local entry = require("./support/entry")

local describe, it = runner.describe, runner.it
local H = 3600000

local function src(fields)
	local s = { key = "claude", provider = "claude", name = "", frozen = false, email = "", stale = false, error = "", code = 0, retryAt = 0, inFlight = false }
	for k, v in fields do
		s[k] = v
	end
	return s
end

local SNAP = { provider = "claude", plan = "max", windows = { { id = "session", percent = 47, startMs = 0, endMs = 5 * H } }, products = {}, fetchedAt = 0 }
local VIEW = { now = 0, barKey = "claude", sources = {
	src({ email = "a@x.dev", snapshot = SNAP }),
	src({ key = "claude:f", name = "F", frozen = true }),
	src({ key = "grok", provider = "grok", error = "grok-login" }),
} }

local function walk(node, out)
	out = out or {}
	if typeof(node) == "table" and node.type then
		table.insert(out, node)
		for _, child in node.children or {} do
			walk(child, out)
		end
	end
	return out
end

local function texts(loaded)
	local calls = mock.calls(loaded.env, "panel.render")
	local list = {}
	for _, node in walk(calls[#calls][1]) do
		if node.props.text then
			table.insert(list, node.props.text)
		end
	end
	return list
end

local function find(loaded, pred)
	local calls = mock.calls(loaded.env, "panel.render")
	for _, node in walk(calls[#calls][1]) do
		if pred(node) then
			return node
		end
	end
	return nil
end

local function has(list, value)
	for _, v in list do
		if v == value then
			return true
		end
	end
	return false
end

describe("panel", function()
	it("renders the title, both cards and their content on open", function()
		local p = entry.load("panel.luau", {})
		p.env.noctalia.state.set("view", VIEW)
		p.call("onOpen")
		local t = texts(p)
		assert.equal(has(t, "panel.title"), true)
		assert.equal(has(t, "provider.claude"), true)
		assert.equal(has(t, "Max"), true)
		assert.equal(has(t, "a@x.dev"), true)
		assert.equal(has(t, "window.session"), true)
		assert.equal(has(t, "47%"), true)
		assert.equal(has(t, "provider.grok"), true)
		assert.equal(has(t, "error.grok-login"), true)
		assert.equal(find(p, function(n) return n.type == "progress" end).props.progress, 0.47)
	end)

	it("switches the Claude card to a frozen account", function()
		local p = entry.load("panel.luau", {})
		p.env.noctalia.state.set("view", VIEW)
		p.call("onOpen")
		local tab = find(p, function(n) return n.type == "button" and n.props.text == "F" end)
		assert.equal(tab.props.selected, false)
		tab.props.onClick()
		assert.equal(has(texts(p), "panel.frozen"), true)
		assert.equal(find(p, function(n) return n.type == "button" and n.props.text == "F" end).props.selected, true)
		p.call("onClose")
		p.call("onOpen")
		assert.equal(find(p, function(n) return n.type == "button" and n.props.text == "F" end).props.selected, false)
	end)

	it("asks the service to refresh and disables the button while busy", function()
		local p = entry.load("panel.luau", {})
		p.env.noctalia.state.set("view", VIEW)
		p.call("onOpen")
		local button = find(p, function(n) return n.type == "button" and n.props.glyph == "refresh" end)
		assert.equal(button.props.enabled, true)
		assert.equal(button.props.tooltip, "panel.refresh")
		button.props.onClick()
		assert.equal(p.env.noctalia.state.get("cmd.refresh"), 1)
		local busy = table.clone(VIEW)
		busy.sources = { src({ inFlight = true }) }
		p.env.noctalia.state.set("view", busy)
		assert.equal(find(p, function(n) return n.type == "button" and n.props.glyph == "refresh" end).props.enabled, false)
	end)

	it("does not render while closed", function()
		local p = entry.load("panel.luau", {})
		p.env.noctalia.state.set("view", VIEW)
		assert.equal(#mock.calls(p.env, "panel.render"), 0)
	end)
end)
