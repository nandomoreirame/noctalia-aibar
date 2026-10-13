.pragma library

// cli-chat-proxy.grok.com/v1/billing?format=credits -> normalized snapshot (AD-004).
// Request contract (QML side): GET, headers Authorization: Bearer <key>,
// X-XAI-Token-Auth: xai-grok-cli. Without format=credits the server answers a
// legacy shape with no percent (refused as "grok-format").

var API_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
var TOKEN_AUTH = "xai-grok-cli";

function time(iso) {
  const t = iso ? Date.parse(iso) : NaN;
  return isNaN(t) ? null : t;
}

function parseBilling(text, nowMs) {
  let o;
  try {
    o = JSON.parse(String(text || ""));
  } catch (e) {
    return { ok: false, error: "parse" };
  }
  const c = o && o.config;
  if (!c || typeof c !== "object") return { ok: false, error: "parse" };
  // The server drops zero fields (protobuf JSON): a period without a percent is
  // a fresh one at 0%. The legacy shape has neither.
  const hasPercent = typeof c.creditUsagePercent === "number";
  if (!hasPercent && !c.currentPeriod) return { ok: false, error: "grok-format" };
  const p = c.currentPeriod || {};
  const window = {
    id: "period",
    periodType: /MONTHLY/.test(String(p.type || "")) ? "monthly" : "weekly",
    percent: hasPercent ? c.creditUsagePercent : 0,
    start: time(p.start),
    end: time(p.end)
  };
  const products = (Array.isArray(c.productUsage) ? c.productUsage : [])
    .filter((x) => x && typeof x.usagePercent === "number")
    .map((x) => ({ name: String(x.product || ""), percent: x.usagePercent }));
  return { ok: true, snapshot: { provider: "grok", plan: "", windows: [window], extra: null, products: products, fetchedAt: nowMs } };
}
