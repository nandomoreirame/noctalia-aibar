-- Go's read-only quota endpoint. Percentages describe the shared allowance,
-- not independent model budgets. The response does not identify the plan tier.
local time = require("./time.luau")
local OpenCode = {}

OpenCode.API_URL = "https://opencode.ai/zen/go/v1/usage"
OpenCode.USER_AGENT = "opencode/2.2.1"
OpenCode.DB_PATH = "~/.local/share/opencode/opencode.db"
-- Match the current Console integration, then its selected credential. The
-- database is read-only; other integrations are never selected.
OpenCode.CREDENTIAL_QUERY = "SELECT value FROM credential WHERE integration_id IN ('opencode', 'opencode-go') ORDER BY CASE integration_id WHEN 'opencode' THEN 0 ELSE 1 END, active DESC, time_created DESC, id DESC LIMIT 1"

function OpenCode.credentialArgv(dbPath: string): { string }
	return { "sqlite3", "-readonly", dbPath, OpenCode.CREDENTIAL_QUERY }
end

function OpenCode.parseUsage(data: any, nowMs: number)
	local usage = if typeof(data) == "table" then data.usage else nil
	if typeof(usage) ~= "table" then
		return { ok = false, error = "parse" }
	end
	local windows = {}
	for _, slot in { { "rolling", "session" }, { "weekly", "weekly" }, { "monthly", "period" } } do
		local raw = usage[slot[1]]
		if typeof(raw) ~= "table" or typeof(raw.percent) ~= "number" or not (raw.percent >= 0 and raw.percent < math.huge) then
			return { ok = false, error = "parse" }
		end
		local endMs = time.parseIso(raw.resetsAt)
		if endMs == nil or (raw.status ~= "ok" and raw.status ~= "rate-limited") then
			return { ok = false, error = "parse" }
		end
		-- The API provides no start timestamp. In particular, do not assume a
		-- 30-day month or infer an elapsed-time pace for the rolling quota.
		table.insert(windows, {
			id = slot[2],
			periodType = if slot[1] == "monthly" then "monthly" else nil,
			percent = raw.percent,
			endMs = endMs,
		})
	end
	return { ok = true, snapshot = { provider = "opencode", plan = "", primary = "max", windows = windows, products = {}, fetchedAt = nowMs } }
end

return OpenCode
