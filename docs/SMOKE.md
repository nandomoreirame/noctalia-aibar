# Smoke test (manual)

Run after `npm test` is green, with the plugin symlinked and enabled. Watch the
shell log in another terminal: `qs log -c noctalia-shell -f | grep -i aibar`.
Any `aibar` error or `ReferenceError`/`TypeError` fails the run.

The strings below are the pt-BR catalog, which is what this machine shows.

| # | REQ | Step | Expected |
|---|-----|------|----------|
| 1 | REQ-001 | Rename `~/.claude/.credentials.json` aside, then `qs -c noctalia-shell ipc call plugin:aibar refresh` | Claude card shows "Rode `claude` para entrar". No request in the log. Put the file back. |
| 2 | REQ-001 | Set `expiresAt` in that file to a past timestamp (copy the file aside first; do not leave it expired), reload | Claude card shows "Token do Claude expirou: abra o `claude` para renovar" and no usage request is sent. Restore the file. |
| 3 | REQ-002 | Rename `~/.grok/auth.json` aside and refresh | Grok card shows "Rode `grok login`". Put the file back. |
| 4 | REQ-003 | With both CLIs logged in, refresh and read the shell log | Log lines are `aibar`, the provider and a status. No token, header or credential path contents. |
| 5 | REQ-004 | Leave the shell running past one poll interval, and press the panel refresh button | Each provider is fetched again. A second refresh while one is in flight does not start another request. |
| 6 | REQ-005 | Disconnect the network and refresh | The last numbers stay, the bar text dims, the card shows "desatualizado" and "Erro de rede". Reconnect: the next success clears it. |
| 7 | REQ-006 | With a normal Claude response, open the panel | Rows for the 5h session and the weekly window. Extra usage, when present, shows used/limit in major units (BRL). A model window appears only when the response has it. |
| 8 | REQ-007 | With a normal Grok response, open the panel | One period row (Semanal or Mensal), product rows with a percent. A legacy billing body shows "Formato inesperado do billing do Grok". |
| 9 | REQ-008 | Compare a window's percent with how much of its interval has elapsed | At or above 90% the bar is the error color. More than 10 points ahead of elapsed time, the tertiary color. Otherwise primary. The row says "N pts à frente", "N pts atrás" or "no ritmo". |
| 10 | REQ-009 | Look at the bar on Claude, then on a vertical bar position | Icon, `47% · 1h12m` style text, and a short progress bar. Vertical bar: icon and the bar only. No data: icon and "—". Stale: the text is dimmed. |
| 11 | REQ-010 | Middle click the widget, then restart the shell | The bar switches to the other provider and stays there after the restart. Left click opens the panel. Hover lists every window of that provider. |
| 12 | REQ-011 | Open the panel | One card for Claude Code and one for Grok, whatever the bar shows. Each has a name, a plan label when known, "atualizado há N min" or "desatualizado", and a row per window. The refresh button polls both and is reachable with Tab. |
| 13 | REQ-012 | Set the notify threshold below the current percent of a window that has not fired yet | One warning toast for that window. A later poll at a higher percent does not toast again. Dropping below the threshold, or a new reset time, allows one more toast. Threshold 0 sends nothing. |
| 14 | REQ-013 | Settings: change the bar provider, the interval, the threshold and the User-Agent, confirm, restart the shell | The four values persist and the poll interval follows the saved minutes (minimum 2). |
| 15 | REQ-014 | Switch the shell language between pt and en | Every label comes from `i18n/pt.json` or `i18n/en.json`. `npm test` checks the two catalogs have the same keys. |
