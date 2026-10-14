.pragma library

// armed: { "<source>|<window>": <end ms of the window that already fired> }.
// A window fires once per reset period; dropping below the threshold re-arms it.
// source tells accounts of one provider apart; it defaults to the provider.
function crossings(snapshot, armed, threshold, source) {
  const next = Object.assign({}, armed || {});
  const fire = [];
  if (!snapshot || !(threshold > 0)) return { fire: fire, armed: next };
  for (const w of snapshot.windows || []) {
    const key = (source || snapshot.provider) + "|" + w.id;
    if (w.percent < threshold) {
      delete next[key];
      continue;
    }
    if (next[key] === w.end) continue;
    next[key] = w.end;
    fire.push({ provider: snapshot.provider, id: w.id, percent: w.percent, end: w.end });
  }
  return { fire: fire, armed: next };
}
