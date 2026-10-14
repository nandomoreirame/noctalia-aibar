# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) and follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

## [0.1.3] - 2026-10-13

### Added

- Add frozen Claude accounts: list `Name=dir` entries in the "Frozen Claude accounts" setting and the panel shows each one's last status with a "frozen" badge, without asking to renew its token.
- Add `scripts/claude-swap` to swap the active login (`~/.claude`) with the frozen one (`~/.claude-freeze`), moving only `.credentials.json` and the `oauthAccount` block; it refuses to run while a `claude` session is open, and `init` freezes the current login.
- Switch between Claude accounts inside the Claude card (Active · Frozen) and show the logged account email.
- Cycle through every account and Grok with a middle click on the bar widget.

### Changed

- Key cached snapshots by the logged account id, so a swap never shows one account's usage under the other.
- Show how long ago a snapshot was fetched as "2h5m" or "3d0h" instead of minutes.

### Fixed

- Show a window whose reset already passed as 0% instead of its old percent with "resets in 0m".

---

## [0.1.2] - 2026-10-13

### Fixed

- Read a Grok billing period that just reset as 0% instead of failing with "Unexpected Grok billing format" (the API omits zero-valued fields).

---

## [0.1.1] - 2026-10-13

### Added

- Keep the last usage snapshot of each provider in `~/.cache/noctalia/aibar-snapshots.json` (usage data only, never a credential), so the bars come back marked stale right after a shell restart.
- Show "Limit reached: resets in X" in the card and the bar tooltip while a window is at 100%, hiding the login prompt that an unused CLI's expired token would otherwise trigger.

### Changed

- Pin the QtQuick import to version 6.11 across the QML files.

### Fixed

- Fix usage that stopped updating after suspend: QML `XMLHttpRequest` ignores `timeout`, so a request cut mid-flight blocked every later poll. A request older than 30 s is now dropped and aborted when the next one starts, and late answers from it are ignored.

---

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
