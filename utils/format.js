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
