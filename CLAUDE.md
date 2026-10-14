# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

v5 port of aibar (Luau, `plugin.toml`, plugin API 22, version 0.2.0). Design references:

- Spec: `docs/specs/aibar-v5/SPEC.md` (REQ-001..021)
- Plan: `docs/plans/2026-10-14-aibar-v5.md`

The v4 QML plugin for noctalia-shell 4.7.x is frozen on branch
[`legacy-v4`](https://github.com/nandomoreirame/noctalia-aibar/tree/legacy-v4) (v0.1.3). Do not port changes back to it.

## What it is

`aibar` is a personal Noctalia **v5** plugin, id `nandomoreirame/aibar`. It shows
Claude Code and Grok (SuperGrok / Grok Build) plan usage in the bar (percent, reset
countdown, progress bar) and in a panel.

## Commands

```bash
./run-tests                              # full suite, then tests/*.test.sh
./run-tests tests/<name>.test.luau       # one Luau file
noctalia plugins lint .
```

Read the `N passed, M failed` line and the `claude-swap:` line. A piped command
reports the pipe's exit code, not the suite's.

## Architecture

- `service.luau` is the only entry that reads credentials, calls HTTP, writes
  `snapshots.json` and `selection.json`, and fires notifications. It publishes one
  `view` on `noctalia.state` and watches the counters `cmd.refresh` and `cmd.cycle`.
- `widget.luau` and `panel.luau` render only from `view`. Left click toggles the
  panel. Middle click increments `cmd.cycle`. The panel refresh button increments
  `cmd.refresh`.
- `lib/*.luau` is pure: no `noctalia`, `barWidget`, `panel` or `ui` globals. Each
  module returns one table. Siblings are required as `require("./x.luau")`. Modules:
  `time`, `creds`, `pace`, `format`, `poll`, `notify`, `accounts`, `claude`, `grok`,
  `view`, `present`.
- `end` is a Luau keyword. Window bounds are `startMs` and `endMs` (epoch ms).
  Window ids: Claude `session` (5h), `weekly` (7d), `weekly-opus`, `weekly-sonnet`;
  Grok `period` with `periodType` `weekly` or `monthly`.
- Tests load plugin modules with `modules.load("lib/x.luau")` (`tests/support/modules.luau`),
  which compiles the source the way the host does. `tests/support/noctalia_mock.luau`
  records HTTP, files, state, `barWidget` and `panel`.
- Fixtures in `tests/fixtures/` are real responses with personal fields removed.
  `grok-billing-legacy.json` is the shape Grok returns when `format=credits` or the
  token header is missing.

## Endpoints

| Provider | Request | Credential |
|----------|---------|------------|
| Claude | `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-cli/<ver> (external, cli)` | `~/.claude/.credentials.json` → `claudeAiOauth.accessToken` (`expiresAt` in ms) |
| Grok | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`, headers `Authorization: Bearer`, `X-XAI-Token-Auth: xai-grok-cli` | `~/.grok/auth.json` → first issuer entry with a `key` |

Without the Claude Code `User-Agent` the Claude endpoint answers 429.

## Hard constraints

- Credentials are **read-only**: never write, copy, cache or refresh them. An expired
  token is shown to the user as an action, not refreshed.
- Tokens exist only in locals of `pollSource` and in the `headers` list passed to
  `noctalia.http`. Never put a token in `noctalia.state`, a log, a file, argv or a
  notification.
- Paths stay `~/...` (the host expands them). Never write an absolute home path
  in a file: a global pre-commit hook rejects it. Use `/data/u` in fixtures.
- UI strings go through `noctalia.tr`. `translations/en.json` and `translations/pt-BR.json`
  stay in sync (a coverage test enforces it).
