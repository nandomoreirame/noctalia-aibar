.pragma library

// Usage sources shown by the bar and the panel: the active Claude account
// (~/.claude), extra Claude accounts (each a CLAUDE_CONFIG_DIR) and Grok.
// Keys: "claude", "claude:<slug>", "grok". Extra accounts are frozen: they hold
// the login of an account not in use (see claude-swap), so the bar shows their
// last status and never asks to renew their token.

var MAX_EXTRA = 4;
var MAX_NAME = 24;
var DEFAULT_DIR = "~/.claude";

function slug(name) {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

function validDir(dir) {
  if (!/^(~\/|\/)/.test(dir) || /[\u0000-\u001f]/.test(dir)) return false;
  return dir.split("/").indexOf("..") === -1;
}

// "Trabalho=~/.claude-trabalho, Outra=/path" -> [{ key, name, dir }].
// Invalid, duplicate and default-dir entries are dropped.
function parseAccounts(text) {
  if (typeof text !== "string") return [];
  const out = [];
  const seen = {};
  for (const entry of text.split(/[,\n]/)) {
    const eq = entry.indexOf("=");
    if (eq < 0) continue;
    const name = entry.slice(0, eq).trim().slice(0, MAX_NAME).trim();
    const dir = entry.slice(eq + 1).trim().replace(/\/+$/, "");
    const id = slug(name);
    if (!id || !validDir(dir) || dir === DEFAULT_DIR || seen[id]) continue;
    seen[id] = true;
    out.push({ key: "claude:" + id, name: name, dir: dir });
    if (out.length === MAX_EXTRA) break;
  }
  return out;
}

function sources(extra) {
  const list = [{ key: "claude", provider: "claude", name: "", dir: "", frozen: false }];
  for (const a of extra || []) list.push({ key: a.key, provider: "claude", name: a.name, dir: a.dir, frozen: true });
  list.push({ key: "grok", provider: "grok", name: "", dir: "", frozen: false });
  return list;
}

function expand(dir, home) {
  return dir.indexOf("~/") === 0 ? home + dir.slice(1) : dir;
}

function credPath(dir, home) {
  return expand(dir, home) + "/.credentials.json";
}

// Claude Code keeps .claude.json in HOME by default, inside CLAUDE_CONFIG_DIR otherwise.
function configPath(dir, home) {
  return dir ? expand(dir, home) + "/.claude.json" : home + "/.claude.json";
}

// .claude.json -> { uuid, email } of the logged account, or null. Only these
// two fields are read; the file holds no token.
function accountOf(text) {
  let o = null;
  try {
    o = JSON.parse(String(text || ""));
  } catch (e) {
    return null;
  }
  const a = o && o.oauthAccount;
  if (!a || typeof a.accountUuid !== "string" || a.accountUuid === "") return null;
  return { uuid: a.accountUuid, email: typeof a.emailAddress === "string" ? a.emailAddress : "" };
}

// What a source does when its account id is read: "adopt" the first one (its
// snapshot is already that account's), "reset" after a swap, "none" otherwise.
// An unreadable file (mid-write) keeps the last id.
function accountChange(prev, next) {
  if (!next || next === prev) return "none";
  return prev ? "reset" : "adopt";
}

// Cached snapshots are keyed by account id, so a swap never shows one account's
// usage under the other. Without an id, the per-provider entry (Grok, or the
// cache written before accounts existed) is used.
function cachedSnapshot(cache, key, uuid) {
  if (!cache) return null;
  if (uuid) return (cache.byAccount || {})[uuid] || null;
  return key === "claude" || key === "grok" ? cache[key] || null : null;
}

function indexOfKey(list, key) {
  for (let i = 0; i < list.length; i++) if (list[i].key === key) return i;
  return -1;
}

function resolveKey(list, key) {
  return indexOfKey(list, key) >= 0 ? key : list[0].key;
}

function nextKey(list, key) {
  const i = indexOfKey(list, key);
  return i < 0 ? list[0].key : list[(i + 1) % list.length].key;
}
