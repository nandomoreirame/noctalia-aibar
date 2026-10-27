---
slug: multi-provider-tabs
phase: implement
spec_path: docs/specs/multi-provider-tabs/SPEC.md
plan_path: docs/plans/2026-10-27-multi-provider-tabs.md
review_base: 4b352a73428644c83e64cba4ba57ef06547e5f9e
updated: 2026-10-27
---

## Task ledger

| Task | Implemented | Review | Commit |
|---|---|---|---|
| 1 mock commands | yes | agy NONE | 19f6979 |
| 2 format/poll | yes | agy NONE | 4e8600a |
| 3 pace max | yes | agy NONE | aeacc55 |
| 4 notify group | yes | agy NONE | cd714b0 |
| 5 codex lib/creds | yes | Claude panel (agy timed out twice); 1 Medium + 1 Low + test gaps fixed | 7299e7f |
| 6 cursor lib | yes | agy NONE | 0d520e7 |
| 7 agy lib | yes | agy NONE | 35ed251 |
| 8 sources/toggles | yes | agy NONE | 5cd48e1 |
| 9 present cards/bar | yes | agy NONE (9-11 together) | pending: blocked |
| 10 present.panel tabs | yes | agy NONE | pending: blocked |
| 11 panel tab row | yes | agy NONE | pending: blocked |
| 12 i18n/toggles/manifest | yes | agy NONE | 910e2af (owner hunks excluded via temp index) |
| 13 pollers dispatch | yes | agy NONE | b6177ab |
| 14 codex service | yes | agy NONE | 542c2dd |
| 15 cursor service | yes | agy NONE | 324ce3e |
| 16 agy service | yes | agy NONE | 863a14b |
| 17 notify label | yes | agy NONE | 3f4d928 |
| 18 docs | yes | self-review | 46d0e23 |

## Adaptations

- Grok not authenticated, Codex out of quota: implementation by Claude agents; agy reviewed with `--model gemini-3.8-flash-high` (Argon quota exhausted).
- Task 5 review fix: Codex window ids are unique per block (`weekly-2`) and extra-limit ids use the name slug (`extra:<slug>:<span>`) instead of the array position.
- Task 8 took the `enabledProviders` wiring and the `service_helpers` defaults from Task 13, so the existing cycle tests stay on Claude + Grok.

## Blocker

Tasks 9-11 edit `lib/present.luau`, `panel.luau`, `tests/present.test.luau` and `tests/panel.test.luau`, which also carry the owner's earlier uncommitted work (card elapsed bar, header settings/close buttons, panel layout and size; saved as a patch). The hunks overlap, so the task delta cannot be committed without that work. Needs the owner's decision: commit the owner's work first as its own commit, then Tasks 9-11.
