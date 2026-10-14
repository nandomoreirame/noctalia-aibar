# Smoke test (manual)

Run after `./run-tests` is green, with the plugin symlinked and enabled. Watch the
log in another terminal: `journalctl --user -f | grep -i aibar` (or the noctalia
log path the host prints). Any `aibar` error fails the run.

Refresh with `noctalia msg plugin nandomoreirame/aibar:usage all refresh`. Open
the panel with `noctalia msg panel-toggle nandomoreirame/aibar:panel`. Settings
live in Settings → Plugins.

The strings below are the pt-BR catalog, which is what this machine shows.

| # | REQ | Step | Expected |
|---|-----|------|----------|
| 1 | REQ-004 | Rename `~/.claude/.credentials.json` aside, then refresh | Claude card shows "Rode `claude` para entrar". No request in the log. Put the file back. |
| 2 | REQ-004 | Set `expiresAt` in that file to a past timestamp (copy the file aside first; do not leave it expired), then refresh | Claude card shows "Token do Claude expirou: abra o `claude` para renovar" and no usage request is sent. Restore the file. |
| 3 | REQ-004 | Rename `~/.grok/auth.json` aside and refresh | Grok card shows "Rode `grok login`". Put the file back. |
| 4 | REQ-005 | With both CLIs logged in, refresh and read the log | Log lines are `aibar`, the source key and a status. No token, header or credential path contents. |
| 5 | REQ-006 | Leave the shell running past one poll interval, and press the panel refresh button | Each provider is fetched again. A second refresh while one is in flight does not start another request. |
| 6 | REQ-007 | Disconnect the network and refresh | The last numbers stay, the bar text dims, the card shows "desatualizado" and "Erro de rede". Reconnect: the next success clears it. |
| 7 | REQ-009 | With a normal Claude response, open the panel | Rows for the 5h session and the weekly window. Extra usage, when present, shows used/limit in major units (BRL). A model window appears only when the response has it. |
| 8 | REQ-009 | With a normal Grok response, open the panel | One period row (Semanal or Mensal), product rows with a percent. A legacy billing body shows "Formato inesperado do billing do Grok". |
| 9 | REQ-011 | Compare a window's percent with how much of its interval has elapsed | At or above 90% the bar is the error color. More than 10 points ahead of elapsed time, the tertiary color. Otherwise primary. The row says "N pts à frente", "N pts atrás" or "no ritmo". |
| 10 | REQ-013 | Look at the bar on Claude, then on a vertical bar position | Icon, `47% · 1h12m` style text, and a short progress bar. Vertical bar: icon and the bar only. No data: icon and "—". Stale: the text is dimmed. |
| 11 | REQ-014 | Middle click the widget, then restart the shell | The bar switches to the next source and stays there after the restart. Left click opens the panel. Hover lists every window of that source. |
| 12 | REQ-015 | Open the panel | One card for Claude Code and one for Grok, whatever the bar shows. Claude accounts share one card with tabs. Each card has a name, a plan label when known, "atualizado há N min" or "desatualizado", and a row per window. The refresh button polls every source and is reachable with Tab. |
| 13 | REQ-016 | Set the notify threshold below the current percent of a window that has not fired yet | One warning toast for that window. A later poll at a higher percent does not toast again. Dropping below the threshold, or a new reset time, allows one more toast. Threshold 0 sends nothing. |
| 14 | REQ-003 | Settings → Plugins: change the bar provider, the interval, the threshold, the User-Agent and the frozen accounts, confirm, restart the shell | The five values persist and the poll interval follows the saved minutes (minimum 2). |
| 15 | REQ-018 | Switch the shell language between pt and en | Every label comes from `translations/pt-BR.json` or `translations/en.json`. `./run-tests` checks the two catalogs have the same keys. |
| 16 | REQ-008 | Close every `claude` session, run `scripts/claude-swap`, and watch the Claude card | Within 30 s the card follows the account that is now active. Swap back when finished. |
