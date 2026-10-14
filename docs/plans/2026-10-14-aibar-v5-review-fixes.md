# Plan: aibar-v5-review-fixes

**Spec:** `docs/specs/aibar-v5/SPEC.md` · **Depth:** Standard · **Tasks:** 7 · **Date:** 2026-10-14
**Depends on:** `docs/plans/2026-10-14-aibar-v5.md` Tasks 1-19 (done, `badbfe5`). Run before
its Task 20 (manual smoke).
**Source:** `/code-review` (high) of `e93e96d..badbfe5`. Findings were read against the host
source in `~/.cache/noctalia-v5-src`, not reproduced; each task below starts with a test that
reproduces its finding.

Fixes to `service.luau` (file-change detection, account swaps, settings changes), the
`claude:<name>` setting value, and the duplicated i18n adapter.

## Global rules for every task

- TDD: write the Luau test, run it and see it fail for the stated reason, implement, run it
  green, then the full suite: `./run-tests`. Read the `N passed, M failed` line and the
  `claude-swap:` line; never trust a piped exit code. Finish with `noctalia plugins lint .`.
- Single file: `./run-tests tests/<name>.test.luau`.
- Service tests use `tests/support/service_helpers.luau` (`h.boot`, `h.requests`, `h.view`,
  `h.sourceOf`, `h.NOW`, `h.CLAUDE_URL`, `h.GROK_URL`, `h.CLAUDE_CRED`, `h.CLAUDE_BODY`, ...)
  and `tests/support/noctalia_mock.luau` (`mock.respond`, `mock.setFile`, `mock.setConfig`,
  `mock.setNow`, `mock.pendingHttp`, `mock.calls`). Files seeded through `h.boot` start with
  `mtime = 1`.
- `lib/*.luau` stays pure (no `noctalia`, `barWidget`, `panel`, `ui` globals); the manifest
  test enforces it.
- Tokens only in the `headers` passed to `noctalia.http`. The secrecy test in
  `tests/service.test.luau` must stay green.
- Never write a `/home/<user>` path in any file. English code, comments and docs.
- No git commands inside tasks except the per-task `/git commit`.

## Out of scope

- Review finding "`~/.claude.json` is re-decoded on most ticks while `claude` runs" (about
  250 KB today). Accepted cost; revisit if the host logs a callback budget overrun. Note it
  under "Known gaps" in the spec when closing this plan.
- A scheduled `pollAll` landing between the two writes of `claude-swap` (milliseconds wide).

## Batches

| Batch | Tasks | Notes |
|-------|-------|-------|
| 1 | T1, T5, T7 | independent |
| 2 | T2 | builds on T1's `changed()` |
| 3 | T3, T4 | touch `request()` / `onConfigChanged()` after T2 |
| 4 | T6 | rewrites `configure()` / `onConfigChanged()`, after T4 |

---

### Task 1: Ignore mtime jitter, notice same-mtime rewrites

**Requirement:** REQ-008 (review finding: exact float `mtime` comparison)
**Files:**
- Modify: `service.luau:211-220` (`changed`)
- Test: `tests/service-events.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: test-driven-development)
- Reviewers: business-logic-reviewer, test-reviewer

**Why:** the host builds `mtime` from two separate clock reads, so the double can differ by a
few ns between calls with no change on disk. Exact equality then re-polls (429 risk).

**Step 1: Write the failing tests** (append a `describe` to `tests/service-events.test.luau`)

```lua
describe("service file fingerprints", function()
	it("ignores sub-millisecond mtime jitter", function()
		local s = h.boot()
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 200, body = h.CLAUDE_BODY })
		mock.setFile(s.env, "~/.claude/.credentials.json", h.CLAUDE_CRED, 1 + 1e-7)
		s.call("update")
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 1)
	end)

	it("notices a rewrite that keeps the mtime but changes the size", function()
		local s = h.boot()
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 200, body = h.CLAUDE_BODY })
		mock.setFile(s.env, "~/.claude/.credentials.json", h.CLAUDE_CRED .. " ", 1)
		s.call("update")
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 2)
	end)
end)
```

(Two `update` calls on purpose: Task 2 defers file-triggered polls by one tick, and these
tests must hold before and after it.)

**Step 2: Run to verify they fail**
Run: `./run-tests tests/service-events.test.luau`
Expected: `FAIL ignores sub-millisecond mtime jitter` (2 requests, expected 1) and
`FAIL notices a rewrite ...` (1 request, expected 2).

**Step 3: Implement** — replace `changed` in `service.luau`:

```lua
-- Millisecond mtime plus size. The host derives mtime from two clock reads, so
-- the raw double can wobble by a few ns with nothing changed on disk.
local function fingerprint(path: string): string
	local info = noctalia.fileInfo(path)
	if not info then
		return "missing"
	end
	return math.floor((tonumber(info.mtime) or 0) * 1000) .. ":" .. (tonumber(info.size) or 0)
end

-- true when the file's fingerprint differs from the last one seen.
local function changed(path: string): boolean
	local seen = fingerprint(path)
	if mtimes[path] == seen then
		return false
	end
	mtimes[path] = seen
	return true
end
```

**Step 4: Run to verify they pass**
Run: `./run-tests tests/service-events.test.luau` then `./run-tests`
Expected: all green.

**Step 5: Commit**
Run: `/git commit`

---

### Task 2: Deferred, non-lossy polls after file changes and swaps

**Requirement:** REQ-008 (review findings: change consumed while a request is in flight;
swap seen between the two `claude-swap` writes)
**Depends on:** Task 1
**Files:**
- Modify: `service.luau` (`pollSource`, `syncIdentity`, `update`, new locals)
- Test: `tests/service-events.test.luau`

**Team:**
- Track: backend (credentials)
- Implementer: backend-engineer (skills: test-driven-development, security-guardrails)
- Reviewers: security-reviewer, business-logic-reviewer, test-reviewer

**Why:** today `changed()` records the new mtime and calls `pollSource`, which returns early
when a request is in flight or a 429 backoff is active, so the change is lost until the next
`pollAll` (up to `poll_minutes`). And `claude-swap` writes `.claude.json` and
`.credentials.json` separately: a tick between the two writes polls one account's token under
the other account's id, poisoning `cache.byAccount`.

**Rule:** a file change marks the source *pending* with the current tick number. A pending
mark is served on a **later** tick, after identities were re-read on that tick, and stays
until `pollSource` actually runs (not blocked by `poll.canRequest`).

**Step 1: Write the failing tests**

Add to `describe("service file changes", ...)`:

```lua
	it("keeps a credential change that arrives while a request is in flight", function()
		local s = h.boot()
		mock.setFile(s.env, "~/.claude/.credentials.json", h.CLAUDE_CRED, 2)
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 1)
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 401, body = "" })
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 2)
	end)

	it("polls a swapped account only with its own token", function()
		local s = h.boot()
		mock.setFile(s.env, "~/.claude.json", '{"oauthAccount":{"accountUuid":"u2","emailAddress":"b@x.dev"}}', 2)
		s.call("update")
		assert.equal(h.sourceOf(s, "claude").email, "b@x.dev")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 1)
		mock.setFile(s.env, "~/.claude/.credentials.json", '{"claudeAiOauth":{"accessToken":"SECRET-B","expiresAt":1891662400000}}', 2)
		s.call("update")
		s.call("update")
		local c = h.requests(s, h.CLAUDE_URL)
		assert.equal(#c, 2)
		local headers = mock.pendingHttp(s.env)[c[2]].request.headers
		local found = false
		for _, line in headers do
			if line == "Authorization: Bearer SECRET-B" then
				found = true
			end
		end
		assert.equal(found, true)
	end)
```

Update the two existing tests in that `describe` for the one-tick deferral:

- `re-polls a source whose credentials changed`: after `setFile`, call `update` twice before
  asserting `2`, then once more and assert it is still `2`.
- `switches to the swapped account, drops the old answer and re-polls`: after `setFile`, call
  `update` twice before reading `h.requests(s, h.CLAUDE_URL)`; the rest stays.

**Step 2: Run to verify they fail**
Run: `./run-tests tests/service-events.test.luau`
Expected: `FAIL keeps a credential change ...` (1 request, expected 2) and
`FAIL polls a swapped account ...` (the reset polls at once: 2 requests after the first
update, expected 1).

**Step 3: Implement** in `service.luau`

New locals next to `mtimes`:

```lua
local tick = 0
-- key -> tick when a file change asked for a poll; served on a later tick.
local pending = {}
```

`pollSource` returns whether it ran. Change the early return to `return false` and add
`return true` at the end of both provider branches (credential errors count as run: the new
file was read).

In `syncIdentity`, replace the last line `pollSource(source)` of the reset branch with:

```lua
	-- Wait a tick: claude-swap writes .claude.json and .credentials.json separately.
	pending[key] = tick
```

Replace `update`:

```lua
function update()
	tick += 1
	for _, s in sources do
		if s.provider == "claude" and changed(accounts.configPath(s)) then
			syncIdentity(s)
		end
	end
	for _, s in sources do
		local mark = pending[s.key]
		if mark ~= nil and mark < tick and pollSource(s) then
			pending[s.key] = nil
		end
	end
	for _, s in sources do
		if changed(accounts.credPath(s)) and pending[s.key] == nil then
			pending[s.key] = tick
		end
	end
	if now() >= nextPollAt then
		pollAll()
	else
		publish()
	end
end
```

**Step 4: Run to verify they pass**
Run: `./run-tests tests/service-events.test.luau` then `./run-tests`
Expected: all green, including the Task 1 tests.

**Step 5: Commit**
Run: `/git commit`

---

### Task 3: Keep the answer of a request started before the account was known

**Requirement:** REQ-008 (review finding: "adopt" drops the in-flight answer and leaves
`inFlight = true`)
**Depends on:** Task 2
**Files:**
- Modify: `service.luau:108` (`request` callback guard)
- Test: `tests/service-events.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: test-driven-development)
- Reviewers: business-logic-reviewer, test-reviewer

**Why:** with `~/.claude.json` unreadable at start (mid-write), the request starts with
account `""`. A later tick adopts the id, and the guard `uuidOf(key) ~= account` drops the
answer: no data and a disabled refresh button until the next `pollAll`. v4 only dropped the
answer when the request had a known account (`if (account && ...)`).

**Step 1: Write the failing test** (add to `describe("service file changes", ...)`)

```lua
	it("keeps the answer of a request started before the account was known", function()
		local s = h.boot({ fs = { ["~/.claude.json"] = false } })
		mock.setFile(s.env, "~/.claude.json", h.CLAUDE_JSON, 2)
		s.call("update")
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 200, body = h.CLAUDE_BODY })
		local c = h.sourceOf(s, "claude")
		assert.equal(c.inFlight, false)
		assert.equal(c.snapshot.windows[1].percent, 47)
		local saved = mock.json.decode(s.env.noctalia.readFile("/mock/plugin-data/snapshots.json"))
		assert.equal(saved.byAccount.u1.windows[1].percent, 47)
	end)
```

**Step 2: Run to verify it fails**
Run: `./run-tests tests/service-events.test.luau`
Expected: `FAIL keeps the answer ...` (`inFlight` is `true`, snapshot `nil`).

**Step 3: Implement** — change the guard in `request`:

```lua
		-- A request started without a known account belongs to whichever account is
		-- adopted next; one started with a known account is dropped after a swap.
		if generation[key] ~= id or (account ~= "" and uuidOf(key) ~= account) then
			return
		end
```

**Step 4: Run to verify it passes**
Run: `./run-tests tests/service-events.test.luau` then `./run-tests`
Expected: all green (the swap test still drops the pre-swap answer: that request started
with `u1`).

**Step 5: Commit**
Run: `/git commit`

---

### Task 4: A vanished bar source falls back to `bar_provider`

**Requirement:** REQ-014 and the spec edge case "`selection.json` names a source that no
longer exists" (review finding)
**Depends on:** Task 2
**Files:**
- Modify: `service.luau:298-309` (`onConfigChanged`)
- Test: `tests/service-events.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: test-driven-development)
- Reviewers: business-logic-reviewer, test-reviewer

**Why:** with `bar_provider` unchanged, a removed account makes `resolveKey` fall to
`sources[1]` (`claude`) instead of the setting, and `selection.json` keeps the dead key, so
runtime and the next boot disagree.

**Step 1: Write the failing test** (add to `describe("service commands and selection", ...)`)

```lua
	it("falls back to bar_provider when the chosen account is removed", function()
		local s = h.boot({
			config = { bar_provider = "grok", claude_accounts = { "Work=~/.claude-w" } },
			fs = { ["~/.claude-w/.credentials.json"] = h.CLAUDE_CRED },
		})
		s.env.noctalia.state.set("cmd.cycle", 1)
		s.env.noctalia.state.set("cmd.cycle", 2)
		assert.equal(h.view(s).barKey, "claude:work")
		mock.setConfig(s.env, "claude_accounts", {})
		s.call("onConfigChanged")
		assert.equal(h.view(s).barKey, "grok")
		assert.equal(mock.json.decode(s.env.noctalia.readFile("/mock/plugin-data/selection.json")).key, "grok")
	end)
```

**Step 2: Run to verify it fails**
Run: `./run-tests tests/service-events.test.luau`
Expected: `FAIL falls back ...` (barKey `claude`, expected `grok`).

**Step 3: Implement** — replace the `else` branch of `onConfigChanged`:

```lua
	else
		-- A source that vanished (removed account) falls back like at boot.
		local resolved = view.initialKey(sources, barKey, setting)
		if resolved ~= barKey then
			barKey = resolved
			persistSelection()
		end
	end
```

**Step 4: Run to verify it passes**
Run: `./run-tests tests/service-events.test.luau` then `./run-tests`
Expected: all green.

**Step 5: Commit**
Run: `/git commit`

---

### Task 5: Accept `claude:<account name>` in `bar_provider`

**Requirement:** REQ-003, REQ-014 (review finding: the docs say `claude:<name>` but the key is
`claude:<slug>`)
**Files:**
- Modify: `lib/accounts.luau` (new `normalizeKey`), `lib/view.luau` (`initialKey`),
  `service.luau` (`onConfigChanged` changed-setting branch), `README.md:47`,
  `translations/en.json`, `translations/pt-BR.json` (`settings.bar_provider.description`)
- Test: `tests/accounts.test.luau`, `tests/view.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: test-driven-development)
- Reviewers: business-logic-reviewer, test-reviewer

**Why:** `bar_provider = "claude:Trabalho Pessoal"` never matches `claude:trabalho-pessoal`,
so it silently falls to `claude` and overwrites the middle-click choice. Normalizing the
setting makes the documented form work.

**Step 1: Write the failing tests**

`tests/accounts.test.luau`:
```lua
describe("accounts.normalizeKey", function()
	it("slugs the account name after claude: and lowercases the rest", function()
		assert.equal(accounts.normalizeKey("claude:Trabalho Pessoal"), "claude:trabalho-pessoal")
		assert.equal(accounts.normalizeKey(" Claude:work "), "claude:work")
		assert.equal(accounts.normalizeKey("GROK"), "grok")
		assert.equal(accounts.normalizeKey("claude"), "claude")
		assert.equal(accounts.normalizeKey(nil), "")
	end)
end)
```

`tests/view.test.luau` (in `describe("view.initialKey", ...)`):
```lua
	it("matches the setting by account name", function()
		assert.equal(view.initialKey(SOURCES, nil, "claude:Frozen"), "claude:frozen")
		assert.equal(view.initialKey(SOURCES, nil, " Grok "), "grok")
	end)
```

**Step 2: Run to verify they fail**
Run: `./run-tests tests/accounts.test.luau tests/view.test.luau`
Expected: `attempt to call a nil value` (`normalizeKey`) and `FAIL matches the setting ...`.

**Step 3: Implement**

`lib/accounts.luau`, after `slug`:
```lua
-- A bar_provider value -> source key: "claude:Trabalho Pessoal" -> "claude:trabalho-pessoal".
function Accounts.normalizeKey(value: any): string
	if typeof(value) ~= "string" then
		return ""
	end
	local text = string.lower(trim(value))
	if string.sub(text, 1, 7) == "claude:" then
		return "claude:" .. slug(string.sub(text, 8))
	end
	return text
end
```

`lib/view.luau`, in `initialKey`, resolve the setting through it:
```lua
	return accounts.resolveKey(sources, accounts.normalizeKey(setting))
```

`service.luau`, `onConfigChanged`, changed-setting branch: replace
`barKey = accounts.resolveKey(sources, setting)` with
`barKey = view.initialKey(sources, nil, setting)`.

Docs, same meaning in each:
- `README.md:47`: "`claude`, `grok`, or `claude:<account name>` (as in Frozen Claude
  accounts; case and spaces do not matter)".
- `translations/en.json`: "Source the bar shows: claude, grok or claude:<account name>.
  Middle click on the widget cycles through the sources; changing this setting overrides that
  choice."
- `translations/pt-BR.json`: "Fonte exibida na barra: claude, grok ou claude:<nome da conta>.
  O clique do meio no widget alterna entre as fontes; mudar esta opção substitui essa
  escolha."

**Step 4: Run to verify they pass**
Run: `./run-tests tests/accounts.test.luau tests/view.test.luau` then `./run-tests`
Expected: all green (the translations test checks both files keep the same keys).

**Step 5: Commit**
Run: `/git commit`

---

### Task 6: Settings changes poll only new sources and reset moved accounts

**Requirement:** REQ-006, REQ-008 (review findings: every settings change polls every
provider; a frozen account whose dir changed keeps the old account's id and email)
**Depends on:** Task 4
**Files:**
- Modify: `service.luau` (`configure`, `onConfigChanged`, `start`)
- Test: `tests/service-events.test.luau`

**Team:**
- Track: backend (credentials)
- Implementer: backend-engineer (skills: test-driven-development, security-guardrails)
- Reviewers: security-reviewer, business-logic-reviewer, test-reviewer

**Why:** adjusting `notify_threshold` or `poll_minutes` fires a GET to every account and Grok
(429 risk on Claude). And `Work=~/.claude-a` → `Work=~/.claude-b` keeps the key
`claude:work` with A's identity, so B's usage is cached under A's id.

**Step 1: Write the failing tests** (new `describe` in `tests/service-events.test.luau`)

```lua
describe("service settings changes", function()
	local function answered()
		local s = h.boot({
			config = { claude_accounts = { "Work=~/.claude-a" } },
			fs = {
				["~/.claude-a/.credentials.json"] = '{"claudeAiOauth":{"accessToken":"SECRET-A","expiresAt":1891662400000}}',
				["~/.claude-a/.claude.json"] = '{"oauthAccount":{"accountUuid":"u7","emailAddress":"w@x.dev"}}',
				["~/.claude-b/.credentials.json"] = '{"claudeAiOauth":{"accessToken":"SECRET-B","expiresAt":1891662400000}}',
				["~/.claude-n/.credentials.json"] = '{"claudeAiOauth":{"accessToken":"SECRET-N","expiresAt":1891662400000}}',
			},
		})
		for i = 1, #mock.pendingHttp(s.env) do
			mock.respond(s.env, i, { ok = true, status = 500, body = "" })
		end
		return s
	end

	it("does not poll when an unrelated setting changes", function()
		local s = answered()
		local before = #mock.pendingHttp(s.env)
		mock.setConfig(s.env, "notify_threshold", 50)
		s.call("onConfigChanged")
		assert.equal(#mock.pendingHttp(s.env), before)
	end)

	it("polls only an added account", function()
		local s = answered()
		local before = #mock.pendingHttp(s.env)
		mock.setConfig(s.env, "claude_accounts", { "Work=~/.claude-a", "New=~/.claude-n" })
		s.call("onConfigChanged")
		local calls = mock.pendingHttp(s.env)
		assert.equal(#calls, before + 1)
		local found = false
		for _, line in calls[#calls].request.headers do
			if line == "Authorization: Bearer SECRET-N" then
				found = true
			end
		end
		assert.equal(found, true)
	end)

	it("resets an account whose dir changed", function()
		local s = answered()
		assert.equal(h.sourceOf(s, "claude:work").email, "w@x.dev")
		mock.setConfig(s.env, "claude_accounts", { "Work=~/.claude-b" })
		s.call("onConfigChanged")
		local work = h.sourceOf(s, "claude:work")
		assert.equal(work.email, "")
		assert.equal(work.error, "")
		local calls = mock.pendingHttp(s.env)
		local found = false
		for _, line in calls[#calls].request.headers do
			if line == "Authorization: Bearer SECRET-B" then
				found = true
			end
		end
		assert.equal(found, true)
	end)
end)
```

**Step 2: Run to verify they fail**
Run: `./run-tests tests/service-events.test.luau`
Expected: `FAIL does not poll ...`, `FAIL polls only an added account` (3 new requests, not
1), `FAIL resets an account ...` (email still `w@x.dev`).

**Step 3: Implement** in `service.luau`

`configure` remembers each key's dir, resets a key whose dir moved, and returns the sources
that are new (or reset) so the caller can poll just those:

```lua
-- Rebuilds the sources from settings. A key whose dir changed is a different
-- account: its identity, state and pending answers are dropped. Returns the
-- sources without a state before this call (new or reset).
local function configure(): { any }
	local previous = {}
	for _, s in sources do
		previous[s.key] = s.dir
	end
	sources = accounts.sources(accounts.parseAccounts(noctalia.getConfig("claude_accounts")))
	local fresh = {}
	for _, s in sources do
		if previous[s.key] ~= nil and previous[s.key] ~= s.dir then
			identities[s.key] = nil
			states[s.key] = nil
			pending[s.key] = nil
			generation[s.key] = (generation[s.key] or 0) + 1
		end
		changed(accounts.credPath(s))
		if s.provider == "claude" then
			changed(accounts.configPath(s))
			syncIdentity(s)
		end
		if states[s.key] == nil then
			states[s.key] = poll.restore(poll.createState(), accounts.cachedSnapshot(cache, s.key, uuidOf(s.key)))
			table.insert(fresh, s)
		end
	end
	return fresh
end
```

`start` ignores the return value (it still calls `pollAll()`). In `onConfigChanged`, replace
the leading `configure()` with `local fresh = configure()` and the trailing `pollAll()` with:

```lua
	for _, s in fresh do
		pollSource(s)
	end
	publish()
```

`syncIdentity` for a reset key sees `uuidOf(key) == ""`, so a readable `.claude.json`
adopts; a missing one leaves the email empty, as the test expects. If `syncIdentity`'s adopt
branch dereferences `info` when it is `nil`, guard it (`accountChange` returns `"none"` for a
missing id, so this should not happen; keep the guard local and tested by this task).

**Step 4: Run to verify they pass**
Run: `./run-tests tests/service-events.test.luau` then `./run-tests`
Expected: all green, including `lets a changed bar_provider setting override the choice`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 7: One i18n adapter and one counter helper

**Requirement:** REQ-018 (review finding: `tr` wrapper copied in three entries, counter bump
in two)
**Files:**
- Modify: `lib/present.luau` (new `translator`, `bump`), `service.luau:44-49`,
  `widget.luau` (`tr`, `onMiddleClick`), `panel.luau` (`tr`, `onRefresh`)
- Test: `tests/present.test.luau`

**Team:**
- Track: frontend
- Implementer: rpi-implementer (skills: test-driven-development)
- Reviewers: test-reviewer

**Step 1: Write the failing test** (append to `tests/present.test.luau`)

```lua
describe("present helpers", function()
	it("wraps a host translator, passing vars only when given", function()
		local seen = {}
		local t = present.translator(function(...)
			seen = { ... }
			return "x"
		end)
		assert.equal(t("a.b"), "x")
		assert.equal(#seen, 1)
		t("a.b", { n = 1 })
		assert.equal(#seen, 2)
	end)

	it("bumps a command counter from any stored value", function()
		assert.equal(present.bump(nil), 1)
		assert.equal(present.bump(4), 5)
		assert.equal(present.bump("2"), 3)
	end)
end)
```

**Step 2: Run to verify it fails**
Run: `./run-tests tests/present.test.luau`
Expected: `attempt to call a nil value` (`translator`).

**Step 3: Implement**

`lib/present.luau`:
```lua
-- The entries' tr(key, vars?) over the host's noctalia.tr, which must not get a
-- nil vars argument.
function Present.translator(hostTr: any): (string, any?) -> string
	return function(key: string, vars: any?): string
		if vars then
			return hostTr(key, vars)
		end
		return hostTr(key)
	end
end

-- Next value of a cmd.* counter on noctalia.state.
function Present.bump(value: any): number
	return (tonumber(value) or 0) + 1
end
```

In `service.luau`, `widget.luau` and `panel.luau`, replace the local `tr` function with
`local tr = present.translator(noctalia.tr)` (`service.luau` already requires `present`).
`widget.luau` `onMiddleClick`:
`noctalia.state.set("cmd.cycle", present.bump(noctalia.state.get("cmd.cycle")))`;
`panel.luau` `onRefresh` likewise with `cmd.refresh`.

**Step 4: Run to verify it passes**
Run: `./run-tests tests/present.test.luau` then `./run-tests` then `noctalia plugins lint .`
Expected: all green; lint `0 errors`.

**Step 5: Commit**
Run: `/git commit`

---

## Traceability

| Review finding | Task |
|----------------|------|
| `service.luau:215` float mtime equality | T1 |
| `service.luau:277` change consumed while blocked | T2 |
| `service.luau:274` swap between two writes | T2 |
| `service.luau:185` adopt drops in-flight answer | T3 |
| `service.luau:306` vanished source falls to `claude` | T4 |
| `README.md:47` `claude:<name>` vs slug | T5 |
| `service.luau:308` every settings change polls all | T6 |
| `service.luau:250` moved dir keeps old identity | T6 |
| `widget.luau:10` duplicated `tr` and counter | T7 |
| `service.luau:274` large `.claude.json` re-decoded | Out of scope |
