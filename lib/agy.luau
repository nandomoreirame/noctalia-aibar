-- `agy -p "/quota" --output-format json` stdout (decoded) -> snapshot. The
-- command runs no model turn; agy authenticates and renews its own session, so
-- the plugin never sees an agy token.

local time = require("./time.luau")

local Agy = {}

Agy.ARGV = { "agy", "-p", "/quota", "--output-format", "json" }
local HOUR = 3600000
local SPAN = { ["5h"] = { key = "session", ms = 5 * HOUR }, weekly = { key = "weekly", ms = 168 * HOUR } }

function Agy.parseQuota(data: any, nowMs: number)
	if typeof(data) ~= "table" or data.status ~= "SUCCESS" then
		return { ok = false, error = "agy-login" }
	end
	local command = if typeof(data.command) == "table" then data.command else {}
	local body = if typeof(command.data) == "table" then command.data else {}
	local windows = {}
	for _, group in (if typeof(body.groups) == "table" then body.groups else {}) do
		if typeof(group) == "table" and typeof(group.buckets) == "table" then
			for _, b in group.buckets do
				if typeof(b) == "table" and typeof(b.id) == "string" and typeof(b.remaining_fraction) == "number" then
					local span = SPAN[b.window]
					local endMs = time.parseIso(b.reset_time)
					table.insert(windows, {
						id = b.id,
						group = if typeof(group.name) == "string" then group.name else "",
						span = if span then span.key else "quota",
						percent = math.clamp((1 - b.remaining_fraction) * 100, 0, 100),
						startMs = if span and endMs ~= nil then endMs - span.ms else nil,
						endMs = endMs,
					})
				end
			end
		end
	end
	if #windows == 0 then
		return { ok = false, error = "parse" }
	end
	-- Each group blocks on its own: the bar shows the most-used window.
	return { ok = true, snapshot = { provider = "agy", plan = "", primary = "max", windows = windows, products = {}, fetchedAt = nowMs } }
end

return Agy
