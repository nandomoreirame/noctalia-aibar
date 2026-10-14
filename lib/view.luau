-- The plain `view` value the service publishes on noctalia.state (see the plan
-- header). Copied across entry VMs, so it holds data only: never a token.

local accounts = require("./accounts.luau")
local pace = require("./pace.luau")

local View = {}

function View.build(sources: any, states: any, identities: any, barKey: string, nowMs: number)
	local list = {}
	for _, s in sources do
		local st = states[s.key] or {}
		local id = identities[s.key]
		table.insert(list, {
			key = s.key,
			provider = s.provider,
			name = s.name,
			frozen = s.frozen,
			email = if id then id.email else "",
			snapshot = pace.project(st.snapshot, nowMs),
			stale = st.stale == true,
			error = st.error or "",
			code = st.code or 0,
			retryAt = st.retryAt or 0,
			inFlight = st.inFlight == true,
		})
	end
	return { sources = list, barKey = barKey, now = nowMs }
end

-- The persisted middle-click choice wins at start while its source exists.
function View.initialKey(sources: any, persisted: any, setting: any): string
	if typeof(persisted) == "string" and accounts.indexOfKey(sources, persisted) > 0 then
		return persisted
	end
	return accounts.resolveKey(sources, accounts.normalizeKey(setting))
end

return View
