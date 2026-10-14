-- Per-source request state. Plain data, replaced (never mutated) on every step.
-- error: "" | "network" | "http" | "auth" | "rate-limited" | "parse" | "grok-format"
--        | "claude-login" | "claude-expired" | "grok-login"

local Poll = {}

Poll.BACKOFF_MS = 5 * 60000
-- noctalia.http times out at 30 s; this guard also covers a callback lost to a
-- reload or suspend.
Poll.REQUEST_TIMEOUT_MS = 30000

local function with(s: any, fields: any): any
	local out = table.clone(s)
	for k, v in fields do
		out[k] = v
	end
	return out
end

function Poll.createState()
	return { inFlight = false, startedAt = 0, stale = false, error = "", code = 0, retryAt = 0 }
end

function Poll.canRequest(s: any, nowMs: number): boolean
	local free = not s.inFlight or nowMs - s.startedAt >= Poll.REQUEST_TIMEOUT_MS
	return free and nowMs >= s.retryAt
end

function Poll.begin(s: any, nowMs: number): any
	return with(s, { inFlight = true, startedAt = nowMs })
end

function Poll.succeed(s: any, snapshot: any): any
	return with(s, { inFlight = false, snapshot = snapshot, stale = false, error = "", code = 0, retryAt = 0 })
end

-- kind: "network" | "parse" | "grok-format" | credential errors | "http" (with code)
function Poll.fail(s: any, kind: string, code: number, nowMs: number): any
	local err = kind
	local retryAt = s.retryAt
	if kind == "http" then
		if code == 401 or code == 403 then
			err = "auth"
		elseif code == 429 then
			err = "rate-limited"
			retryAt = nowMs + Poll.BACKOFF_MS
		end
	end
	return with(s, {
		inFlight = false,
		stale = s.snapshot ~= nil,
		error = err,
		code = if kind == "http" then code else 0,
		retryAt = retryAt,
	})
end

-- Seeds an empty state with the snapshot cached on disk, stale until the first
-- answer. Live data always wins over the cache.
function Poll.restore(s: any, snapshot: any): any
	if s.snapshot ~= nil or typeof(snapshot) ~= "table" or typeof(snapshot.windows) ~= "table" then
		return s
	end
	return with(s, { snapshot = snapshot, stale = true })
end

return Poll
