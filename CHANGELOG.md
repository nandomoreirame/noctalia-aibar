# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) and follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]


## [0.1.0] - 2026-10-10

### Added

- Add the Noctalia Shell v4 plugin `aibar`, showing Claude Code and Grok plan usage in the bar and in a panel.
- Add a bar widget with the plan percent, reset countdown and a progress bar colored by pace (on track, ahead, critical), a tooltip listing every window, middle click to switch provider, and an active state while the panel is open.
- Add a panel with one usage card per provider: Claude session, weekly and per-model windows plus extra usage spent, Grok weekly or monthly period, and "pts ahead/behind" pace hints.
- Add polling of the Claude OAuth usage endpoint and the Grok billing endpoint through `XMLHttpRequest`, reading the CLIs' credential files read-only and never storing, logging or refreshing a token.
- Add a request state machine with in-flight guard, 429 backoff, stale-data marking and actionable errors for missing or expired logins.
- Add credential file reloading on change and on every refresh, so a new `claude` or `grok` login is picked up without restarting the shell.
- Add a toast notification that fires once when a window crosses the usage threshold and re-arms after it resets.
- Add settings for the bar provider, poll interval, notification threshold and Claude `User-Agent`, plus a `plugin:aibar` IPC target with `refresh` and `toggle`.
- Add English and Portuguese translations, with a test that keeps both catalogs in sync.
- Add a README with a panel screenshot and a smoke-test checklist.
