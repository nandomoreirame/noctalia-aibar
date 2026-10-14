-- Text pieces shared by the bar, tooltip, panel and notifications. Returns
-- i18n keys and vars, never translated text.

local Format = {}

function Format.countdown(endMs: number?, nowMs: number): string
	if endMs == nil then
		return ""
	end
	local min = math.max(0, math.floor((endMs - nowMs) / 60000))
	local d = min // 1440
	local h = (min % 1440) // 60
	local m = min % 60
	if d > 0 then
		return d .. "d" .. h .. "h"
	end
	if h > 0 then
		return h .. "h" .. m .. "m"
	end
	return m .. "m"
end

function Format.percentText(p: any): string
	if typeof(p) ~= "number" then
		return "—"
	end
	return math.floor(p + 0.5) .. "%"
end

-- "47% · 1h12m" for the primary window; "—" without data.
function Format.barText(w: any, nowMs: number): string
	if not w then
		return "—"
	end
	local reset = Format.countdown(w.endMs, nowMs)
	if reset == "" then
		return Format.percentText(w.percent)
	end
	return Format.percentText(w.percent) .. " · " .. reset
end

function Format.minutesAgo(fetchedAt: number, nowMs: number): number
	return math.max(0, math.floor((nowMs - fetchedAt) / 60000))
end

-- "5m", "2h5m", "3d0h" since fetchedAt.
function Format.ago(fetchedAt: number, nowMs: number): string
	return Format.countdown(nowMs, fetchedAt)
end

function Format.windowKey(w: any): string
	if w.id == "period" then
		return "window.period-" .. (if w.periodType == "monthly" then "monthly" else "weekly")
	end
	return "window." .. w.id
end

local LOGIN_ERRORS = { auth = true, ["grok-login"] = true, ["claude-login"] = true, ["claude-expired"] = true }

-- { key, vars? } for a source's request error; nil when there is none. quiet
-- hides login errors: the CLIs renew their token only when used, so an expired
-- one is expected while a plan is blocked or an account is frozen.
function Format.errorMessage(usage: any, provider: string, nowMs: number, quiet: boolean?): any
	if not usage or usage.error == nil or usage.error == "" then
		return nil
	end
	local e = usage.error
	if quiet and LOGIN_ERRORS[e] then
		return nil
	end
	if e == "auth" then
		return { key = if provider == "grok" then "error.grok-login" else "error.claude-expired" }
	end
	if e == "http" then
		return { key = "error.http", vars = { code = usage.code } }
	end
	if e == "rate-limited" then
		return { key = "error.rate-limited", vars = { n = math.max(0, math.ceil(((usage.retryAt or 0) - nowMs) / 60000)) } }
	end
	return { key = "error." .. e }
end

function Format.limitMessage(w: any, nowMs: number): any
	if not w then
		return nil
	end
	return { key = "panel.limit-reached", vars = { t = Format.countdown(w.endMs, nowMs) } }
end

-- "33,50 / 90,00 BRL"; the decimal separator comes from the UI language.
function Format.moneyText(extra: any, decimalSep: string?): string
	if not extra then
		return ""
	end
	local function amount(n: number): string
		local text = string.format("%.2f", n)
		if decimalSep == "," then
			text = (string.gsub(text, "%.", ","))
		end
		return text
	end
	local currency = if extra.currency and extra.currency ~= "" then " " .. extra.currency else ""
	return amount(extra.used) .. " / " .. amount(extra.limit) .. currency
end

return Format
