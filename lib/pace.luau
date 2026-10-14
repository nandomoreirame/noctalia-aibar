-- Usage versus elapsed time of a window, status colors and window selection.

local Pace = {}

Pace.CRITICAL = 90
Pace.AHEAD_POINTS = 10
local PRIMARY = { "session", "period" }

local function round(x: number): number
	return math.floor(x + 0.5)
end

-- { elapsed, delta } in percent / points; {} when the window has no bounds.
function Pace.pace(w: any, nowMs: number)
	if not w or w.startMs == nil or w.endMs == nil or not (w.endMs > w.startMs) then
		return {}
	end
	local elapsed = math.clamp((nowMs - w.startMs) / (w.endMs - w.startMs) * 100, 0, 100)
	return { elapsed = round(elapsed), delta = round(w.percent - elapsed) }
end

function Pace.status(w: any, nowMs: number): string
	if not w then
		return "ok"
	end
	if w.percent >= Pace.CRITICAL then
		return "critical"
	end
	local p = Pace.pace(w, nowMs)
	if p.delta ~= nil and p.delta > Pace.AHEAD_POINTS then
		return "ahead"
	end
	return "ok"
end

-- The window the bar shows: Claude's 5 h session, Grok's period, else the first.
function Pace.primaryWindow(snapshot: any): any
	if not snapshot or not snapshot.windows or #snapshot.windows == 0 then
		return nil
	end
	for _, id in PRIMARY do
		for _, w in snapshot.windows do
			if w.id == id then
				return w
			end
		end
	end
	return snapshot.windows[1]
end

-- A cached snapshot can outlive its windows: one whose reset passed is shown as
-- 0% without bounds. Same table when nothing reset.
function Pace.project(snapshot: any, nowMs: number): any
	if not snapshot or not snapshot.windows then
		return snapshot
	end
	local changed = false
	local windows = {}
	for i, w in snapshot.windows do
		if w.endMs == nil or w.endMs > nowMs then
			windows[i] = w
		else
			changed = true
			local copy = table.clone(w)
			copy.percent = 0
			copy.startMs = nil
			copy.endMs = nil
			windows[i] = copy
		end
	end
	if not changed then
		return snapshot
	end
	local out = table.clone(snapshot)
	out.windows = windows
	return out
end

-- The window at 100% that unblocks last, or nil.
function Pace.exhausted(snapshot: any, nowMs: number): any
	if not snapshot or not snapshot.windows then
		return nil
	end
	local found = nil
	for _, w in snapshot.windows do
		if typeof(w.percent) == "number" and w.percent >= 100 and w.endMs ~= nil and w.endMs > nowMs then
			if found == nil or w.endMs > found.endMs then
				found = w
			end
		end
	end
	return found
end

return Pace
