-- api.anthropic.com/api/oauth/usage (decoded) -> normalized snapshot.
-- Request contract (service): GET with Authorization: Bearer <token>,
-- anthropic-beta: oauth-2025-04-20, User-Agent: claude-cli/<ver> (external, cli).

local time = require("./time.luau")

local Claude = {}

Claude.API_URL = "https://api.anthropic.com/api/oauth/usage"
Claude.BETA = "oauth-2025-04-20"
local HOUR = 3600000
Claude.WINDOW_MS = { session = 5 * HOUR, weekly = 168 * HOUR, ["weekly-opus"] = 168 * HOUR, ["weekly-sonnet"] = 168 * HOUR }
local KEYS = { { "five_hour", "session" }, { "seven_day", "weekly" }, { "seven_day_opus", "weekly-opus" }, { "seven_day_sonnet", "weekly-sonnet" } }

local function windowFrom(raw: any, id: string): any
	if typeof(raw) ~= "table" or typeof(raw.utilization) ~= "number" then
		return nil
	end
	local endMs = time.parseIso(raw.resets_at)
	return {
		id = id,
		percent = raw.utilization,
		startMs = if endMs ~= nil then endMs - Claude.WINDOW_MS[id] else nil,
		endMs = endMs,
	}
end

local function extraFrom(raw: any): any
	if typeof(raw) ~= "table" or typeof(raw.monthly_limit) ~= "number" then
		return nil
	end
	local scale = 10 ^ (tonumber(raw.decimal_places) or 0)
	return {
		enabled = raw.is_enabled == true,
		used = (tonumber(raw.used_credits) or 0) / scale,
		limit = raw.monthly_limit / scale,
		percent = tonumber(raw.utilization) or 0,
		currency = tostring(raw.currency or ""),
	}
end

function Claude.parseUsage(data: any, plan: string?, nowMs: number)
	if typeof(data) ~= "table" then
		return { ok = false, error = "parse" }
	end
	local windows = {}
	for _, k in KEYS do
		local w = windowFrom(data[k[1]], k[2])
		if w then
			table.insert(windows, w)
		end
	end
	if #windows == 0 then
		return { ok = false, error = "parse" }
	end
	return {
		ok = true,
		snapshot = { provider = "claude", plan = plan or "", windows = windows, extra = extraFrom(data.extra_usage), products = {}, fetchedAt = nowMs },
	}
end

return Claude
