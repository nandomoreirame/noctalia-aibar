-- Usage sources: the active Claude account (~/.claude), frozen Claude accounts
-- (each a CLAUDE_CONFIG_DIR holding the login of an account not in use, see
-- scripts/claude-swap) and Grok. Keys: "claude", "claude:<slug>", "grok".
-- Paths stay in "~/..." form; noctalia.readFile expands "~".

local Accounts = {}

Accounts.MAX_EXTRA = 4
Accounts.MAX_NAME = 24
local DEFAULT_DIR = "~/.claude"

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function slug(name: string): string
	local s = string.gsub(string.lower(name), "[^a-z0-9]+", "-")
	return (string.gsub(s, "^%-+", ""):gsub("%-+$", ""))
end

-- Account names are cut at MAX_NAME characters (UTF-8 aware) and trimmed.
local function capName(name: string): string
	local cut = utf8.offset(name, Accounts.MAX_NAME + 1)
	if cut then
		name = string.sub(name, 1, cut - 1)
	end
	return trim(name)
end

-- A bar_provider value -> source key: "claude:Trabalho Pessoal" -> "claude:trabalho-pessoal".
function Accounts.normalizeKey(value: any): string
	if typeof(value) ~= "string" then
		return ""
	end
	local text = trim(value)
	if string.lower(string.sub(text, 1, 7)) == "claude:" then
		return "claude:" .. slug(capName(trim(string.sub(text, 8))))
	end
	return string.lower(text)
end

local function validDir(dir: string): boolean
	if string.sub(dir, 1, 2) ~= "~/" and string.sub(dir, 1, 1) ~= "/" then
		return false
	end
	if string.find(dir, "%c") then
		return false
	end
	for part in string.gmatch(dir, "[^/]+") do
		if part == ".." then
			return false
		end
	end
	return true
end

-- { "Name=dir", ... } (or one "a=b, c=d" string) -> { { key, name, dir } }.
-- Invalid, duplicate and default-dir entries are dropped.
function Accounts.parseAccounts(value: any)
	local entries = {}
	local function split(text: string)
		for part in string.gmatch(text, "[^,\n]+") do
			table.insert(entries, part)
		end
	end
	if typeof(value) == "string" then
		split(value)
	elseif typeof(value) == "table" then
		for _, item in value do
			if typeof(item) == "string" then
				split(item)
			end
		end
	end
	local out = {}
	local seen = {}
	for _, entry in entries do
		local eq = string.find(entry, "=", 1, true)
		if eq then
			local name = capName(trim(string.sub(entry, 1, eq - 1)))
			local dir = (string.gsub(trim(string.sub(entry, eq + 1)), "/+$", ""))
			local id = slug(name)
			if id ~= "" and validDir(dir) and dir ~= DEFAULT_DIR and not seen[id] then
				seen[id] = true
				table.insert(out, { key = "claude:" .. id, name = name, dir = dir })
				if #out == Accounts.MAX_EXTRA then
					break
				end
			end
		end
	end
	return out
end

function Accounts.sources(extra: any)
	local list = { { key = "claude", provider = "claude", name = "", dir = "", frozen = false } }
	for _, a in extra or {} do
		table.insert(list, { key = a.key, provider = "claude", name = a.name, dir = a.dir, frozen = true })
	end
	table.insert(list, { key = "grok", provider = "grok", name = "", dir = "", frozen = false })
	return list
end

function Accounts.credPath(source: any): string
	if source.provider == "grok" then
		return "~/.grok/auth.json"
	end
	return (if source.dir ~= "" then source.dir else DEFAULT_DIR) .. "/.credentials.json"
end

-- Claude Code keeps .claude.json in HOME by default, inside CLAUDE_CONFIG_DIR otherwise.
function Accounts.configPath(source: any): string
	if source.dir == "" then
		return "~/.claude.json"
	end
	return source.dir .. "/.claude.json"
end

-- .claude.json data -> { uuid, email } of the logged account, or nil. The file holds no token.
function Accounts.accountOf(data: any): any
	local a = if typeof(data) == "table" then data.oauthAccount else nil
	if typeof(a) ~= "table" or typeof(a.accountUuid) ~= "string" or a.accountUuid == "" then
		return nil
	end
	return { uuid = a.accountUuid, email = if typeof(a.emailAddress) == "string" then a.emailAddress else "" }
end

-- "adopt" the first id, "reset" after a swap, "none" otherwise. An unreadable
-- file (mid-write) keeps the last id.
function Accounts.accountChange(prev: string, nextId: string): string
	if nextId == nil or nextId == "" or nextId == prev then
		return "none"
	end
	return if prev ~= "" then "reset" else "adopt"
end

-- Snapshots are cached by account id, so a swap never shows one account's usage
-- under the other. Without an id, the per-provider entry is used.
function Accounts.cachedSnapshot(cache: any, key: string, uuid: string): any
	if typeof(cache) ~= "table" then
		return nil
	end
	if uuid ~= "" then
		local byAccount = if typeof(cache.byAccount) == "table" then cache.byAccount else {}
		return byAccount[uuid]
	end
	if key == "claude" or key == "grok" then
		return cache[key]
	end
	return nil
end

function Accounts.indexOfKey(list: any, key: string): number
	for i, s in list do
		if s.key == key then
			return i
		end
	end
	return 0
end

function Accounts.resolveKey(list: any, key: string): string
	if Accounts.indexOfKey(list, key) > 0 then
		return key
	end
	return list[1].key
end

function Accounts.nextKey(list: any, key: string): string
	local i = Accounts.indexOfKey(list, key)
	if i == 0 then
		return list[1].key
	end
	return list[i % #list + 1].key
end

return Accounts
