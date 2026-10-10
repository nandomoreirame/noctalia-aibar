# SPEC: aibar

**Status:** approved (2026-10-10) · **Depth:** Deep (14 REQs) · **Repo:** `noctalia-aibar`

## Summary

`aibar` is a personal Noctalia Shell v4 plugin (QML, `manifest.json`, run as
`qs -c noctalia-shell`) that shows the plan usage of **Claude Code** and **Grok
(SuperGrok / Grok Build)** in the bar and in a panel. It follows the Daybar
architecture: all logic in pure `utils/**/*.js` QML libraries tested with vitest,
services in `Main.qml`, thin QML views.

Inspired by `akitaonrails/ai-usagebar` (endpoints, headers and pitfalls), without
reusing its code. Personal use only: no registry publishing goal.

## Goals

- See at a glance, in the bar, the usage % of the most critical window of one
  provider, the time to its reset and a small progress bar.
- See both providers in detail in a panel: every window, reset countdown and pace.
- Never touch the CLIs' credentials beyond reading them.

## Non-goals (out of scope)

- Claude Code context view (local session logs), usage history.
- xAI prepaid Management API balance, SuperGrok banked resets (gRPC-Web).
- Refreshing OAuth tokens (the `claude` and `grok` CLIs own that).
- Any other provider. Noctalia v5.

## Verified Claims

| # | Claim | Evidence |
|---|-------|----------|
| V1 | Claude usage: `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-cli/<ver> (external, cli)`; 200 on 2026-10-10 | live probe; `tests/fixtures/claude-usage.json`; ai-usagebar `src/anthropic/fetch.rs:21-35` |
| V2 | Without a Claude Code User-Agent the endpoint rate-limits hard (429) | ai-usagebar `src/anthropic/fetch.rs:24` |
| V3 | Claude response: `five_hour` / `seven_day` / `seven_day_opus` / `seven_day_sonnet` = `{ utilization (0-100), resets_at (ISO) }` or `null`; `extra_usage` = `{ is_enabled, monthly_limit, used_credits, utilization, currency, decimal_places }` (minor units); plus many unknown codename keys, all `null` | fixture |
| V4 | Claude credentials: `~/.claude/.credentials.json` → `claudeAiOauth.{ accessToken, expiresAt (ms), subscriptionType, rateLimitTier, refreshToken, ... }` | live file keys |
| V5 | Grok usage: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`, headers `Authorization: Bearer <key>`, `X-XAI-Token-Auth: xai-grok-cli`; 200 on 2026-10-10 | live probe; `tests/fixtures/grok-billing.json`; ai-usagebar `src/supergrok/direct.rs:21-45` |
| V6 | Grok response (credits format): `config.{ creditUsagePercent, currentPeriod{ type: "USAGE_PERIOD_TYPE_WEEKLY"\|"..._MONTHLY", start, end }, productUsage[{ product, usagePercent }] }` | fixture |
| V7 | Without `format=credits` / the token header, Grok answers a legacy shape (`monthlyLimit`, `used`, no percent) | `tests/fixtures/grok-billing-legacy.json` |
| V8 | Grok credentials: `~/.grok/auth.json` = `{ "<issuer>": { key, expires_at, email, ... } }`; the long-lived `key` is what the billing call takes | live file keys; ai-usagebar `src/supergrok/direct.rs:100-115` |
| V9 | QML `XMLHttpRequest` in Quickshell sends a custom `User-Agent` and `anthropic-beta` | live test against httpbin.org/headers, 2026-10-10 |
| V10 | Icons exist in Noctalia's Tabler set: `asterisk` (Claude), `brand-x` (Grok), `refresh`, `alert-triangle` | `/etc/xdg/quickshell/noctalia-shell/Commons/IconsTabler.qml` |

## Requirements

### Credentials

- **REQ-001** WHEN the plugin polls Claude THEN the system SHALL read `accessToken`
  and `expiresAt` from `~/.claude/.credentials.json` (`claudeAiOauth`) and SHALL
  never write, copy or refresh it. A missing/unreadable file SHALL yield state
  `auth` with message key `error.claude-login`; `expiresAt` in the past SHALL yield
  state `auth` with `error.claude-expired` and no request.
- **REQ-002** WHEN the plugin polls Grok THEN the system SHALL read the first entry
  of `~/.grok/auth.json` that has a non-empty `key` and SHALL never write or copy
  it. A missing file or key SHALL yield state `auth` with `error.grok-login`.

### Fetch

- **REQ-003** The system SHALL fetch Claude with the headers of V1 (User-Agent
  pinned to a published CLI version, configurable as `claudeUserAgent`) and Grok
  with the headers of V5, using QML `XMLHttpRequest` only. Tokens SHALL appear
  only in request headers: never in argv, files, logs or settings.
- **REQ-004** The system SHALL poll each provider every `pollMinutes` (default 5,
  min 2) while the shell runs, once at startup, and on the panel's refresh
  button; a provider SHALL never have two requests in flight.
- **REQ-005** WHEN a request fails THEN the system SHALL keep the last good
  snapshot, mark it `stale` and record the error: network/5xx/parse → `error`;
  401/403 → `auth`; 429 → `rate-limited` and SHALL send no request to that
  provider for 5 minutes. A success clears the error and the backoff.

### Parsing

- **REQ-006** The Claude parser SHALL map `five_hour` → window `session` (5 h),
  `seven_day` → `weekly` (7 d), `seven_day_opus` / `seven_day_sonnet` →
  `weekly-opus` / `weekly-sonnet` when non-null, and `extra_usage` (when present)
  → `extra { enabled, used, limit, percent, currency }` in major units. Unknown
  keys SHALL be ignored; a body with no usable window SHALL be `error`.
- **REQ-007** The Grok parser SHALL map `creditUsagePercent` + `currentPeriod` →
  window `period` (`weekly` or `monthly` from the type, start/end from the
  period) and each `productUsage` entry → `products[{ name, percent }]`. The
  legacy shape (no `creditUsagePercent`) SHALL be `error` with `error.grok-format`.

### Pace and status

- **REQ-008** For each window the system SHALL compute `elapsed%` from start/end
  (Claude start = `resets_at` minus the window length) and `paceDelta = used% −
  elapsed%` in points. Status: `critical` when used ≥ 90; `ahead` when paceDelta >
  10; else `ok`.

### Bar

- **REQ-009** The bar widget SHALL show, for the provider in `barProvider`
  (default `claude`): its icon, the % of its primary window (Claude `session`,
  Grok `period`), ` · ` and the time to reset (`1h12m`, `3d4h`, `45m`), plus a
  fixed-width (~40 px) progress bar filled with that %, colored by status
  (`ok` primary, `ahead` warning/tertiary, `critical` error). Vertical bar: icon +
  progress bar only. No data: icon + `—`. Stale: text at reduced opacity.
- **REQ-010** Middle click on the widget SHALL toggle `barProvider` between
  `claude` and `grok` and persist it; left click toggles the panel. Hover SHALL
  show a tooltip with every window of that provider (label, %, reset).

### Panel

- **REQ-011** The panel SHALL show one card per provider (both, whatever
  `barProvider` is), each with: header (icon, name, plan label when known,
  "updated N min ago"/stale badge), one row per window (label, progress bar, %,
  reset countdown, pace text "N pts ahead/behind"), Claude extra usage row, Grok
  product rows; an error/auth state with its message instead of rows when there
  is no snapshot; a header refresh button that polls both.

### Notifications and settings

- **REQ-012** WHEN a window's % crosses `notifyThreshold` (default 97) upward THEN
  the system SHALL show one toast for that crossing; it SHALL re-arm only after
  the window resets or drops below the threshold. `notifyThreshold` 0 disables it.
- **REQ-013** Settings SHALL expose `barProvider`, `pollMinutes`,
  `notifyThreshold` and `claudeUserAgent`, with defaults in
  `manifest.json` `metadata.defaultSettings` and a `saveSettings()` function.
- **REQ-014** All UI strings SHALL go through `pluginApi.tr` with `i18n/pt.json`
  and `i18n/en.json` kept in sync (coverage test).

## Architecture Decisions

- **AD-001 Pure core.** `utils/claude.js`, `utils/grok.js`, `utils/pace.js`,
  `utils/format.js`, `utils/poll.js` (state machine: in-flight, backoff, stale),
  `utils/notify.js` (threshold crossing), `utils/creds.js` (credential file
  parsing). QML only does I/O (FileView, XHR, Timer) and rendering.
- **AD-002 XHR, not curl.** V9 proves XHR carries the needed headers; curl would
  put the bearer token in `/proc/<pid>/cmdline`.
- **AD-003 Read-only credentials, no refresh.** Avoids racing the CLIs over
  refresh tokens (ai-usagebar needs a flock for this). An expired Claude token is
  shown as an action for the user.
- **AD-004 One normalized snapshot.** Both parsers return
  `{ provider, plan, windows: [{ id, label, percent, start, end }], extra?, products?, fetchedAt }`
  so bar, tooltip, panel and notifications share one shape.
- **AD-005 Same scaffold as Daybar.** `vitest.config.js` QML-library transform,
  column-0 top-level declarations, `.pragma library`, `.import`.

## Edge Cases

- `expiresAt` within the next minute counts as expired (no doomed request).
- `resets_at` in the past: countdown shows `0m`, pace uses 100 % elapsed.
- `utilization` above 100 is clamped to 100 for the bar width, shown as-is in text.
- Claude windows `null` (e.g. no Opus scope) are omitted, never shown as 0 %.
- `auth.json` with several issuers: first entry with a key wins.
- Grok `currentPeriod` missing but percent present: window without reset text.
- The shell starts offline: state `error`, no snapshot, bar shows `—`.

## Traceability

| REQ | Plan tasks |
|-----|-----------|
| REQ-001, REQ-002 | T3 |
| REQ-003, REQ-004, REQ-005 | T7, T10 |
| REQ-006 | T4 |
| REQ-007 | T5 |
| REQ-008 | T6 |
| REQ-009, REQ-010 | T8, T12 |
| REQ-011 | T13 |
| REQ-012 | T9, T10 |
| REQ-013 | T1, T14 |
| REQ-014 | T2, T15 |
