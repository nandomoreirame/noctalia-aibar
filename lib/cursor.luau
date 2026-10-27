-- api2.cursor.sh DashboardService/GetCurrentPeriodUsage (decoded) -> snapshot.
-- Request contract (service): POST "{}" with Authorization: Bearer <token>,
-- Content-Type: application/json, Connect-Protocol-Version: 1. The token comes
-- from Cursor's state.vscdb through sqlite3; argv holds only the query.

local Cursor = {}

Cursor.API_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
Cursor.DB_PATH = "~/.config/Cursor/User/globalStorage/state.vscdb"
Cursor.TOKEN_QUERY = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"

-- dbPath must be expanded already: sqlite3 does not expand "~".
function Cursor.tokenArgv(dbPath: string): { string }
	return { "sqlite3", "-readonly", dbPath, Cursor.TOKEN_QUERY }
end

-- runAsync result -> { ok, token } | { ok = false, error = "cursor-login" }
function Cursor.tokenFrom(result: any)
	if typeof(result) ~= "table" or result.exitCode ~= 0 or typeof(result.stdout) ~= "string" then
		return { ok = false, error = "cursor-login" }
	end
	local token = string.match(result.stdout, "^%s*(.-)%s*$")
	if token == nil or token == "" or string.find(token, "%s") then
		return { ok = false, error = "cursor-login" }
	end
	return { ok = true, token = token }
end

local function percentOf(v: any): number
	return if typeof(v) == "number" then v else 0
end

-- Protobuf JSON drops zero fields: a missing percent is 0%.
function Cursor.parseUsage(data: any, nowMs: number)
	if typeof(data) ~= "table" then
		return { ok = false, error = "parse" }
	end
	local endMs = tonumber(data.billingCycleEnd)
	if typeof(data.planUsage) ~= "table" and endMs == nil then
		return { ok = false, error = "parse" }
	end
	local usage = if typeof(data.planUsage) == "table" then data.planUsage else {}
	return {
		ok = true,
		snapshot = {
			provider = "cursor",
			plan = "",
			windows = { { id = "period", periodType = "monthly", percent = percentOf(usage.totalPercentUsed), startMs = tonumber(data.billingCycleStart), endMs = endMs } },
			products = { { name = "Auto", percent = percentOf(usage.autoPercentUsed) }, { name = "API", percent = percentOf(usage.apiPercentUsed) } },
			fetchedAt = nowMs,
		},
	}
end

return Cursor
