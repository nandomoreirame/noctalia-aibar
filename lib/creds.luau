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

return Creds
