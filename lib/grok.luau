-- cli-chat-proxy.grok.com/v1/billing?format=credits (decoded) -> normalized snapshot.
-- Request contract (service): GET with Authorization: Bearer <key>,
-- X-XAI-Token-Auth: xai-grok-cli. Without format=credits the server answers a
-- legacy shape with no percent (refused as "grok-format").

local time = require("./time.luau")

local Grok = {}

Grok.API_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
Grok.TOKEN_AUTH = "xai-grok-cli"

function Grok.parseBilling(data: any, nowMs: number)
	local c = if typeof(data) == "table" then data.config else nil
	if typeof(c) ~= "table" then
		return { ok = false, error = "parse" }
	end
	-- The server drops zero fields (protobuf JSON): a period without a percent
	-- is a fresh one at 0%. The legacy shape has neither.
	local hasPercent = typeof(c.creditUsagePercent) == "number"
	if not hasPercent and typeof(c.currentPeriod) ~= "table" then
		return { ok = false, error = "grok-format" }
	end
	local p = if typeof(c.currentPeriod) == "table" then c.currentPeriod else {}
	local window = {
		id = "period",
		periodType = if string.find(tostring(p.type or ""), "MONTHLY", 1, true) then "monthly" else "weekly",
		percent = if hasPercent then c.creditUsagePercent else 0,
		startMs = time.parseIso(p.start),
		endMs = time.parseIso(p["end"]),
	}
	local products = {}
	if typeof(c.productUsage) == "table" then
		for _, x in c.productUsage do
			if typeof(x) == "table" and typeof(x.usagePercent) == "number" then
				table.insert(products, { name = tostring(x.product or ""), percent = x.usagePercent })
			end
		end
	end
	return { ok = true, snapshot = { provider = "grok", plan = "", windows = { window }, products = products, fetchedAt = nowMs } }
end

return Grok
