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

local function tr(key: string, vars: any?): string
	if vars then
		return noctalia.tr(key, vars)
	end
	return noctalia.tr(key)
end

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
		if generation[key] ~= id or uuidOf(key) ~= account then
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

local function pollSource(source: any)
	local key = source.key
	local t = now()
	local current = stateOf(key)
	if not poll.canRequest(current, t) then
		return
	end
	if source.provider == "grok" then
		local cred = creds.grokKey(decodeFile(accounts.credPath(source)))
		if not cred.ok then
			states[key] = poll.fail(current, cred.error, 0, t)
			return
		end
		request(source, grok.API_URL, {
			"Authorization: Bearer " .. cred.key,
			"X-XAI-Token-Auth: " .. grok.TOKEN_AUTH,
			"Accept: application/json",
		}, function(data)
			return grok.parseBilling(data, now())
		end)
		return
	end
	local cred = creds.claudeToken(decodeFile(accounts.credPath(source)), t)
	if not cred.ok then
		states[key] = poll.fail(current, cred.error, 0, t)
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
	pollSource(source)
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
	return math.floor((tonumber(info.mtime) or 0) * 1000) .. ":" .. (tonumber(info.size) or 0)
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

local function configure()
	sources = accounts.sources(accounts.parseAccounts(noctalia.getConfig("claude_accounts")))
	for _, s in sources do
		changed(accounts.credPath(s))
		if s.provider == "claude" then
			changed(accounts.configPath(s))
			syncIdentity(s)
		end
		if states[s.key] == nil then
			states[s.key] = poll.restore(poll.createState(), accounts.cachedSnapshot(cache, s.key, uuidOf(s.key)))
		end
	end
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
	for _, s in sources do
		if s.provider == "claude" and changed(accounts.configPath(s)) then
			syncIdentity(s)
		end
		if changed(accounts.credPath(s)) then
			pollSource(s)
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
	configure()
	local setting = tostring(noctalia.getConfig("bar_provider") or "")
	if setting ~= lastBarSetting then
		lastBarSetting = setting
		barKey = accounts.resolveKey(sources, setting)
		persistSelection()
	else
		barKey = accounts.resolveKey(sources, barKey)
	end
	pollAll()
end

start()
