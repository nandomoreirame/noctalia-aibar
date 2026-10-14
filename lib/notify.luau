-- armed: { ["<source>|<window>"] = <endMs of the window that already fired, or -1> }.
-- A window fires once per reset period; dropping below the threshold re-arms it.

local Notify = {}

local NO_END = -1

function Notify.crossings(snapshot: any, armed: any, threshold: any, source: string?)
	local nextArmed = table.clone(armed or {})
	local fire = {}
	if not snapshot or typeof(threshold) ~= "number" or threshold <= 0 then
		return { fire = fire, armed = nextArmed }
	end
	for _, w in snapshot.windows or {} do
		local key = (source or snapshot.provider) .. "|" .. w.id
		local stamp = if w.endMs ~= nil then w.endMs else NO_END
		if w.percent < threshold then
			nextArmed[key] = nil
		elseif nextArmed[key] ~= stamp then
			nextArmed[key] = stamp
			table.insert(fire, { provider = snapshot.provider, id = w.id, periodType = w.periodType, percent = w.percent, endMs = w.endMs })
		end
	end
	return { fire = fire, armed = nextArmed }
end

return Notify
