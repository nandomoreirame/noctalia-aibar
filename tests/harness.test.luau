local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local entry = require("./support/entry")

local describe, it = runner.describe, runner.it

describe("harness", function()
	it("loads a module that requires a sibling with the host .luau form", function()
		local probe = modules.load("tests/support/fixtures/probe.luau")
		assert.equal(probe.answer(), 42)
	end)

	it("caches a module by path", function()
		assert.equal(modules.load("tests/support/fixtures/probe.luau"), modules.load("tests/support/fixtures/probe.luau"))
	end)

	it("rejects require paths the host rejects", function()
		local req = modules.requirer("lib/x.luau")
		assert.throws(function()
			req("./y")
		end, "relative and end in .luau")
		assert.throws(function()
			req("lib/y.luau")
		end, "relative and end in .luau")
	end)

	it("reads data files wrapped by run-tests", function()
		local text = modules.text("tests/fixtures/grok-billing.json")
		assert.equal(string.find(text, "creditUsagePercent", 1, true) ~= nil, true)
	end)

	it("gives entries a host-style require", function()
		local loaded = entry.load("tests/support/fixtures/probe.luau", {})
		assert.equal(typeof(loaded.env.require), "function")
	end)
end)
