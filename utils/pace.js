.pragma library

var CRITICAL = 90;
var AHEAD_POINTS = 10;
var PRIMARY = ["session", "period"];

// { elapsed, delta } in percent / points; null when the window has no bounds.
function pace(w, nowMs) {
  if (!w || w.start === null || w.end === null || !(w.end > w.start)) return { elapsed: null, delta: null };
  const elapsed = Math.max(0, Math.min(100, ((nowMs - w.start) / (w.end - w.start)) * 100));
  return { elapsed: Math.round(elapsed), delta: Math.round(w.percent - elapsed) };
}

function status(w, nowMs) {
  if (!w) return "ok";
  if (w.percent >= CRITICAL) return "critical";
  const p = pace(w, nowMs);
  return p.delta !== null && p.delta > AHEAD_POINTS ? "ahead" : "ok";
}

// The window the bar shows: Claude's 5 h session, Grok's period, else the first.
function primaryWindow(snapshot) {
  if (!snapshot || !snapshot.windows || snapshot.windows.length === 0) return null;
  for (const id of PRIMARY) {
    const w = snapshot.windows.find((x) => x.id === id);
    if (w) return w;
  }
  return snapshot.windows[0];
}

// A cached snapshot can outlive its windows: one whose reset passed is shown as
// 0% without bounds (the next period starts on first use). Same object when
// nothing reset.
function project(snapshot, nowMs) {
  if (!snapshot || !snapshot.windows) return snapshot;
  let changed = false;
  const windows = snapshot.windows.map((w) => {
    if (w.end === null || w.end === undefined || w.end > nowMs) return w;
    changed = true;
    return Object.assign({}, w, { percent: 0, start: null, end: null });
  });
  return changed ? Object.assign({}, snapshot, { windows: windows }) : snapshot;
}

// The window at 100% that unblocks last, or null. Windows already reset or
// without an end are skipped: a cached snapshot can outlive them.
function exhausted(snapshot, nowMs) {
  if (!snapshot || !snapshot.windows) return null;
  let found = null;
  for (const w of snapshot.windows) {
    if (typeof w.percent !== "number" || w.percent < 100) continue;
    if (w.end === null || w.end === undefined || !(w.end > nowMs)) continue;
    if (!found || w.end > found.end) found = w;
  }
  return found;
}
