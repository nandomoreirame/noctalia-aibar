.pragma library

// api.anthropic.com/api/oauth/usage -> normalized snapshot (AD-004).
// Request contract (QML side): GET, headers Authorization: Bearer <token>,
// anthropic-beta: oauth-2025-04-20, User-Agent: claude-cli/<ver> (external, cli).

var API_URL = "https://api.anthropic.com/api/oauth/usage";
var BETA = "oauth-2025-04-20";
var HOUR = 3600000;
var WINDOW_MS = { session: 5 * HOUR, weekly: 168 * HOUR, "weekly-opus": 168 * HOUR, "weekly-sonnet": 168 * HOUR };
var KEYS = [["five_hour", "session"], ["seven_day", "weekly"], ["seven_day_opus", "weekly-opus"], ["seven_day_sonnet", "weekly-sonnet"]];

function windowFrom(raw, id) {
  if (!raw || typeof raw.utilization !== "number") return null;
  const end = raw.resets_at ? Date.parse(raw.resets_at) : NaN;
  return {
    id: id,
    percent: raw.utilization,
    start: isNaN(end) ? null : end - WINDOW_MS[id],
    end: isNaN(end) ? null : end
  };
}

function extraFrom(raw) {
  if (!raw || typeof raw.monthly_limit !== "number") return null;
  const scale = Math.pow(10, Number(raw.decimal_places) || 0);
  return {
    enabled: !!raw.is_enabled,
    used: Number(raw.used_credits || 0) / scale,
    limit: raw.monthly_limit / scale,
    percent: Number(raw.utilization || 0),
    currency: String(raw.currency || "")
  };
}

function parseUsage(text, plan, nowMs) {
  let o;
  try {
    o = JSON.parse(String(text || ""));
  } catch (e) {
    return { ok: false, error: "parse" };
  }
  if (!o || typeof o !== "object") return { ok: false, error: "parse" };
  const windows = KEYS.map((k) => windowFrom(o[k[0]], k[1])).filter((w) => w);
  if (windows.length === 0) return { ok: false, error: "parse" };
  return {
    ok: true,
    snapshot: { provider: "claude", plan: plan || "", windows: windows, extra: extraFrom(o.extra_usage), products: [], fetchedAt: nowMs }
  };
}
