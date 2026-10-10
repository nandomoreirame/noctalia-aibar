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
