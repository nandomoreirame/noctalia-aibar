# AI Bar

A [Noctalia Shell](https://github.com/noctalia-dev/noctalia) plugin that shows
Claude Code and Grok (SuperGrok / Grok Build) plan usage in the bar and in a
panel: percent, reset countdown and a progress bar.

> [!IMPORTANT]
> AI Bar is a **Noctalia Shell v4** plugin (QML, `manifest.json`), tested on
> **noctalia-shell 4.7.7**. It does **not** run on Noctalia v5, whose plugin system
> is a different one (Luau scripts with a `plugin.toml` manifest). A v5 port is
> planned. See [Compatibility](#compatibility).

## Compatibility

| Noctalia | Status |
|----------|--------|
| v4 (`noctalia-shell` 4.7.x, run as `qs -c noctalia-shell`) | Supported, tested on 4.7.7 |
| v4 before 4.7 | Untested |
| v5 (`noctalia` 5.x) | Not supported: v5 plugins are written in Luau, so AI Bar would need a rewrite |

**v5 is planned.** I intend to port AI Bar to Noctalia v5 once I have it installed
and tested on my CachyOS setup. Until then, v4 is the only supported target.

On Arch/CachyOS the v4 shell is the `noctalia-shell` package and v5 is `noctalia`;
both can be installed side by side. Check the installed v4 version with
`pacman -Q noctalia-shell`, and make sure the bar you use is started with
`qs -c noctalia-shell`.

## Requirements

- noctalia-shell 4.7.x (see [Compatibility](#compatibility))
- `claude` CLI, logged in (`~/.claude/.credentials.json` present)
- `grok login` already done (`~/.grok/auth.json` present)

The plugin only reads those files. It never writes them, copies them, or refreshes
a token.

## Install

```bash
git clone https://github.com/nandomoreirame/noctalia-aibar ~/dev/projects/noctalia-aibar
ln -s ~/dev/projects/noctalia-aibar ~/.config/noctalia/plugins/aibar
```

Enable **AI Bar** in Noctalia Settings > Plugins, then add the **AI Bar** widget
to the bar.

## Settings

| Setting | Default | What it does |
|---------|---------|--------------|
| Provider in the bar | Claude Code | Which provider the bar widget shows. Middle click on the widget switches it and the choice is saved. |
| Refresh every (minutes) | 5 | Poll interval. Minimum 2. |
| Notify at (%) | 97 | One toast when a window crosses this percent upward. 0 turns notifications off. |
| Claude User-Agent | `claude-cli/2.1.281 (external, cli)` | Must look like a published Claude Code CLI, or the usage endpoint answers 429. |

## Data sources

| Provider | Endpoint | Credential file | Notes |
|----------|----------|-----------------|-------|
| Claude Code | `GET https://api.anthropic.com/api/oauth/usage` | `~/.claude/.credentials.json` (`claudeAiOauth.accessToken`) | Read-only. Headers: `Authorization`, `anthropic-beta: oauth-2025-04-20`, `User-Agent`. No token refresh. |
| Grok | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` | `~/.grok/auth.json` (first non-empty `key`) | Read-only. Headers: `Authorization`, `X-XAI-Token-Auth: xai-grok-cli`. Without `format=credits` the server answers a legacy shape the plugin refuses. |

The token is sent only as a request header from QML `XMLHttpRequest`. It is never
written to a property, a file, argv or the log.

## Failures

A failed request keeps the last good snapshot and marks it stale: the bar text
dims and the card shows a stale badge, plus the error. Network errors, HTTP 5xx
and unparseable bodies are errors. HTTP 401 and 403 are auth errors. HTTP 429
waits five minutes before the next request to that provider. A later success
clears the error and the wait.

## Development

```bash
npm install
npm test
```

Logic lives in `utils/**/*.js` (QML libraries). `vitest.config.js` turns those
libraries into ES modules for the tests only. The files on disk stay valid QML.

## Credits

The endpoint contracts were learned from
[akitaonrails/ai-usagebar](https://github.com/akitaonrails/ai-usagebar) (MIT).
No code was reused.
