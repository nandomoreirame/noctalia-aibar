local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")

local describe, it = runner.describe, runner.it
local agy = modules.load("lib/agy.luau")
local NOW = 1793110000000
local H = 3600000
local WEEKLY_END = 1793716953000 -- 2026-11-03T14:42:33Z
local FIVE_END = 1793130153000 -- 2026-10-27T19:42:33Z
local ARGON_END = 1793451689000 -- 2026-10-31T13:01:29Z

local function fixture(name)
	return mock.json.decode(modules.text("tests/fixtures/" .. name))
end

describe("agy.parseQuota", function()
	it("maps every bucket to a window with its group and span", function()
		local r = agy.parseQuota(fixture("agy-quota.json"), NOW)
		assert.equal(r.ok, true)
		local w = r.snapshot.windows
		assert.equal(#w, 5)
		assert.deepEqual(w[1], { id = "gemini-weekly", group = "Gemini Models", span = "weekly", percent = 0, startMs = WEEKLY_END - 168 * H, endMs = WEEKLY_END })
		assert.deepEqual(w[2], { id = "gemini-5h", group = "Gemini Models", span = "session", percent = 0, startMs = FIVE_END - 5 * H, endMs = FIVE_END })
		assert.equal(w[3].group, "Claude and GPT models")
		assert.deepEqual(w[5], { id = "gemini-argon-wtu-weekly", group = "Gemini 4 Argon", span = "weekly", percent = 100, startMs = ARGON_END - 168 * H, endMs = ARGON_END })
		assert.equal(r.snapshot.primary, "max")
		assert.equal(r.snapshot.provider, "agy")
		assert.equal(r.snapshot.fetchedAt, NOW)
	end)

	it("keeps an unknown window kind as a plain quota without bounds", function()
		local data = { status = "SUCCESS", command = { data = { groups = { { name = "G", buckets = { { id = "x", window = "daily", remaining_fraction = 0.25, reset_time = "2026-10-27T19:42:33Z" } } } } } } }
		assert.deepEqual(agy.parseQuota(data, NOW).snapshot.windows, { { id = "x", group = "G", span = "quota", percent = 75, endMs = FIVE_END } })
	end)

	it("refuses a failed run and an empty summary", function()
		assert.deepEqual(agy.parseQuota({ status = "ERROR", error = "Individual quota reached." }, NOW), { ok = false, error = "agy-login" })
		assert.deepEqual(agy.parseQuota(nil, NOW), { ok = false, error = "agy-login" })
		assert.deepEqual(agy.parseQuota({ status = "SUCCESS", command = { data = { groups = {} } } }, NOW), { ok = false, error = "parse" })
	end)

	it("runs /quota in JSON print mode", function()
		assert.deepEqual(agy.ARGV, { "agy", "-p", "/quota", "--output-format", "json" })
	end)
end)
