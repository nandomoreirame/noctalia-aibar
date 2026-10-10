.pragma library

// Per-provider request state. Plain data, replaced (never mutated) on every step.
// error: "" | "network" | "http" | "auth" | "rate-limited" | "parse" | "grok-format"
//        | "claude-login" | "claude-expired" | "grok-login"

var BACKOFF_MS = 5 * 60000;

function createState() {
  return { inFlight: false, snapshot: null, stale: false, error: "", code: 0, retryAt: 0 };
}

function canRequest(s, nowMs) {
  return !s.inFlight && nowMs >= s.retryAt;
}

function begin(s, nowMs) {
  return Object.assign({}, s, { inFlight: true });
}

function succeed(s, snapshot) {
  return Object.assign({}, s, { inFlight: false, snapshot: snapshot, stale: false, error: "", code: 0, retryAt: 0 });
}

// kind: "network" | "parse" | "grok-format" | credential errors | "http" (with code)
function fail(s, kind, code, nowMs) {
  let error = kind;
  let retryAt = s.retryAt;
  if (kind === "http") {
    if (code === 401 || code === 403) error = "auth";
    else if (code === 429) {
      error = "rate-limited";
      retryAt = nowMs + BACKOFF_MS;
    }
  }
  return Object.assign({}, s, { inFlight: false, stale: s.snapshot !== null, error: error, code: kind === "http" ? code : 0, retryAt: retryAt });
}
