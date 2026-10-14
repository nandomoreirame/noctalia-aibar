-- AI Bar service: the only entry that touches credentials, HTTP and files.
-- Tokens live only in locals of pollSource and in the headers table handed to
-- noctalia.http. They never reach noctalia.state, logs, files or notifications.

local accounts = require("./lib/accounts.luau")
local claude = require("./lib/claude.luau")
local creds = require("./lib/creds.luau")
local format = require("./lib/format.luau")
local grok = require("./lib/grok.luau")
local notify = require("./lib/notify.luau")
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

local tr = present.translator(noctalia.tr)

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
	elseif key == "claude" or key == "grok" then
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
			tr("notify.title", { provider = present.sourceName(source, tr), window = tr(format.windowKey(item)), n = math.floor(item.percent + 0.5) }),
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
-- newer request replaced it or the source's account changed meanwhile.
local function request(source: any, url: string, headers: { string }, parse: (any) -> any)
	local key = source.key
	local id = (generation[key] or 0) + 1
	generation[key] = id
	local account = uuidOf(key)
	states[key] = poll.begin(stateOf(key), now())
	noctalia.http({ url = url, method = "GET", headers = headers }, function(res)
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

local function pollSource(source: any): boolean
	local key = source.key
	-- Marked this tick (file change or swap): wait for a later tick, whoever asks.
	if pending[key] == tick then
		return false
	end
	local t = now()
	local current = stateOf(key)
	if not poll.canRequest(current, t) then
		return false
	end
	if source.provider == "grok" then
		local cred = creds.grokKey(decodeFile(accounts.credPath(source)))
		if not cred.ok then
			states[key] = poll.fail(current, cred.error, 0, t)
			return true
		end
		request(source, grok.API_URL, {
			"Authorization: Bearer " .. cred.key,
			"X-XAI-Token-Auth: " .. grok.TOKEN_AUTH,
			"Accept: application/json",
		}, function(data)
			return grok.parseBilling(data, now())
		end)
		return true
	end
	local cred = creds.claudeToken(decodeFile(accounts.credPath(source)), t)
	if not cred.ok then
		states[key] = poll.fail(current, cred.error, 0, t)
		return true
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
	return true
end

local function pollAll()
	local minutes = math.max(2, tonumber(noctalia.getConfig("poll_minutes")) or 5)
	nextPollAt = now() + minutes * 60000
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

local function refresh()
	for _, s in sources do
		if s.provider == "claude" then
			syncIdentity(s)
		end
		pollSource(s)
	end
	publish()
end

-- Forget everything about a key: identity, state, pending mark, and any answer
-- still in flight (its generation no longer matches).
local function resetSource(key: string)
	identities[key] = nil
	states[key] = nil
	pending[key] = nil
	generation[key] = (generation[key] or 0) + 1
end

-- Start watching a path without consuming a change update() has not seen.
local function watch(path: string)
	if mtimes[path] == nil then
		changed(path)
	end
end

-- Rebuilds the sources from settings. A key whose dir changed, or that was
-- removed, is reset. Returns the sources that had no state before this call
-- (new or reset); they need a poll even when a cached snapshot was restored.
local function configure(): { any }
	local previous = {}
	for _, s in sources do
		previous[s.key] = s.dir
	end
	sources = accounts.sources(accounts.parseAccounts(noctalia.getConfig("claude_accounts")))
	local kept = {}
	local fresh = {}
	for _, s in sources do
		kept[s.key] = true
		if previous[s.key] ~= nil and previous[s.key] ~= s.dir then
			resetSource(s.key)
		end
		local isFresh = states[s.key] == nil
		watch(accounts.credPath(s))
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
	local selection = decodeFile(dataPath("selection.json"))
	barKey = view.initialKey(sources, if typeof(selection) == "table" then selection.key else nil, lastBarSetting)
	pollAll()
	noctalia.state.watch("cmd.refresh", function()
		refresh()
	end)
	noctalia.state.watch("cmd.cycle", function()
		cycle()
	end)
end

function update()
	tick += 1
	for _, s in sources do
		if s.provider == "claude" and changed(accounts.configPath(s)) then
			syncIdentity(s)
		end
	end
	for _, s in sources do
		if changed(accounts.credPath(s)) and pending[s.key] == nil then
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
	publish()
end

start()
