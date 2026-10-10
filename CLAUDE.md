# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

All 15 plan tasks are implemented. Design references:

- Spec: `docs/specs/aibar/SPEC.md` (REQ-001..014, verified claims V1..V10, AD-001..005,
  edge cases)
- Plan: `docs/plans/2026-10-10-aibar.md` (normalized snapshot shape, task breakdown)

## What it is

`aibar` is a personal Noctalia Shell **v4** plugin (QML, run as `qs -c noctalia-shell`)
that shows Claude Code and Grok (SuperGrok / Grok Build) plan usage in the bar
(percent, reset countdown, progress bar) and in a panel. Noctalia v5 is not a target.
Sibling project and architecture reference: `~/dev/projects/noctalia-daybar`
(`vitest.config.js` is copied verbatim from it).

## Commands

```bash
npm install
npm test                          # full vitest suite
npm test -- tests/claude.test.js  # single file
```

Read the `Tests  N passed` line; never trust the exit code of a piped command.

## Architecture

- `utils/**/*.js`: all logic as QML JavaScript libraries (`.pragma library`,
  `.import "x.js" as X`, no ES `import`/`export`, top-level declarations at column 0 so
  the `qml-library-to-esm` transform in `vitest.config.js` exports them). Pure
  functions, TDD. Modules: `claude`, `grok` (parsers), `creds`, `pace`, `format`,
  `poll` (in-flight/backoff/stale state machine), `notify` (threshold crossing).
- QML (`Main.qml`, `BarWidget.qml`, `Panel.qml`, `Settings.qml`, `components/`): I/O and
  rendering only. The look follows Daybar: `components/ui/Card.qml` and `PillButton.qml`
  are copied from it, spacing uses `Math.round(N * Style.uiScaleRatio)`, and `Panel.qml`
  sets `contentPreferredHeight` from its layout (without it SmartPanel opens tall). Services, FileView and
  timers live in `Main.qml`; views reach them through `pluginApi.mainInstance`.
- Both parsers return one normalized snapshot (AD-004) consumed by bar, tooltip, panel
  and notifications; its shape is defined at the top of the plan. Window ids: Claude
  `session`, `weekly`, `weekly-opus`, `weekly-sonnet`; Grok `period`.
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

- Credentials are **read-only**: never write, copy, cache or refresh them, never put a
  token in a property, argv, file or log. An expired token is shown to the user as an
  action, not refreshed. Requests use QML `XMLHttpRequest` only (no curl: the token
  would show in `/proc`).
- No `eval`/`Function`. UI strings through `pluginApi?.tr()` with `i18n/pt.json` and
  `i18n/en.json` in sync (a coverage test enforces it).
- Never write absolute home paths (`/home/...`) in files: a global pre-commit hook
  rejects them. Use `/data/u` in fixtures.
