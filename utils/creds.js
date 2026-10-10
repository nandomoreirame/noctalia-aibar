.pragma library

// Reads the CLIs' own credential files (text in, plain result out). Never logs,
// copies or writes a token; the caller passes it straight into a request header.

var EXPIRY_MARGIN_MS = 60000;

function parse(text) {
  try {
    return JSON.parse(String(text || ""));
  } catch (e) {
    return null;
  }
}

// ~/.claude/.credentials.json -> { ok, token, plan } | { ok: false, error }
function claudeToken(text, nowMs) {
  const o = parse(text);
  const oauth = o && o.claudeAiOauth;
  if (!oauth || typeof oauth.accessToken !== "string" || oauth.accessToken === "") return { ok: false, error: "claude-login" };
  if (!(Number(oauth.expiresAt) > nowMs + EXPIRY_MARGIN_MS)) return { ok: false, error: "claude-expired" };
  return { ok: true, token: oauth.accessToken, plan: String(oauth.subscriptionType || "") };
}

// ~/.grok/auth.json -> { ok, key } | { ok: false, error }
function grokKey(text) {
  const o = parse(text);
  if (!o || typeof o !== "object" || Array.isArray(o)) return { ok: false, error: "grok-login" };
  for (const k of Object.keys(o)) {
    const key = o[k] && typeof o[k].key === "string" ? o[k].key.trim() : "";
    if (key) return { ok: true, key: key };
  }
  return { ok: false, error: "grok-login" };
}
