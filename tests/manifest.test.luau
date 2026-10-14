local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")

local describe, it = runner.describe, runner.it

local function flatten(t, prefix, out)
	for k, v in t do
		local key = if prefix == "" then k else prefix .. "." .. k
		if typeof(v) == "table" then
			flatten(v, key, out)
		else
			out[key] = v
		end
	end
	return out
end

local function sortedKeys(map)
	local list = {}
	for k in map do
		table.insert(list, k)
	end
	table.sort(list)
	return list
end

local en = flatten(mock.json.decode(modules.text("translations/en.json")), "", {})
local pt = flatten(mock.json.decode(modules.text("translations/pt-BR.json")), "", {})
local toml = modules.text("plugin.toml")

describe("translations", function()
	it("en and pt-BR have the same keys", function()
		assert.deepEqual(sortedKeys(pt), sortedKeys(en))
		assert.equal(#sortedKeys(en) > 30, true)
	end)

	it("no empty strings", function()
		for key, value in en do
			assert.equal(value ~= "" and pt[key] ~= "", true)
		end
	end)

	it("cover every label and description key of the manifest", function()
		local count = 0
		for key in string.gmatch(toml, '_key%s*=%s*"([^"]+)"') do
			count += 1
			if en[key] == nil then
				error("missing translation: " .. key)
			end
		end
		assert.equal(count, 9)
	end)
end)

describe("plugin.toml", function()
	it("declares the id, api level, version and entries", function()
		for _, needle in { 'id = "nandomoreirame/aibar"', "plugin_api = 22", 'version = "0.2.0"', 'entry = "service.luau"', 'entry = "widget.luau"', 'entry = "panel.luau"', 'middle = "none"' } do
			if string.find(toml, needle, 1, true) == nil then
				error("plugin.toml lacks " .. needle)
			end
		end
	end)

	it("keeps the description within 120 characters", function()
		local description = string.match(toml, '\ndescription%s*=%s*"([^"]*)"')
		assert.equal(description ~= nil and utf8.len(description) <= 120, true)
	end)
end)

describe("lib purity", function()
	it("lib modules never touch host globals", function()
		for _, name in { "accounts", "claude", "creds", "format", "grok", "notify", "pace", "poll", "present", "time", "view" } do
			-- Comments and string literals may name host APIs; only code counts.
			local source = string.gsub(modules.text("lib/" .. name .. ".luau"), "%-%-[^\n]*", "")
			source = string.gsub(source, '"[^"\n]*"', '""')
			for _, global in { "noctalia%.", "barWidget%.", "panel%.", "ui%." } do
				if string.find(source, "%f[%w_]" .. global) then
					error(name .. " uses " .. global)
				end
			end
		end
	end)
end)
