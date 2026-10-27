# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

v5 port of aibar (Luau, `plugin.toml`, plugin API 22, version 0.3.0). Design references:

- Spec: `docs/specs/aibar-v5/SPEC.md` (REQ-001..021)
- Plan: `docs/plans/2026-10-14-aibar-v5.md`
- Spec: `docs/specs/multi-provider-tabs/SPEC.md` (Codex, Agy, Cursor and provider tabs, REQ-001..014)
- Plan: `docs/plans/2026-10-27-multi-provider-tabs.md`

The v4 QML plugin for noctalia-shell 4.7.x is frozen on branch
[`legacy-v4`](https://github.com/nandomoreirame/noctalia-aibar/tree/legacy-v4) (v0.1.3). Do not port changes back to it.

## What it is

`aibar` is a personal Noctalia **v5** plugin, id `nandomoreirame/aibar`. It shows
Claude Code, Grok (SuperGrok / Grok Build), Codex, Antigravity (`agy`) and Cursor
plan usage in the bar (percent, reset countdown, progress bar) and in a panel with
one tab per provider (Claude accounts are sub-tabs).

## Commands

```bash
./run-tests                              # full suite, then tests/*.test.sh
./run-tests tests/<name>.test.luau       # one Luau file
noctalia plugins lint .
```

Read the `N passed, M failed` line and the `claude-swap:` line. A piped command
reports the pipe's exit code, not the suite's.

## Architecture

- `service.luau` is the only entry that reads credentials, calls HTTP, runs
  processes (`sqlite3`, `agy`), writes `snapshots.json` and `selection.json`, and
  fires notifications. It polls through a `pollers` table keyed by provider;
  `command()` is the `runAsync` counterpart of `request()`. Sources follow the
  `show_<provider>` settings (Claude is always on). It publishes one
  `view` on `noctalia.state` and watches the counters `cmd.refresh` and `cmd.cycle`,
  plus `cmd.select` (`{ key, n }`), which moves the bar to the source picked in the panel.
- `widget.luau` and `panel.luau` render only from `view`. Left click toggles the
  panel. Middle click increments `cmd.cycle`. The panel refresh button increments
  `cmd.refresh`. Choosing a provider tab or a Claude account tab sets `cmd.select`.
- `lib/*.luau` is pure: no `noctalia`, `barWidget`, `panel` or `ui` globals. Each
  module returns one table. Siblings are required as `require("./x.luau")`. Modules:
  `time`, `creds`, `pace`, `format`, `poll`, `notify`, `accounts`, `claude`, `grok`,
  `codex`, `cursor`, `agy`, `view`, `present`.
- `end` is a Luau keyword. Window bounds are `startMs` and `endMs` (epoch ms).
  Window ids: Claude `session` (5h), `weekly` (7d), `weekly-opus`, `weekly-sonnet`;
  Grok `period` with `periodType` `weekly` or `monthly`; Codex `session`/`weekly`
  (classified by window length) plus extra limits `extra:<name-slug>:<span>` with
  `group`/`span`; Cursor `period` monthly; agy one window per bucket id with
  `group`/`span` and `snapshot.primary = "max"` (the bar shows the most-used one).
- Tests load plugin modules with `modules.load("lib/x.luau")` (`tests/support/modules.luau`),
  which compiles the source the way the host does. `tests/support/noctalia_mock.luau`
  records HTTP, files, state, `barWidget` and `panel`.
- Fixtures in `tests/fixtures/` are real responses with personal fields removed
  (`cursor-usage.json` keeps the real shape with its zero percentages raised).
  `grok-billing-legacy.json` is the shape Grok returns when `format=credits` or the
  token header is missing.

## Endpoints

| Provider | Request | Credential |
|----------|---------|------------|
| Claude | `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-cli/<ver> (external, cli)` | `~/.claude/.credentials.json` → `claudeAiOauth.accessToken` (`expiresAt` in ms) |
| Grok | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`, headers `Authorization: Bearer`, `X-XAI-Token-Auth: xai-grok-cli` | `~/.grok/auth.json` → first issuer entry with a `key` |
| Codex | `GET https://chatgpt.com/backend-api/wham/usage`, headers `Authorization: Bearer`, `ChatGPT-Account-Id`, `User-Agent: codex-cli` | `~/.codex/auth.json` → `tokens.access_token`, `tokens.account_id` |
| Cursor | `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`, body `{}`, headers `Authorization: Bearer`, `Content-Type: application/json`, `Connect-Protocol-Version: 1` | `sqlite3 -readonly ~/.config/Cursor/User/globalStorage/state.vscdb` → `ItemTable` key `cursorAuth/accessToken` |
| Agy | no HTTP: `agy -p "/quota" --output-format json` (no model turn, about 5 s) | none: agy authenticates and renews its own session |

Without the Claude Code `User-Agent` the Claude endpoint answers 429.

## Hard constraints

- Credentials are **read-only**: never write, copy, cache or refresh them. An expired
  token is shown to the user as an action, not refreshed.
- Tokens exist only in locals of the pollers and in the `headers` list passed to
  `noctalia.http`. Never put a token in `noctalia.state`, a log, a file, argv or a
  notification. `runAsync` stdout (the Cursor token, agy output) is never logged.
- Paths stay `~/...` (the host expands them). Never write an absolute home path
  in a file: a global pre-commit hook rejects it. Use `/data/u` in fixtures.
- UI strings go through `noctalia.tr`. `translations/en.json` and `translations/pt-BR.json`
  stay in sync (a coverage test enforces it).
