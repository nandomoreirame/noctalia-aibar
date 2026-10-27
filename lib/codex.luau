-- chatgpt.com/backend-api/wham/usage (decoded) -> normalized snapshot.
-- Request contract (service): GET with Authorization: Bearer <access_token>,
-- ChatGPT-Account-Id: <account_id> (when known), User-Agent: codex-cli.

local Codex = {}

Codex.API_URL = "https://chatgpt.com/backend-api/wham/usage"
Codex.USER_AGENT = "codex-cli"

-- A window's kind from its length; free plans send the weekly window as primary.
local function spanOf(seconds: number?, fallback: string): string
	if seconds ~= nil and seconds <= 6 * 3600 then
		return "session"
	end
	if seconds ~= nil and seconds >= 6 * 86400 then
		return "weekly"
	end
	return fallback
end

-- Notifications and the bar key windows by id, so a stable name beats a position.
local function slug(name: string): string
	local s = string.gsub(string.lower(name), "[^a-z0-9]+", "-")
	return (string.gsub(s, "^%-+", ""):gsub("%-+$", ""))
end

-- Appends the windows of one rate_limit block. group names an extra limit.
local function addLimit(windows: { any }, limit: any, prefix: string, group: string?, nowMs: number)
	if typeof(limit) ~= "table" then
		return
	end
	local used = {}
	for _, slot in { { limit.primary_window, "session" }, { limit.secondary_window, "weekly" } } do
		local raw = slot[1]
		if typeof(raw) == "table" and typeof(raw.used_percent) == "number" then
			local seconds = tonumber(raw.limit_window_seconds)
			local span = spanOf(seconds, slot[2])
			-- Two windows of one block can classify alike (a weekly primary plus a
			-- secondary without a length): the second gets a suffix.
			local id = prefix .. span
			if used[id] then
				id ..= "-2"
			end
			used[id] = true
			local endMs = nil
			if typeof(raw.reset_at) == "number" then
				endMs = raw.reset_at * 1000
			elseif typeof(raw.reset_after_seconds) == "number" then
				endMs = nowMs + raw.reset_after_seconds * 1000
			end
			local w: any = {
				id = id,
				percent = raw.used_percent,
				startMs = if endMs ~= nil and seconds ~= nil and seconds > 0 then endMs - seconds * 1000 else nil,
				endMs = endMs,
			}
			if group ~= nil then
				w.group = group
				w.span = span
			end
			table.insert(windows, w)
		end
	end
end

function Codex.parseUsage(data: any, nowMs: number)
	if typeof(data) ~= "table" then
		return { ok = false, error = "parse" }
	end
	local windows = {}
	addLimit(windows, data.rate_limit, "", nil, nowMs)
	-- A named pool can block while the main limit reads low (null means none).
	if typeof(data.additional_rate_limits) == "table" then
		for i, extra in data.additional_rate_limits do
			if typeof(extra) == "table" then
				local name = if typeof(extra.limit_name) == "string" and extra.limit_name ~= "" then extra.limit_name
					elseif typeof(extra.metered_feature) == "string" then extra.metered_feature
					else "#" .. i
				local key = slug(name)
				addLimit(windows, extra.rate_limit, "extra:" .. (if key ~= "" then key else tostring(i)) .. ":", name, nowMs)
			end
		end
	end
	if #windows == 0 then
		return { ok = false, error = "parse" }
	end
	return {
		ok = true,
		snapshot = { provider = "codex", plan = if typeof(data.plan_type) == "string" then data.plan_type else "", windows = windows, products = {}, fetchedAt = nowMs },
	}
end

return Codex
