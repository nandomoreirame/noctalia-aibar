-- ISO 8601 timestamps (as the usage APIs send them) to UTC epoch milliseconds.
-- No os.time: it converts through the local timezone.

local Time = {}

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant).
local function daysFromCivil(y: number, m: number, d: number): number
	if m <= 2 then
		y -= 1
	end
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

function Time.parseIso(text: any): number?
	if typeof(text) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, s, rest = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
	if y == nil then
		return nil
	end
	local frac, zone = string.match(rest, "^%.(%d+)(.*)$")
	if frac == nil then
		frac, zone = "", rest
	end
	local offsetMin = 0
	if zone ~= "Z" and zone ~= "z" then
		local sign, oh, om = string.match(zone, "^([+-])(%d%d):?(%d%d)$")
		if sign == nil then
			return nil
		end
		offsetMin = (tonumber(oh) * 60 + tonumber(om)) * (if sign == "-" then -1 else 1)
	end
	local Y, M, D = tonumber(y), tonumber(mo), tonumber(d)
	local H, MI, S = tonumber(h), tonumber(mi), tonumber(s)
	if M < 1 or M > 12 or D < 1 or D > 31 or H > 23 or MI > 59 or S > 60 then
		return nil
	end
	local ms = tonumber(string.sub(frac .. "000", 1, 3))
	local seconds = daysFromCivil(Y, M, D) * 86400 + H * 3600 + MI * 60 + S - offsetMin * 60
	return seconds * 1000 + ms
end

return Time
