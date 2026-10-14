.pragma library

function countdown(endMs, nowMs) {
  if (endMs === null || endMs === undefined) return "";
  const min = Math.max(0, Math.floor((endMs - nowMs) / 60000));
  const d = Math.floor(min / 1440);
  const h = Math.floor((min % 1440) / 60);
  const m = min % 60;
  if (d > 0) return d + "d" + h + "h";
  if (h > 0) return h + "h" + m + "m";
  return m + "m";
}

function percentText(p) {
  return typeof p === "number" ? Math.round(p) + "%" : "—";
}

// "47% · 1h12m" for the primary window; "—" without data.
function barText(w, nowMs) {
  if (!w) return "—";
  const reset = countdown(w.end, nowMs);
  return reset ? percentText(w.percent) + " · " + reset : percentText(w.percent);
}

function minutesAgo(fetchedAt, nowMs) {
  return Math.max(0, Math.floor((nowMs - fetchedAt) / 60000));
}

// "5m", "2h5m", "3d0h" since fetchedAt.
function ago(fetchedAt, nowMs) {
  return countdown(nowMs, fetchedAt);
}

function windowKey(w) {
  if (w.id === "period") return "window.period-" + (w.periodType === "monthly" ? "monthly" : "weekly");
  return "window." + w.id;
}

var LOGIN_ERRORS = ["auth", "grok-login", "claude-login", "claude-expired"];

// i18n key and vars for a provider's request error; null when there is none.
// quiet hides login errors: the CLIs renew their token only when used, so an
// expired one is expected while the plan is blocked or the account is frozen.
function errorMessage(usage, provider, nowMs, quiet) {
  if (!usage || !usage.error) return null;
  if (quiet && LOGIN_ERRORS.indexOf(usage.error) !== -1) return null;
  if (usage.error === "auth") return { key: provider === "grok" ? "error.grok-login" : "error.claude-expired", vars: null };
  if (usage.error === "http") return { key: "error.http", vars: { code: usage.code } };
  if (usage.error === "rate-limited") return { key: "error.rate-limited", vars: { n: Math.max(0, Math.ceil((usage.retryAt - nowMs) / 60000)) } };
  return { key: "error." + usage.error, vars: null };
}

// i18n key and vars for a window at 100% (see Pace.exhausted); null without one.
function limitMessage(w, nowMs) {
  if (!w) return null;
  return { key: "panel.limit-reached", vars: { t: countdown(w.end, nowMs) } };
}

// "33,50 / 90,00 BRL"; the decimal separator comes from the UI language.
function moneyText(extra, decimalSep) {
  if (!extra) return "";
  const sep = decimalSep === "," ? "," : ".";
  const amount = function (n) { return Number(n).toFixed(2).replace(".", sep); };
  const currency = extra.currency ? " " + extra.currency : "";
  return amount(extra.used) + " / " + amount(extra.limit) + currency;
}
