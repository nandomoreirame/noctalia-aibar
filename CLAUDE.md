# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

Pre-implementation. Source of truth:

- Spec: `docs/specs/aibar/SPEC.md` (REQ-001..014, verified claims, architecture decisions)
- Plan: `docs/plans/2026-10-10-aibar.md` (15 TDD tasks with file contents and batches)
- State: `docs/specs/aibar/STATE.md`

## What it is

`aibar` is a personal Noctalia Shell **v4** plugin (QML, run as `qs -c noctalia-shell`)
that shows Claude Code and Grok (SuperGrok / Grok Build) plan usage in the bar
(percent, reset countdown, progress bar) and in a panel. Noctalia v5 is not a target.
Sibling project and architecture reference: `~/dev/projects/noctalia-daybar`.

## Commands

```bash
npm install
npm test                          # full vitest suite
npm test -- tests/claude.test.js  # single file
```

Read the `Tests  N passed` line; never trust the exit code of a piped command.

## Architecture

- `utils/**/*.js`: all logic as QML JavaScript libraries (`.pragma library`,
  `.import "x.js" as X`, top-level declarations at column 0 so the vitest transform
  exports them). Pure functions, TDD.
- QML (`Main.qml`, `BarWidget.qml`, `Panel.qml`, `Settings.qml`, `components/`): I/O and
  rendering only. Services and timers live in `Main.qml`; views reach them through
  `pluginApi.mainInstance`.
- Fixtures in `tests/fixtures/` are real responses with personal fields removed.

## Hard constraints

- Credentials (`~/.claude/.credentials.json`, `~/.grok/auth.json`) are **read-only**: never
  write, copy, cache or refresh them, never put a token in a property, argv, file or log.
  Requests use QML `XMLHttpRequest` only (no curl: the token would show in `/proc`).
- The Claude usage endpoint needs a Claude Code `User-Agent` or it answers 429.
- No `eval`/`Function`. UI strings through `pluginApi?.tr()` with `i18n/pt.json` and
  `i18n/en.json` in sync.
- Never write absolute home paths (`/home/...`) in files: a global pre-commit hook
  rejects them. Use `/data/u` in fixtures.
