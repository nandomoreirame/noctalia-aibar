-- Reads the CLIs' own credential data (decoded JSON in, plain result out).
-- Never logs, copies or writes a token; the service puts it straight into a
-- request header.

local Creds = {}

Creds.EXPIRY_MARGIN_MS = 60000

-- ~/.claude/.credentials.json -> { ok, token, plan } | { ok = false, error }
function Creds.claudeToken(data: any, nowMs: number)
	local oauth = if typeof(data) == "table" then data.claudeAiOauth else nil
	if typeof(oauth) ~= "table" or typeof(oauth.accessToken) ~= "string" or oauth.accessToken == "" then
		return { ok = false, error = "claude-login" }
	end
	local expiresAt = tonumber(oauth.expiresAt)
	if expiresAt == nil or not (expiresAt > nowMs + Creds.EXPIRY_MARGIN_MS) then
		return { ok = false, error = "claude-expired" }
	end
	return { ok = true, token = oauth.accessToken, plan = tostring(oauth.subscriptionType or "") }
end

-- ~/.grok/auth.json -> { ok, key } | { ok = false, error }. Decoded tables lose
-- the JSON key order, so issuers are tried in alphabetical order.
function Creds.grokKey(data: any)
	if typeof(data) ~= "table" or data[1] ~= nil then
		return { ok = false, error = "grok-login" }
	end
	local issuers = {}
	for issuer in data do
		if typeof(issuer) == "string" then
			table.insert(issuers, issuer)
		end
	end
	table.sort(issuers)
	for _, issuer in issuers do
		local entry = data[issuer]
		local key = if typeof(entry) == "table" and typeof(entry.key) == "string" then string.match(entry.key, "^%s*(.-)%s*$") else ""
		if key ~= "" then
			return { ok = true, key = key }
		end
	end
	return { ok = false, error = "grok-login" }
end

-- ~/.codex/auth.json -> { ok, token, accountId } | { ok = false, error }. An
-- API-key login (OPENAI_API_KEY only) has no plan usage to read.
function Creds.codexToken(data: any)
	local t = if typeof(data) == "table" then data.tokens else nil
	if typeof(t) ~= "table" or typeof(t.access_token) ~= "string" or t.access_token == "" then
		return { ok = false, error = "codex-login" }
	end
	return { ok = true, token = t.access_token, accountId = if typeof(t.account_id) == "string" then t.account_id else "" }
end

-- OpenCode's own credential file. Never use another provider's key as fallback.
function Creds.opencodeKey(data: any)
	local entry = if typeof(data) == "table" then data["opencode-go"] else nil
	if typeof(entry) ~= "table" or entry.type ~= "api" or typeof(entry.key) ~= "string" or entry.key == "" or string.find(entry.key, "[%s%c]") then
		return { ok = false, error = "opencode-login" }
	end
	return { ok = true, key = entry.key }
end

-- Decoded selected credential.value from OpenCode v2's SQLite database.
function Creds.opencodeSession(data: any, nowMs: number)
	if typeof(data) ~= "table" then
		return { ok = false, error = "opencode-login" }
	end
	local token = if data.type == "oauth" then data.access elseif data.type == "key" or data.type == "api" then data.key else nil
	local metadata = if typeof(data.metadata) == "table" then data.metadata else {}
	local orgId = metadata.orgID or ""
	if typeof(token) ~= "string" or token == "" or string.find(token, "[%s%c]") or typeof(orgId) ~= "string" or string.find(orgId, "[%s%c]") then
		return { ok = false, error = "opencode-login" }
	end
	-- A custom Console credential must never be sent to the public service.
	if metadata.server ~= nil and metadata.server ~= "https://opencode.ai/console" and metadata.server ~= "https://console.opencode.ai" then
		return { ok = false, error = "opencode-login" }
	end
	if data.type == "oauth" and (typeof(data.expires) ~= "number" or not (data.expires > nowMs + Creds.EXPIRY_MARGIN_MS)) then
		return { ok = false, error = "opencode-expired" }
	end
	return { ok = true, key = token, orgId = orgId }
end

return Creds
