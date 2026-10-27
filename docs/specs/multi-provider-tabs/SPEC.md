# Spec: Codex, Antigravity and Cursor usage with provider tabs

**Slug:** multi-provider-tabs
**Status:** approved (2026-10-27)
**Depth:** Deep (14 REQs)
**Base:** aibar v0.2.0 (Noctalia v5, Luau). Builds on `docs/specs/aibar-v5/SPEC.md`.

## Goal

Show plan usage for three more AI coding tools, Codex, Antigravity CLI (`agy`)
and Cursor, next to Claude Code and Grok, and reorganize the panel into one tab
per provider: `Claude // Grok // Codex // Agy // Cursor`.

## Research findings (2026-10-27, live probes with the owner's credentials)

| Provider | Credential | Request | Probe |
|---|---|---|---|
| Codex | `~/.codex/auth.json` → `tokens.access_token`, `tokens.account_id` | `GET https://chatgpt.com/backend-api/wham/usage`, `Authorization: Bearer`, `ChatGPT-Account-Id` | 200: `plan_type`, `rate_limit.primary_window` (5h) and `secondary_window` (7d) with `used_percent`, `limit_window_seconds`, `reset_at` (epoch s) |
| Cursor | SQLite `~/.config/Cursor/User/globalStorage/state.vscdb`, table `ItemTable`, key `cursorAuth/accessToken` | `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`, body `{}`, `Authorization: Bearer`, `Content-Type: application/json` | 200: `billingCycleStart`/`billingCycleEnd` (epoch ms as strings), `planUsage.totalPercentUsed`, `autoPercentUsed`, `apiPercentUsed` |
| Agy | none in the plugin: `agy` itself authenticates (and renews its keyring session) | `agy -p "/quota" --output-format json` via `noctalia.runAsync` | exit 0 in 4.4 to 5.6 s, `num_turns: 0`, zero tokens. `command.data.groups[]` → `{ name, buckets[] }`, bucket `{ id, name, window: "5h" \| "weekly", remaining_fraction, reset_time }` (the same data as agy's Models & Quota page) |

Agy quota sample (2026-10-27): groups `Gemini Models` (`gemini-5h`, `gemini-weekly`),
`Claude and GPT models` (`3p-5h`, `3p-weekly`), `Gemini 4 Argon`
(`gemini-argon-wtu-weekly`, at `remaining_fraction: 0`).

Prior art: [akitaonrails/ai-usagebar](https://github.com/akitaonrails/ai-usagebar)
(`4a98814`, 2026-10-25) uses the same three sources: `wham/usage` for Codex,
`cursorAuth/accessToken` from `state.vscdb` for Cursor, and `agy -p "/quota"` as the
reference reading for agy (90 s timeout, 10 min cooldown after a failure). It notes
that the Cloud Code `retrieveUserQuotaSummary` fallback disagrees with agy (prod
tracks another Gemini counter, daily drops the Gemini group), and that Cursor
3.27.12 replaced the JWT in `cursorAuth/accessToken` with an opaque token.

How ai-usagebar handles the providers this plugin already covers or adds:

| Provider | ai-usagebar | aibar (this spec) |
|---|---|---|
| Claude | `GET /api/oauth/usage?cedar_ember=1`, Claude Code `User-Agent`; reads `five_hour`, `seven_day`, `seven_day_sonnet`, `extra_usage`, `limits[]` (`kind: weekly_scoped` with `scope.model.display_name`, e.g. the Fable weekly cap, which has no `seven_day_*` field) and `cedar_ember.grants` (banked resets); refreshes the OAuth token itself | same endpoint and headers, no refresh; `limits[]` and `cedar_ember` not read (see Out of scope) |
| Grok (SuperGrok) | `GET cli-chat-proxy.grok.com/v1/billing` with the `auth.json` `key` (primary), `x.ai/billing` ACP extension of the CLI (fallback), `grok.com ConsumerUiSvc/GetRemainingResets` gRPC-Web for banked resets | same primary endpoint; no ACP fallback, no resets |
| Codex | `wham/usage` with `User-Agent: codex-cli`, `ChatGPT-Account-Id`; `reset_after_seconds` fallback; `additional_rate_limits`; `model_usage[].available`; refresh at `auth.openai.com/oauth/token` | REQ-001/002 adopt the headers, the fallback and `additional_rate_limits`; no refresh |
| Cursor | `GET cursor.com/api/usage-summary` with the `WorkosCursorSessionToken` cookie plus browser-looking headers (the dashboard CORS check rejects a plain request); `GetClientVisibleCreditGrants` best effort; `cursor-agent` `auth.json` when the IDE db is missing | RPC `GetCurrentPeriodUsage` with a plain Bearer (verified 200, no cookie forging); IDE db only |
| Agy | `agy -p "/quota" --output-format json`; Cloud Code fallback with its own token refresh | `/quota` only |

Rejected alternatives:
- Codex rollouts (`~/.codex/sessions/**/rollout-*.jsonl`, `rate_limits` event): no
  token, but stale whenever Codex is idle.
- Cursor `https://cursor.com/api/usage-summary`: needs a forged session cookie
  (`WorkosCursorSessionToken`); the RPC takes a plain Bearer.
- Agy Cloud Code `v1internal:retrieveUserQuotaSummary` with the keyring token:
  403 `#3501` for a bare request, needs agy's client headers, and its figures
  differ from agy's own page (see prior art). It also puts a token in the plugin.
- Agy `agy -p "/status"`: not a print-mode command, it is sent to the model.

## Requirements

### Codex

- **REQ-001** WHEN the service polls the `codex` source THE SYSTEM SHALL read
  `~/.codex/auth.json` and, with a non-empty `tokens.access_token`, send
  `GET https://chatgpt.com/backend-api/wham/usage` with `Authorization: Bearer <token>`,
  `ChatGPT-Account-Id: <tokens.account_id>` (omitted when empty),
  `User-Agent: codex-cli` and `Accept: application/json`. A missing file or token
  SHALL fail with `codex-login` and no request.
- **REQ-002** WHEN the Codex answer is 200 THE SYSTEM SHALL map
  `rate_limit.primary_window` to window `session` and `secondary_window` to window
  `weekly`, with `percent = used_percent`, `endMs = reset_at * 1000` (or
  `now + reset_after_seconds * 1000` when `reset_at` is absent) and
  `startMs = endMs - limit_window_seconds * 1000`, and `plan = plan_type`. Each
  entry of `additional_rate_limits` (null means none) adds its windows labelled
  with its `limit_name`, since a named pool can be the binding limit while the
  main one reads low. A body without any usable window SHALL fail with `parse`.
  401/403 SHALL show `error.codex-login` ("open `codex` to renew it").

### Cursor

- **REQ-003** WHEN the service polls the `cursor` source THE SYSTEM SHALL read the
  token with `noctalia.runAsync` argv
  `{ "sqlite3", "-readonly", <expanded state.vscdb path>, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'" }`.
  The token never appears in argv; stdout is never logged. `sqlite3` absent
  (`noctalia.commandExists`) SHALL fail with `cursor-sqlite`; exit code ≠ 0 or
  empty stdout SHALL fail with `cursor-login`.
- **REQ-004** WITH a token THE SYSTEM SHALL send
  `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
  with body `{}`, `Authorization: Bearer <token>`,
  `Content-Type: application/json`, `Connect-Protocol-Version: 1`.
- **REQ-005** WHEN the Cursor answer is 200 THE SYSTEM SHALL produce one window
  `period` with `periodType = "monthly"`, `percent = planUsage.totalPercentUsed`
  (0 when absent, protobuf JSON drops zeros), `startMs = billingCycleStart`,
  `endMs = billingCycleEnd` (numeric strings), and two products `Auto` and `API`
  from `autoPercentUsed` / `apiPercentUsed`. No `planUsage` and no billing cycle
  SHALL fail with `parse`.

### Antigravity (agy)

- **REQ-006** WHEN the service polls the `agy` source THE SYSTEM SHALL run
  `noctalia.runAsync` with argv `{ "agy", "-p", "/quota", "--output-format", "json" }`
  and no HTTP request. The plugin reads no agy credential. `agy` absent
  (`noctalia.commandExists`) SHALL fail with `agy-missing`; exit code ≠ 0, or a
  JSON whose `status` is not `SUCCESS`, SHALL fail with `agy-login`
  ("run `agy` to sign in"); stdout is never logged. A failed run holds off the
  next one for the normal poll backoff (`Poll.BACKOFF_MS`), since each run costs
  about 5 s of CPU and network.
- **REQ-007** WHEN `agy` answers THE SYSTEM SHALL map every bucket of
  `command.data.groups[].buckets[]` to one window: `id = bucket.id`,
  `percent = (1 - remaining_fraction) * 100`, `endMs = reset_time`,
  `startMs = endMs - span` (5 h for `window = "5h"`, 7 d for `"weekly"`, none
  otherwise), `group = group.name`, `span = window`. The panel labels a window
  `<group> · <Session (5h) | Weekly>`. The bar shows the most-used agy window, the
  one that blocks first. No group with a bucket SHALL fail with `parse`. A real
  answer (personal fields removed) is the fixture `tests/fixtures/agy-quota.json`.

### Sources, settings and UI

- **REQ-008** THE SYSTEM SHALL add bool settings `show_grok`, `show_codex`,
  `show_agy`, `show_cursor` (default `true`). Sources are, in order:
  `claude`, frozen `claude:<slug>` accounts, `grok`, `codex`, `agy`, `cursor`,
  each provider only when its toggle is on. A disabled source is not polled, has
  no tab and is skipped by the middle-click cycle; turning it on polls it at once.
- **REQ-009** THE panel SHALL show one top tab row `Claude // Grok // Codex // Agy // Cursor`
  (enabled providers only) and render only the selected provider's section. The
  Claude tab keeps its account sub-tabs (Active / frozen names) when there is more
  than one Claude account. The panel opens on the provider of the bar source.
- **REQ-010** `bar_provider` SHALL accept `codex`, `agy` and `cursor`. A disabled
  bar source falls back like a removed account. Glyphs: Claude `asterisk`, Grok
  `brand-x`, Codex `brand-openai`, Agy `brand-google`, Cursor `pointer` (all in
  the host's `tabler.json`). The bar's primary window stays `session`, then
  `period`, then the first window.
- **REQ-011** Snapshots of `codex`, `agy` and `cursor` SHALL be cached in
  `snapshots.json` under their key (like `grok`) and restored stale at boot.
  Threshold notifications SHALL work for every window of the new providers with
  their display name.
- **REQ-012** Every new UI string (provider names, tab labels, errors, settings)
  SHALL exist in `translations/en.json` and `translations/pt-BR.json`.

### Constraints

- **REQ-013** Credentials stay read-only. Tokens live only in locals of the poll
  path and in the `headers` passed to `noctalia.http`; never in `noctalia.state`,
  logs, files, argv or notifications. `noctalia.log` records only the key and the
  HTTP status.
- **REQ-014** README, `plugin.toml` (`description`, `tags`, version `0.3.0`),
  `CLAUDE.md` (endpoints table, module list) and `docs/SMOKE.md` SHALL describe the
  five providers.

## Out of scope

- Multiple accounts for Codex, Agy or Cursor (only Claude has frozen accounts).
- Cursor team usage, on-demand spend, credit grants and Codex credits.
- Banked limit resets (Claude `cedar_ember`, Codex `rate_limit_reset_credits`,
  Grok `GetRemainingResets`).
- Claude model-scoped weekly limits from `limits[]` (an existing-provider gap,
  better as its own feature).
- Other ai-usagebar vendors (Copilot, Kimi, OpenCode Go, Kiro, Factory, Cline,
  Z.AI, OpenRouter...).
- Refreshing any expired token.
- The frozen v4 branch.

## Decisions (defaults taken, owner may override at approval)

| # | Question | Decision |
|---|---|---|
| 1 | Agy source | `agy -p "/quota" --output-format json` (prior art: ai-usagebar); no token in the plugin |
| 2 | Codex source | API `wham/usage` |
| 3 | Panel layout | Provider tabs on top, Claude accounts as sub-tabs |
| 4 | Missing providers | Per-provider toggle settings |
| 5 | Codex window ids | Reuse `session`/`weekly` so pace, bar and notifications need no new code |
| 6 | Cursor window | Reuse Grok's `period`/`monthly`; Auto/API shown as products |
| 7 | Tab labels | Short: Claude, Grok, Codex, Agy, Cursor (not translated); section title keeps the full name |
| 8 | Claude toggle | None: Claude is always on (the plugin's base source) |

## Success criteria

- `./run-tests` green, `noctalia plugins lint .` clean.
- Smoke on the desktop: five tabs, Codex shows 5h + weekly matching `codex /status`,
  Cursor shows the monthly cycle, Agy shows the same groups and percentages as its
  Models & Quota page; middle click cycles through all enabled sources.
