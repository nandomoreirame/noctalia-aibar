-- AI Bar service: the only entry that touches credentials, HTTP and files.
-- Tokens live only in locals of the pollers and in the headers table handed to
-- noctalia.http. They never reach noctalia.state, logs, files or notifications.

local accounts = require("./lib/accounts.luau")
local agy = require("./lib/agy.luau")
local claude = require("./lib/claude.luau")
local codex = require("./lib/codex.luau")
local creds = require("./lib/creds.luau")
local cursor = require("./lib/cursor.luau")
local format = require("./lib/format.luau")
local grok = require("./lib/grok.luau")
local notify = require("./lib/notify.luau")
local opencode = require("./lib/opencode.luau")
local poll = require("./lib/poll.luau")
local present = require("./lib/present.luau")
local view = require("./lib/view.luau")

local TICK_MS = 30000

local sources = {}
local states = {}
local identities = {}
local mtimes = {}
local tick = 0
-- key -> tick when a file change or swap asked for a poll. Never polled on
-- that tick by anyone; served once on a later tick.
local pending = {}
local generation = {}
local armed = {}
local cache = { byAccount = {} }
local barKey = "claude"
local lastBarSetting = ""
local nextPollAt = 0
local lastPollAt = 0
local lastUserAgent = ""

local function now(): number
	return noctalia.nowMs()
end

local function dataPath(name: string): string
	return noctalia.pluginDataDir() .. "/" .. name
end

local function decodeFile(path: string): any
	local text = noctalia.readFile(path)
	if text == nil then
		return nil
	end
	return (noctalia.json.decode(text))
end

local tr = present.translator(function(...)
	return noctalia.tr(...)
end)

local function stateOf(key: string): any
	return states[key] or poll.createState()
end

local function uuidOf(key: string): string
	local id = identities[key]
	return if id then id.uuid else ""
end

local function publish()
	noctalia.state.set("view", view.build(sources, states, identities, barKey, now()))
end

local function saveSnapshot(key: string, snapshot: any)
	local uuid = uuidOf(key)
	if uuid ~= "" then
		cache.byAccount[uuid] = snapshot
	elseif key == "claude" or table.find(accounts.PROVIDERS, key) then
		cache[key] = snapshot
	else
		return
	end
	noctalia.writeFile(dataPath("snapshots.json"), noctalia.json.encode(cache))
end

local function fireNotifications(source: any, snapshot: any)
	local result = notify.crossings(snapshot, armed, tonumber(noctalia.getConfig("notify_threshold")) or 0, source.key)
	armed = result.armed
	for _, item in result.fire do
		noctalia.notify(
			tr("notify.title", { provider = present.sourceName(source, tr), window = format.windowLabel(item, tr), n = math.floor(item.percent + 0.5) }),
			tr("notify.body", { t = format.countdown(item.endMs, now()) })
		)
	end
end

local function applyResult(source: any, kind: string, code: number, snapshot: any)
	local key = source.key
	if snapshot then
		states[key] = poll.succeed(stateOf(key), snapshot)
		fireNotifications(source, snapshot)
		saveSnapshot(key, snapshot)
	else
		states[key] = poll.fail(stateOf(key), kind, code, now())
	end
	publish()
end

-- headers is a local list; nothing in it is logged. An answer is dropped when a
-- newer request replaced it or the source's account changed meanwhile. A body
-- makes it a POST.
local function request(source: any, url: string, headers: { string }, parse: (any) -> any, body: string?)
	local key = source.key
	local id = (generation[key] or 0) + 1
	generation[key] = id
	local account = uuidOf(key)
	states[key] = poll.begin(stateOf(key), now())
	noctalia.http({ url = url, method = if body ~= nil then "POST" else "GET", headers = headers, body = body }, function(res)
		-- A request started without a known account belongs to whichever account is
		-- adopted next; one started with a known account is dropped after a swap.
		if generation[key] ~= id or (account ~= "" and uuidOf(key) ~= account) then
			return
		end
		local status = tonumber(res and res.status) or 0
		if status ~= 200 then
			noctalia.log("aibar " .. key .. " " .. status)
			applyResult(source, if status == 0 then "network" else "http", status, nil)
			return
		end
		local parsed = parse(noctalia.json.decode(res.body or ""))
		if not parsed.ok then
			applyResult(source, parsed.error, 0, nil)
			return
		end
		applyResult(source, "", 0, parsed.snapshot)
	end)
end

-- runAsync counterpart of request: the result is dropped when a newer poll or a
-- reset replaced it. stdout may hold a token, so it is never logged.
local function command(source: any, argv: { string }, done: (any) -> ())
	local key = source.key
	local id = (generation[key] or 0) + 1
	generation[key] = id
	states[key] = poll.begin(stateOf(key), now())
	noctalia.runAsync(argv, function(res)
		if generation[key] ~= id then
			return
		end
		done(res)
	end)
end

-- provider -> function(source, state, nowMs) that starts one poll.
local pollers = {}

pollers.grok = function(source: any, current: any, t: number)
	local cred = creds.grokKey(decodeFile(accounts.credPath(source)))
	if not cred.ok then
		states[source.key] = poll.fail(current, cred.error, 0, t)
		return
	end
	request(source, grok.API_URL, {
		"Authorization: Bearer " .. cred.key,
		"X-XAI-Token-Auth: " .. grok.TOKEN_AUTH,
		"Accept: application/json",
	}, function(data)
		return grok.parseBilling(data, now())
	end)
end

pollers.claude = function(source: any, current: any, t: number)
	local cred = creds.claudeToken(decodeFile(accounts.credPath(source)), t)
	if not cred.ok then
		states[source.key] = poll.fail(current, cred.error, 0, t)
		return
	end
	local plan = cred.plan
	request(source, claude.API_URL, {
		"Authorization: Bearer " .. cred.token,
		"anthropic-beta: " .. claude.BETA,
		"User-Agent: " .. tostring(noctalia.getConfig("claude_user_agent") or ""),
		"Accept: application/json",
	}, function(data)
		return claude.parseUsage(data, plan, now())
	end)
end

pollers.opencode = function(source: any, current: any, t: number)
	local function fetch(cred: any)
		if not cred.ok then
			applyResult(source, cred.error, 0, nil)
			return
		end
		local headers = {
			"Authorization: Bearer " .. cred.key,
			"Accept: application/json",
			"User-Agent: " .. opencode.USER_AGENT,
		}
		if cred.orgId ~= nil and cred.orgId ~= "" then
			table.insert(headers, "x-org-id: " .. cred.orgId)
		end
		request(source, opencode.API_URL, headers, function(data)
			return opencode.parseUsage(data, now())
		end)
	end
	-- v2 stores browser sign-ins in SQLite, not the retired auth.json. Poll
	-- it on the regular schedule, not on DB/WAL writes from every model step.
	if noctalia.fileInfo(opencode.DB_PATH) ~= nil then
		if not noctalia.commandExists("sqlite3") then
			states[source.key] = poll.fail(current, "opencode-sqlite", 0, t)
			return
		end
		command(source, opencode.credentialArgv(noctalia.expandPath(opencode.DB_PATH)), function(res)
			if typeof(res) ~= "table" or res.exitCode ~= 0 or res.timedOut == true or res.stdoutTruncated == true then
				applyResult(source, "opencode-login", 0, nil)
				return
			end
			local decoded, data = pcall(noctalia.json.decode, res.stdout or "")
			fetch(creds.opencodeSession(if decoded then data else nil, now()))
		end)
		return
	end
	fetch(creds.opencodeKey(decodeFile(accounts.credPath(source))))
end

pollers.codex = function(source: any, current: any, t: number)
	local cred = creds.codexToken(decodeFile(accounts.credPath(source)))
	if not cred.ok then
		states[source.key] = poll.fail(current, cred.error, 0, t)
		return
	end
	local headers = {
		"Authorization: Bearer " .. cred.token,
		"User-Agent: " .. codex.USER_AGENT,
		"Accept: application/json",
	}
	if cred.accountId ~= "" then
		table.insert(headers, "ChatGPT-Account-Id: " .. cred.accountId)
	end
	request(source, codex.API_URL, headers, function(data)
		return codex.parseUsage(data, now())
	end)
end

-- Token from Cursor's own state.vscdb (read-only); argv holds only the query.
pollers.cursor = function(source: any, current: any, t: number)
	if not noctalia.commandExists("sqlite3") then
		states[source.key] = poll.fail(current, "cursor-sqlite", 0, t)
		return
	end
	command(source, cursor.tokenArgv(noctalia.expandPath(cursor.DB_PATH)), function(res)
		local cred = cursor.tokenFrom(res)
		if not cred.ok then
			applyResult(source, cred.error, 0, nil)
			return
		end
		request(source, cursor.API_URL, {
			"Authorization: Bearer " .. cred.token,
			"Content-Type: application/json",
			"Connect-Protocol-Version: 1",
			"Accept: application/json",
		}, function(data)
			return cursor.parseUsage(data, now())
		end, "{}")
	end)
end

-- agy prints its own Models & Quota summary: no token, no model turn.
pollers.agy = function(source: any, current: any, t: number)
	if not noctalia.commandExists("agy") then
		states[source.key] = poll.fail(current, "agy-missing", 0, t)
		return
	end
	command(source, agy.ARGV, function(res)
		if typeof(res) ~= "table" or res.exitCode ~= 0 then
			applyResult(source, "agy-login", 0, nil)
			return
		end
		local decoded, data = pcall(noctalia.json.decode, res.stdout or "")
		local parsed = agy.parseQuota(if decoded then data else nil, now())
		if not parsed.ok then
			applyResult(source, parsed.error, 0, nil)
			return
		end
		applyResult(source, "", 0, parsed.snapshot)
	end)
end

local function pollSource(source: any): boolean
	local key = source.key
	-- Marked this tick (file change or swap): wait for a later tick, whoever asks.
	if pending[key] == tick then
		return false
	end
	local t = now()
	local current = stateOf(key)
	local poller = pollers[source.provider]
	if poller == nil or not poll.canRequest(current, t) then
		return false
	end
	poller(source, current, t)
	return true
end

local function interval(): number
	return math.max(2, tonumber(noctalia.getConfig("poll_minutes")) or 5) * 60000
end

local function pollAll()
	lastPollAt = now()
	nextPollAt = lastPollAt + interval()
	for _, s in sources do
		pollSource(s)
	end
	publish()
end

-- A source's .claude.json was (re)read: claude-swap moves logins between
-- accounts, so the account behind a key can change.
local function syncIdentity(source: any)
	local key = source.key
	local info = accounts.accountOf(decodeFile(accounts.configPath(source)))
	local change = accounts.accountChange(uuidOf(key), if info then info.uuid else "")
	if change == "none" then
		return
	end
	identities[key] = info
	local current = stateOf(key)
	local cached = accounts.cachedSnapshot(cache, key, info.uuid)
	if change == "adopt" then
		if current.snapshot ~= nil and not current.stale then
			saveSnapshot(key, current.snapshot)
		elseif cached ~= nil then
			local nextState = table.clone(current)
			nextState.snapshot = cached
			nextState.stale = true
			states[key] = nextState
		end
		return
	end
	generation[key] = (generation[key] or 0) + 1
	states[key] = poll.restore(poll.createState(), cached)
	-- Wait a tick: claude-swap writes .claude.json and .credentials.json separately.
	pending[key] = tick
end

local function loadCache()
	local data = decodeFile(dataPath("snapshots.json"))
	if typeof(data) == "table" then
		cache = data
	end
	if typeof(cache.byAccount) ~= "table" then
		cache.byAccount = {}
	end
end

-- Millisecond mtime plus size. The host derives mtime from two clock reads, so
-- the raw double can wobble by a few ns with nothing changed on disk.
local function fingerprint(path: string): string
	local info = noctalia.fileInfo(path)
	if not info then
		return "missing"
	end
	return math.floor((tonumber(info.mtime) or 0) * 1000 + 0.5) .. ":" .. (tonumber(info.size) or 0)
end

-- true when the file's fingerprint differs from the last one seen.
local function changed(path: string): boolean
	local seen = fingerprint(path)
	if mtimes[path] == seen then
		return false
	end
	mtimes[path] = seen
	return true
end

local function persistSelection()
	noctalia.writeFile(dataPath("selection.json"), noctalia.json.encode({ key = barKey }))
end

local function cycle()
	barKey = accounts.nextKey(sources, barKey)
	persistSelection()
	publish()
end

-- The panel picked a source: show it in the bar. Unknown keys are ignored.
local function selectSource(value: any)
	if typeof(value) ~= "table" or typeof(value.key) ~= "string" or accounts.indexOfKey(sources, value.key) == 0 then
		return
	end
	barKey = value.key
	persistSelection()
	publish()
end

local function refresh()
	for _, s in sources do
		if s.provider == "claude" then
			syncIdentity(s)
		end
		pollSource(s)
	end
	publish()
end

-- Forget everything about a key: identity, state, pending mark, fired
-- notifications, and any answer still in flight (its generation no longer matches).
local function resetSource(key: string)
	identities[key] = nil
	states[key] = nil
	pending[key] = nil
	generation[key] = (generation[key] or 0) + 1
	local prefix = key .. "|"
	for k in armed do
		if string.sub(k, 1, #prefix) == prefix then
			armed[k] = nil
		end
	end
end

-- Start watching a path without consuming a change update() has not seen.
local function watch(path: string)
	if mtimes[path] == nil then
		changed(path)
	end
end

-- show_<provider> settings; Claude is always on.
local function enabledProviders(): any
	local map = {}
	for _, p in accounts.PROVIDERS do
		map[p] = noctalia.getConfig("show_" .. p) ~= false
	end
	return map
end

-- Rebuilds the sources from settings. A key whose dir changed, or that was
-- removed, is reset. Returns the sources that had no state before this call
-- (new or reset); they need a poll even when a cached snapshot was restored.
local function configure(): { any }
	local previous = {}
	for _, s in sources do
		previous[s.key] = s.dir
	end
	sources = accounts.sources(accounts.parseAccounts(noctalia.getConfig("claude_accounts")), enabledProviders())
	local kept = {}
	local fresh = {}
	for _, s in sources do
		kept[s.key] = true
		if previous[s.key] ~= nil and previous[s.key] ~= s.dir then
			resetSource(s.key)
		end
		local isFresh = states[s.key] == nil
		local cred = accounts.credPath(s)
		if cred ~= "" then
			watch(cred)
		end
		if s.provider == "claude" then
			watch(accounts.configPath(s))
			syncIdentity(s)
		end
		if states[s.key] == nil then
			states[s.key] = poll.restore(poll.createState(), accounts.cachedSnapshot(cache, s.key, uuidOf(s.key)))
		end
		if isFresh then
			table.insert(fresh, s)
		end
	end
	for key in previous do
		if not kept[key] then
			resetSource(key)
		end
	end
	return fresh
end

local function start()
	noctalia.setUpdateInterval(TICK_MS)
	loadCache()
	configure()
	lastBarSetting = tostring(noctalia.getConfig("bar_provider") or "")
	lastUserAgent = tostring(noctalia.getConfig("claude_user_agent") or "")
	local selection = decodeFile(dataPath("selection.json"))
	barKey = view.initialKey(sources, if typeof(selection) == "table" then selection.key else nil, lastBarSetting)
	pollAll()
	noctalia.state.watch("cmd.refresh", function()
		refresh()
	end)
	noctalia.state.watch("cmd.cycle", function()
		cycle()
	end)
	noctalia.state.watch("cmd.select", selectSource)
end

function update()
	tick += 1
	for _, s in sources do
		if s.provider == "claude" and changed(accounts.configPath(s)) then
			syncIdentity(s)
		end
	end
	for _, s in sources do
		local cred = accounts.credPath(s)
		if cred ~= "" and changed(cred) and pending[s.key] == nil then
			pending[s.key] = tick
		end
	end
	for _, s in sources do
		local mark = pending[s.key]
		if mark ~= nil and mark < tick and pollSource(s) then
			pending[s.key] = nil
		end
	end
	if now() >= nextPollAt then
		pollAll()
	else
		publish()
	end
end

function onIpc(event: string, _payload: any)
	if event == "refresh" then
		refresh()
	elseif event == "cycle" then
		cycle()
	end
end

-- Settings changed: rebuild the sources (claude_accounts), and let only a
-- *changed* bar_provider override the middle-click choice.
function onConfigChanged()
	local fresh = configure()
	local setting = tostring(noctalia.getConfig("bar_provider") or "")
	if setting ~= lastBarSetting then
		lastBarSetting = setting
		barKey = view.initialKey(sources, nil, setting)
		persistSelection()
	else
		-- A source that vanished (removed account) falls back like at boot.
		local resolved = view.initialKey(sources, barKey, setting)
		if resolved ~= barKey then
			barKey = resolved
			persistSelection()
		end
	end
	for _, s in fresh do
		pollSource(s)
	end
	-- A new User-Agent may cure a 429 storm: retry Claude (backoff still applies).
	local userAgent = tostring(noctalia.getConfig("claude_user_agent") or "")
	if userAgent ~= lastUserAgent then
		lastUserAgent = userAgent
		for _, s in sources do
			if s.provider == "claude" then
				pollSource(s)
			end
		end
	end
	-- poll_minutes may have changed: count the new interval from the last poll.
	nextPollAt = lastPollAt + interval()
	publish()
end

start()
