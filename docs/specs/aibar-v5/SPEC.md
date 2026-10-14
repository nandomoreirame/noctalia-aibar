# SPEC: aibar-v5

**Status:** approved (2026-10-14) · **Depth:** Deep · **Repo:** `noctalia-aibar`
**Supersedes:** `docs/specs/aibar/SPEC.md` (v4, frozen on branch `legacy-v4`, v0.1.3)

## Summary

Port `aibar` from Noctalia Shell v4 (QML, `manifest.json`) to Noctalia **v5** (Luau entry
scripts, `plugin.toml`), keeping every v0.1.3 behavior: Claude Code and Grok plan usage in
the bar and in a panel, frozen Claude accounts, per-account snapshot cache, reached-limit
messages, threshold notifications. The v4 code is removed from `main`; `legacy-v4` keeps it.
The plugin stays personal (symlinked into the local data dir) but ships everything the
`noctalia-dev/community-plugins` repo requires, so a PR can be opened later without rework.

## Goals

- Same information as v0.1.3 on Noctalia 5.2.x: bar (icon, `47% · 1h12m`, progress bar),
  tooltip, panel with one card per provider, Claude account switch inside the card.
- Pure logic in `lib/*.luau`, tested with `./run-tests` (Luau CLI, scaffold mock). No Node.
- Credentials stay read-only and never leave the service VM except as request headers.
- Community-ready layout: `plugin.toml`, `README.md`, `thumbnail.webp`, `translations/en.json`.

## Non-goals

- Noctalia v4 support on `main` (that is `legacy-v4`).
- Opening the community-plugins PR, `catalog.toml`, `[[plugin.release]]` rows.
- New providers, usage history, token refresh, Grok banked resets.
- Migrating the v4 snapshot cache (`~/.cache/noctalia/aibar-snapshots.json`) or v4 settings.

## Verified Claims

V1..V8 of the v4 spec (endpoints, headers, response shapes, credential files) still hold and
are not repeated. New claims for v5:

| # | Claim | Evidence |
|---|-------|----------|
| W1 | Installed host is `noctalia` 5.2.1; plugin API levels up to 32 exist at 5.2.0 | `pacman`/`noctalia --version`; `docs/plugin-api.json` in `~/.cache/noctalia-v5-src` |
| W2 | `noctalia.http(request, cb)` is native (no subprocess): headers never reach argv | `runtime-api.mdx` "HTTP and downloads" / `httpStream` note |
| W3 | Entries are isolated VMs; they share plain values through `noctalia.state.set/get/watch` (in-memory, process lifetime) | `runtime-api.mdx` "Sharing state across entries" |
| W4 | Plugins cannot write their own config; `noctalia.getConfig` is read-only; services get `onConfigChanged()` | `runtime-api.mdx` `openSettings`; `entries.mdx` |
| W5 | Middle click on a bar widget opens its settings unless the manifest declares `[widget.actions] middle = "none"` (API 14) | `entries.mdx`, `manifest.mdx` |
| W6 | `barWidget.render(tree)` replaces the glyph/text row; `ui.progress`, `ui.glyph`, `ui.label` work in the bar; `setTooltip` takes key/value rows | `declarative-ui.mdx`, `entries.mdx` |
| W7 | Panel size is host-owned (`width`/`height` on `[[panel]]`), no runtime resize | `declarative-ui.mdx` "panel.*" |
| W8 | `require("./lib/x.luau")` needs API 22; closures as UI callbacks need API 9; `nowMs()` needs API 12; `string_list` setting exists | `entries.mdx`, `plugin-api.json`, `manifest.mdx` |
| W9 | `noctalia.json.decode` maps JSON `null` to `nil` (keys disappear) | `src/scripting/luau_host.cpp` `jsonToLua` |
| W10 | `pluginDataDir()` survives updates; `pluginDir()` is rewritten on update | `runtime-api.mdx` "Persisting data" |
| W11 | Translations are nested JSON in `translations/<lang>.json` (`en`, `pt-BR`); setting labels must be translation keys | official `kaomoji` plugin; `manifest.mdx` |
| W12 | Community submission needs `plugin.toml`, `.luau` entries, `README.md` (title, plugin table, usage, requirements, settings, IPC, notes), `thumbnail.webp` (official ones are 960x540), `translations/en.json`; lowercase id; description <= 120 chars; disclose every network call / file write / process; at most 200 files | github.com/noctalia-dev/community-plugins README; kaomoji thumbnail |
| W13 | Luau CLI has no `io`; `run-tests` wraps root `*.luau` sources into `tests/.generated/` string modules | `run-tests`, `tests/support/entry.luau` |

## Requirements

### Manifest and layout

- **REQ-001** The plugin SHALL be `id = "nandomoreirame/aibar"` with a `plugin.toml` declaring
  `plugin_api = 22`, version `0.2.0`, MIT license, a description of at most 120 characters,
  `dependencies = []`, and three entries: `[[service]] usage` (`service.luau`),
  `[[widget]] bar` (`widget.luau`, `[widget.actions] middle = "none"`) and
  `[[panel]] panel` (`panel.luau`, `width = 400`, `height = 560`, `placement = "attached"`,
  `open_near_click = true`). `noctalia plugins lint .` SHALL pass.
- **REQ-002** All QML, `utils/`, `components/`, `i18n/`, `manifest.json`, `settings.json`,
  `package*.json` and `vitest.config.js` SHALL be removed. Pure logic SHALL live in
  `lib/*.luau` with no host globals (`noctalia`, `barWidget`, `panel`, `ui`).

### Settings

- **REQ-003** Plugin-level settings SHALL be: `bar_provider` (string, default `claude`),
  `poll_minutes` (int, default 5, min 2), `notify_threshold` (int, default 97, 0..100, 0
  disables), `claude_user_agent` (string, default `claude-cli/2.1.281 (external, cli)`),
  `claude_accounts` (`string_list` of `Name=dir`, default empty). Labels and descriptions are
  translation keys.

### Credentials and fetch (service)

- **REQ-004** The service SHALL read `~/.claude/.credentials.json` (and
  `<dir>/.credentials.json` per frozen account) and `~/.grok/auth.json` with
  `noctalia.readFile` (paths kept as `~/...`, which the host expands), with the v4 rules:
  missing → `claude-login`/`grok-login`, expiring within 60 s → `claude-expired`. Decoded
  Luau tables lose JSON key order, so the Grok key is the one of the alphabetically first
  issuer with a non-empty `key`. It SHALL never
  write, copy or refresh them.
- **REQ-005** Tokens SHALL exist only in service-local variables and the `headers` of
  `noctalia.http`. They SHALL never be passed to `noctalia.state`, `noctalia.log`,
  `noctalia.writeFile`, `noctalia.notify` or a subprocess. A test SHALL assert this against
  the mock's recorded calls.
- **REQ-006** The service SHALL own the only timer (a 30 s tick via `setUpdateInterval`;
  widget and panel have none). It SHALL poll every source at start, every `poll_minutes`, and
  on a refresh command; never two requests in flight per source; a request older than 30 s is
  abandoned and its late answer dropped (request generation id).
- **REQ-007** Failures keep the last snapshot marked stale: network/5xx/parse → `error`,
  401/403 → `auth`, 429 → `rate-limited` with no request to that source for 5 min. Success
  clears error and backoff.
- **REQ-008** The service SHALL detect credential and `.claude.json` changes by `fileInfo`
  mtime on every tick (30 s) and re-poll that source, replacing v4 FileView watches. A
  changed `oauthAccount.accountUuid` SHALL reset the source to that account's cached
  snapshot (adopt/reset rules of v4 `accounts.js`) and drop any in-flight answer.

### Parsing and logic (lib)

- **REQ-009** `lib/claude.luau` and `lib/grok.luau` SHALL produce the v4 normalized snapshot
  (`{ provider, plan, windows[{ id, periodType?, percent, startMs, endMs }], extra?, products,
  fetchedAt }`, times in epoch ms; `end` is a Luau keyword, hence `startMs`/`endMs`) from decoded JSON tables, with the v4 rules (omit null
  windows, extra in major units, legacy Grok shape → `grok-format`, fresh Grok period without
  percent → 0 %).
- **REQ-010** `lib/time.luau` SHALL parse ISO 8601 timestamps (`Z` or `±hh:mm`, optional
  fractional seconds) to UTC epoch ms without `os.time` local-time conversion; invalid input
  → `nil`.
- **REQ-011** `lib/pace.luau`, `lib/format.luau`, `lib/poll.luau`, `lib/notify.luau`,
  `lib/accounts.luau`, `lib/creds.luau` SHALL port the v4 modules one to one, with their
  vitest cases ported to Luau.

### State channel

- **REQ-012** The service SHALL publish one plain `view` value on `noctalia.state` holding,
  per source: key, provider, name, frozen, email, snapshot (projected), stale, error, code,
  retryAt, inFlight; plus `barKey` and `now`, republished on every tick so countdowns move.
  Widget and panel SHALL render only from it.
  Commands from views SHALL go through state counters (`cmd.refresh`, `cmd.cycle`) that the
  service watches.

### Bar

- **REQ-013** The widget SHALL `barWidget.render` a row (horizontal bar) of glyph
  (`asterisk` / `brand-x`), label `Format.barText` and a 40 px `ui.progress` colored by
  status (`primary` / `tertiary` / `error`); vertical bar: column of glyph and progress. No
  data: glyph and `—`. Stale: label at 0.6 opacity. Tooltip rows: account name (when more
  than one Claude source), one row per window, limit message, error message.
- **REQ-014** Left click SHALL toggle the panel (`noctalia.togglePanel`). Middle click SHALL
  cycle the bar source; the choice SHALL persist in `pluginDataDir()/selection.json` and
  survive restarts. At start the persisted choice wins when its source still exists; only a
  *change* of `bar_provider` seen in `onConfigChanged` SHALL override it.

### Panel

- **REQ-015** The panel SHALL render a header (title, refresh button disabled while any
  source is in flight) and one card per provider: Claude card with an account switch
  (Active / frozen names) when more than one Claude source exists, email line, plan label,
  "updated N ago" / stale / frozen badge, one row per window (label, `ui.progress`, %, reset
  countdown and pace), extra usage row with money text, limit-reached line, error line; Grok
  card with period row and product rows. Inside a `ui.scroll` so a fixed panel height fits.

### Notifications, cache, i18n

- **REQ-016** On each new snapshot the service SHALL fire `noctalia.notify` (informational,
  never `notifyError`) once per window
  crossing `notify_threshold` upward (v4 `notify.js` arming rules, keyed by source).
- **REQ-017** Snapshots (usage data only) SHALL persist in `pluginDataDir()/snapshots.json`
  keyed as v4 (`claude`, `grok`, `byAccount[uuid]`) and be restored stale at start.
- **REQ-018** Every UI string SHALL go through `noctalia.tr` with `translations/en.json` and
  `translations/pt-BR.json` having the same key set (a Luau test enforces it) and covering
  every `label_key` / `description_key` in `plugin.toml`.

### Tooling and docs

- **REQ-019** `./run-tests` SHALL also wrap `translations/*.json`, `tests/fixtures/*.json`
  and `plugin.toml` as string modules for tests, and run `tests/*.test.sh` (the ported
  `claude-swap` test, bash + `jq`). `tests/support/noctalia_mock.luau` SHALL gain
  `noctalia.http`, `noctalia.fileInfo`, `barWidget.render`, `barWidget.isVertical` and
  `panel.render`/`panel.close`, recorded like the other members. These scaffold changes stay
  in this repo. CI runs `./run-tests` plus `noctalia plugins lint .` when available.
- **REQ-020** `README.md` SHALL follow the community structure (title, plugin table with
  exact ids, usage, `noctalia msg panel-toggle nandomoreirame/aibar:panel`, requirements,
  settings, IPC, notes with the network/file disclosure); `thumbnail.webp` 960x540;
  `CLAUDE.md` and `docs/SMOKE.md` rewritten for v5. `thumbnail.webp` and
  `screenshots/panel.png` come from a real panel screenshot taken during the smoke run.
- **REQ-021** The service SHALL handle `onIpc("refresh")` and `onIpc("cycle")`, reachable with
  `noctalia msg plugin nandomoreirame/aibar:usage all <action>`. Logs SHALL carry only the
  source key and HTTP status.

## Architecture Decisions

- **AD-101 Service owns all I/O.** One `[[service]]` reads files, calls HTTP, persists cache
  and selection, fires notifications. Widget and panel are pure renderers of `view` plus
  command senders. Keeps tokens in one VM (REQ-005).
- **AD-102 lib takes decoded tables.** Entries call `noctalia.json.decode`; lib parsers take
  tables, so lib stays host-free and testable with the scaffold mock.
- **AD-103 mtime polling replaces FileView watches.** A 30 s service tick checks `fileInfo`
  mtimes; cheap and close enough to the v4 watch latency.
- **AD-104 Selection outside config.** v5 plugins cannot write config (W4), so the middle
  click choice lives in `pluginDataDir`, with the setting as default and override.
- **AD-105 Daybar UI kit dropped.** `Card.qml`/`PillButton.qml` have no v5 equivalent; cards
  are `ui.column` with `fill`/`radius`.

## Edge Cases

All v4 edge cases hold (expiry margin, past `resets_at`, utilization > 100 clamped for the
bar, null windows omitted, first Grok issuer, missing `currentPeriod`, offline start). New:

- `noctalia.json.encode` of an empty `products` table may emit `{}`; parsers and the cache
  restore SHALL treat a missing or non-array `products` as empty.
- Late `noctalia.http` callback after a swap or a newer request: dropped by generation id.
- `selection.json` names a source that no longer exists: fall back to `bar_provider`, then
  `claude`.
- Widget loaded before the service published `view`: render glyph + `—`.
- `claude_accounts` entries with invalid dirs, duplicates or `~/.claude`: dropped (v4 rules),
  max 4.

## Out of Scope (follow-ups)

- Backporting the extended mock and `run-tests` to `~/.dotfiles/templates/noctalia-plugin`.
- The community-plugins PR itself.

## Known gaps vs v4

- Widget highlight while its panel is open (host-owned in v5).
- Panel height does not follow content (W7); content scrolls instead.
- Warning-styled toast: v5 has `notify` and `notifyError` only; threshold toasts use `notify`.
- `~/.claude.json` is re-decoded on most ticks while `claude` runs (about 250 KB today). Accepted cost; revisit if the host logs a callback budget overrun.

## Grilling Log

Decisions surfaced and resolved during the grilling pass (pre-build stress test).

| # | Decision | Resolution | Rationale |
|---|----------|------------|-----------|
| 1 | v4 code on `main` | Removed; `legacy-v4` keeps it | One manifest, one test suite |
| 2 | Bar source choice without config writes | Middle click (`middle = "none"`) cycles, persisted in `pluginDataDir` | Keeps the v4 shortcut |
| 3 | Distribution | Personal symlink, community-ready files, id `nandomoreirame/aibar` | PR later without rework |
| 4 | `claude-swap` | Stays in `scripts/`, test ported to bash | Independent of the shell |
| 5 | Version | `0.2.0` | Parity port, no product change |
| 6 | Scaffold extensions | Local to this repo; template backport is a follow-up | Unblocks the port |
| 7 | View clock | Service 30 s tick republishes `view` with `now` | One timer, consistent countdowns |
| 8 | IPC | `refresh` and `cycle` on the service | Same as v4 |
| 9 | Panel size | 400x560, attached, open near click, `ui.scroll` | Fits 2 Claude accounts + Grok without scrolling |
| 10 | Threshold toast | `noctalia.notify` | Informational, like the v4 warning |
| 11 | Selection override | Only a change of `bar_provider` overrides the persisted choice | Middle click stays persistent |
| 12 | Frozen accounts | Still polled, login errors quiet (v4) | Parity |
| 14 | Snapshot time fields | `startMs`/`endMs` | `end` is reserved in Luau |
| 15 | Grok issuer order | Alphabetically first issuer with a key | Luau tables have no key order |
| 13 | Thumbnail | Real panel screenshot from the smoke run, 960x540 webp | Community requirement |

## Traceability

See `docs/plans/2026-10-14-aibar-v5.md` (Traceability table).
