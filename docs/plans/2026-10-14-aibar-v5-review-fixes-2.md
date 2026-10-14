# Plan: aibar-v5-review-fixes-2

**Spec:** `docs/specs/aibar-v5/SPEC.md` · **Depth:** Standard · **Tasks:** 6 · **Date:** 2026-10-14
**Depends on:** `docs/plans/2026-10-14-aibar-v5-review-fixes.md` (done, `5f5bf11`). Run before
Task 20 (manual smoke) of `docs/plans/2026-10-14-aibar-v5.md`.
**Source:** second `/code-review` (high) of `6ecc8e0..5f5bf11`. Not reproduced; every task
starts with a test that reproduces its finding.

The first fix round left per-source state spread over `states`, `identities`, `pending`,
`generation` and `mtimes`, changed from several places. This round gives it two rules and
uses them everywhere:

1. **One deferral rule.** A source marked `pending` on tick `t` is never polled on tick `t`,
   by anyone (`update`, `pollAll`, `refresh`, settings changes). It is polled on the first
   later tick where `poll.canRequest` allows it, once.
2. **One reset.** `resetSource(key)` drops identity, state, pending mark and in-flight answers
   of a key. It runs when an account's dir changes and when an account is removed.

Settings changes poll only what changed: new or reset sources, Claude sources when the
User-Agent changed, and they re-schedule the periodic poll from the new `poll_minutes`.

## Global rules for every task

- TDD: write the Luau test, run it and see it fail for the stated reason, implement, run it
  green, then the full suite `./run-tests` (read `N passed, M failed` and the `claude-swap:`
  line) and `noctalia plugins lint .`.
- Single file: `./run-tests tests/<name>.test.luau`.
- Service tests use `tests/support/service_helpers.luau` (`h.boot`, `h.requests`, `h.view`,
  `h.sourceOf`, `h.NOW`, `h.CLAUDE_URL`, `h.GROK_URL`, `h.CLAUDE_CRED`, `h.CLAUDE_JSON`,
  `h.CLAUDE_BODY`, `h.GROK_BODY`) and the mock (`mock.respond`, `mock.setFile`,
  `mock.setConfig`, `mock.setNow`, `mock.pendingHttp`, `mock.calls`, `mock.json`). Files
  seeded through `h.boot` start with `mtime = 1`.
- `lib/*.luau` stays pure. Tokens only in `noctalia.http` headers (the secrecy test stays
  green). No `/home/<user>` paths. English code, comments and docs.
- No git commands inside tasks except the per-task `/git commit`.

## Batches

| Batch | Tasks | Notes |
|-------|-------|-------|
| 1 | T1, T2, T6 | independent, small |
| 2 | T3 | deferral rule in `update`/`pollSource` |
| 3 | T4 | `resetSource` and `configure`, after T3 |
| 4 | T5 | `onConfigChanged` scheduling, after T4 |

---

### Task 1: Round the mtime to the nearest millisecond

**Requirement:** REQ-008 (finding `service.luau:220`)
**Files:**
- Modify: `service.luau:215-221` (`fingerprint`)
- Test: `tests/service-events.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: test-driven-development)
- Reviewers: business-logic-reviewer, test-reviewer

**Why:** `math.floor(mtime * 1000)` turns a downward wobble at a whole second
(`1.0` read as `0.9999999`) into a 1 ms change and a spurious poll. Files copied with
`cp -p`/`tar` or on coarse filesystems sit on whole seconds.

**Step 1: Write the failing test** (in `describe("service file fingerprints", ...)`)

```lua
	it("ignores a downward wobble at a whole second", function()
		local s = h.boot()
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 200, body = h.CLAUDE_BODY })
		mock.setFile(s.env, "~/.claude/.credentials.json", h.CLAUDE_CRED, 1 - 1e-7)
		s.call("update")
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 1)
	end)
```

**Step 2: Run to verify it fails**
Run: `./run-tests tests/service-events.test.luau`
Expected: `FAIL ignores a downward wobble ...` (2 requests, expected 1).

**Step 3: Implement** — in `fingerprint`:

```lua
	return math.floor((tonumber(info.mtime) or 0) * 1000 + 0.5) .. ":" .. (tonumber(info.size) or 0)
```

**Step 4: Run to verify it passes**
Run: `./run-tests tests/service-events.test.luau` then `./run-tests`
Expected: all green (the upward-jitter test still passes).

**Step 5: Commit**
Run: `/git commit`

---

### Task 2: `normalizeKey` caps the name like `parseAccounts`

**Requirement:** REQ-014 (finding `lib/accounts.luau:28`)
**Files:**
- Modify: `lib/accounts.luau` (new local `capName`, used by `parseAccounts` and `normalizeKey`)
- Test: `tests/accounts.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: test-driven-development)
- Reviewers: business-logic-reviewer, test-reviewer

**Why:** `parseAccounts` cuts names at 24 characters before slugging, `normalizeKey` does not,
so `bar_provider = "claude:<full long name>"` never matches its account.

**Step 1: Write the failing test** (in `describe("accounts.normalizeKey", ...)`)

```lua
	it("caps the account name like parseAccounts", function()
		local key = accounts.parseAccounts({ "Conta Trabalho Principal X=~/.claude-t" })[1].key
		assert.equal(key, "claude:conta-trabalho-principal")
		assert.equal(accounts.normalizeKey("claude:Conta Trabalho Principal X"), key)
	end)
```

**Step 2: Run to verify it fails**
Run: `./run-tests tests/accounts.test.luau`
Expected: `FAIL caps the account name ...` (got `claude:conta-trabalho-principal-x`).

**Step 3: Implement** in `lib/accounts.luau`, after `slug`:

```lua
-- Account names are cut at MAX_NAME characters (UTF-8 aware) and trimmed.
local function capName(name: string): string
	local cut = utf8.offset(name, Accounts.MAX_NAME + 1)
	if cut then
		name = string.sub(name, 1, cut - 1)
	end
	return trim(name)
end
```

`parseAccounts`: replace its inline `utf8.offset` cut with
`local name = capName(trim(string.sub(entry, 1, eq - 1)))`.

`normalizeKey`: slug the capped original-case rest:

```lua
	local text = trim(value)
	if string.lower(string.sub(text, 1, 7)) == "claude:" then
		return "claude:" .. slug(capName(trim(string.sub(text, 8))))
	end
	return string.lower(text)
```

`capName` must be defined above `normalizeKey` (move `normalizeKey` below it if needed).

**Step 4: Run to verify it passes**
Run: `./run-tests tests/accounts.test.luau tests/view.test.luau` then `./run-tests`
Expected: all green, existing `normalizeKey` cases included.

**Step 5: Commit**
Run: `/git commit`

---

### Task 3: One deferral rule for pending sources

**Requirement:** REQ-008 (findings `service.luau:317` swap polled by `pollAll`/`refresh`,
`service.luau:312` duplicate poll after `pollAll`)
**Files:**
- Modify: `service.luau` (`pollSource`, `update`), `tests/support/service_helpers.luau`
  (new `h.header`)
- Test: `tests/service-events.test.luau`

**Team:**
- Track: backend (credentials)
- Implementer: backend-engineer (skills: test-driven-development, security-guardrails)
- Reviewers: security-reviewer, business-logic-reviewer, test-reviewer

**Why:** the one-tick wait after a swap only lives in `update`'s pending loop. `pollAll` (when
the swap lands on the scheduled tick) and `refresh` (`cmd.refresh`, IPC) call `pollSource`
right away with the old `.credentials.json` under the new account id, which writes account A's
usage into `cache.byAccount[B]`. And a credential change marked on the `pollAll` tick is
polled by `pollAll` and again on the next tick.

**Step 1: Write the failing tests**

`tests/support/service_helpers.luau`, add:

```lua
-- The header line of http call #index that starts with prefix, or nil.
function H.header(loaded, index, prefix)
	for _, line in mock.pendingHttp(loaded.env)[index].request.headers do
		if string.sub(line, 1, #prefix) == prefix then
			return line
		end
	end
	return nil
end
```

New `describe` in `tests/service-events.test.luau`:

```lua
describe("service deferral", function()
	local B_JSON = '{"oauthAccount":{"accountUuid":"u2","emailAddress":"b@x.dev"}}'
	local B_CRED = '{"claudeAiOauth":{"accessToken":"SECRET-B","expiresAt":1891662400000}}'

	local function answered()
		local s = h.boot()
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 200, body = h.CLAUDE_BODY })
		mock.respond(s.env, h.requests(s, h.GROK_URL)[1], { ok = true, status = 200, body = h.GROK_BODY })
		return s
	end

	it("does not poll a swapped account on the scheduled poll tick", function()
		local s = answered()
		mock.setNow(s.env, h.NOW + 5 * 60000)
		mock.setFile(s.env, "~/.claude.json", B_JSON, 2)
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 1)
		assert.equal(#h.requests(s, h.GROK_URL), 2)
		mock.setFile(s.env, "~/.claude/.credentials.json", B_CRED, 2)
		s.call("update")
		s.call("update")
		local c = h.requests(s, h.CLAUDE_URL)
		assert.equal(#c, 2)
		assert.equal(h.header(s, c[2], "Authorization:"), "Authorization: Bearer SECRET-B")
	end)

	it("does not poll a swapped account from a refresh on the same tick", function()
		local s = answered()
		mock.setFile(s.env, "~/.claude.json", B_JSON, 2)
		s.env.noctalia.state.set("cmd.refresh", 1)
		assert.equal(#h.requests(s, h.CLAUDE_URL), 1)
		mock.setFile(s.env, "~/.claude/.credentials.json", B_CRED, 2)
		s.call("update")
		local c = h.requests(s, h.CLAUDE_URL)
		assert.equal(#c, 2)
		assert.equal(h.header(s, c[2], "Authorization:"), "Authorization: Bearer SECRET-B")
	end)

	it("polls a credential change once when it lands on the scheduled poll tick", function()
		local s = answered()
		mock.setNow(s.env, h.NOW + 5 * 60000)
		mock.setFile(s.env, "~/.claude/.credentials.json", B_CRED, 2)
		-- Answer every new request right away, so a duplicate is not hidden by inFlight.
		local done = 1
		local function step()
			s.call("update")
			local c = h.requests(s, h.CLAUDE_URL)
			for i = done + 1, #c do
				mock.respond(s.env, c[i], { ok = true, status = 200, body = h.CLAUDE_BODY })
			end
			done = #c
		end
		step()
		step()
		step()
		assert.equal(#h.requests(s, h.CLAUDE_URL), 2)
	end)
end)
```

**Step 2: Run to verify they fail**
Run: `./run-tests tests/service-events.test.luau`
Expected: `FAIL does not poll a swapped account on the scheduled poll tick` (claude polled by
`pollAll`, 2 requests after the first update), `FAIL ... from a refresh ...` (2 after the
refresh), `FAIL polls a credential change once ...` (3 requests).

**Step 3: Implement** in `service.luau`

`pollSource`, first lines:

```lua
local function pollSource(source: any): boolean
	local key = source.key
	-- Marked this tick (file change or swap): wait for a later tick, whoever asks.
	if pending[key] == tick then
		return false
	end
	...
```

`update`: mark credential changes **before** serving pending marks, so a change already
marked on an earlier tick is served once and never re-marked:

```lua
function update()
	tick += 1
	for _, s in sources do
		if s.provider == "claude" and changed(accounts.configPath(s)) then
			syncIdentity(s)
		end
	end
	for _, s in sources do
		if changed(accounts.credPath(s)) and pending[s.key] == nil then
			pending[s.key] = tick
		end
	end
	for _, s in sources do
		local mark = pending[s.key]
		if mark ~= nil and mark < tick and pollSource(s) then
			pending[s.key] = nil
		end
	end
	if now() >= nextPollAt then
		pollAll()
	else
		publish()
	end
end
```

Update the comment on `pending` to state the rule: "key -> tick when a file change or swap
asked for a poll. Never polled on that tick by anyone; served once on a later tick."

**Step 4: Run to verify they pass**
Run: `./run-tests tests/service-events.test.luau` then `./run-tests`
Expected: all green, including the earlier deferral tests (`keeps a credential change ...`,
`polls a swapped account only with its own token`, `re-polls a source whose credentials
changed`).

**Step 5: Commit**
Run: `/git commit`

---

### Task 4: `resetSource` for moved and removed accounts; settings never swallow file changes

**Requirement:** REQ-008 (findings `service.luau:275` cached account not polled,
`service.luau:264` removed account keeps state, `service.luau:230` `configure` consumes a
credential change)
**Depends on:** Task 3
**Files:**
- Modify: `service.luau` (new `resetSource`, `watch`; `configure`)
- Test: `tests/service-events.test.luau`

**Team:**
- Track: backend (credentials)
- Implementer: backend-engineer (skills: test-driven-development, security-guardrails)
- Reviewers: security-reviewer, business-logic-reviewer, test-reviewer

**Why:**
- `fresh` is decided after `syncIdentity`, whose "adopt" path restores a cached snapshot and
  fills `states[key]`; an added (or moved) account with a cached id is then never polled.
- A removed account keeps identity, state, pending mark and generation: re-adding the key
  later inherits the old uuid and email, and an answer still in flight for the removed
  account notifies and writes its snapshot.
- `configure` calls `changed()` on every path at every settings change, recording a
  credential rewrite that `update` has not seen yet, so it is never polled.

**Step 1: Write the failing tests** (in `describe("service settings changes", ...)`)

```lua
	it("polls an added account whose id is already cached", function()
		local cached = '{"byAccount":{"u7":{"provider":"claude","plan":"","windows":[{"id":"weekly","percent":20,"startMs":1791597600082,"endMs":1792202400082}],"products":[],"fetchedAt":1}}}'
		local s = h.boot({ fs = {
			["/mock/plugin-data/snapshots.json"] = cached,
			["~/.claude-w/.credentials.json"] = '{"claudeAiOauth":{"accessToken":"SECRET-W","expiresAt":1891662400000}}',
			["~/.claude-w/.claude.json"] = '{"oauthAccount":{"accountUuid":"u7","emailAddress":"w@x.dev"}}',
		} })
		local before = #h.requests(s, h.CLAUDE_URL)
		mock.setConfig(s.env, "claude_accounts", { "Work=~/.claude-w" })
		s.call("onConfigChanged")
		local c = h.requests(s, h.CLAUDE_URL)
		assert.equal(#c, before + 1)
		assert.equal(h.header(s, c[#c], "Authorization:"), "Authorization: Bearer SECRET-W")
		assert.equal(h.sourceOf(s, "claude:work").snapshot.windows[1].percent, 20)
	end)

	it("forgets a removed account, including its answer in flight", function()
		local s = h.boot({
			config = { notify_threshold = 10, claude_accounts = { "Work=~/.claude-a" } },
			fs = {
				["~/.claude-a/.credentials.json"] = '{"claudeAiOauth":{"accessToken":"SECRET-A","expiresAt":1891662400000}}',
				["~/.claude-a/.claude.json"] = '{"oauthAccount":{"accountUuid":"u7","emailAddress":"w@x.dev"}}',
				["~/.claude-b/.credentials.json"] = '{"claudeAiOauth":{"accessToken":"SECRET-B","expiresAt":1891662400000}}',
			},
		})
		local workRequest = nil
		for _, i in h.requests(s, h.CLAUDE_URL) do
			if h.header(s, i, "Authorization:") == "Authorization: Bearer SECRET-A" then
				workRequest = i
			end
		end
		mock.setConfig(s.env, "claude_accounts", {})
		s.call("onConfigChanged")
		mock.respond(s.env, workRequest, { ok = true, status = 200, body = h.CLAUDE_BODY })
		assert.equal(#mock.calls(s.env, "noctalia.notify"), 0)
		assert.equal(s.env.noctalia.readFile("/mock/plugin-data/snapshots.json"), nil)
		mock.setConfig(s.env, "claude_accounts", { "Work=~/.claude-b" })
		s.call("onConfigChanged")
		local work = h.sourceOf(s, "claude:work")
		assert.equal(work.email, "")
		assert.equal(work.snapshot, nil)
		local c = h.requests(s, h.CLAUDE_URL)
		assert.equal(h.header(s, c[#c], "Authorization:"), "Authorization: Bearer SECRET-B")
	end)

	it("does not swallow a credential change seen first by a settings change", function()
		local s = answered()
		local before = #h.requests(s, h.CLAUDE_URL)
		mock.setFile(s.env, "~/.claude/.credentials.json", h.CLAUDE_CRED .. " ", 2)
		mock.setConfig(s.env, "notify_threshold", 50)
		s.call("onConfigChanged")
		s.call("update")
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), before + 1)
	end)
```

**Step 2: Run to verify they fail**
Run: `./run-tests tests/service-events.test.luau`
Expected: `FAIL polls an added account ...` (no new request), `FAIL forgets a removed
account ...` (a notify fires and `snapshots.json` is written), `FAIL does not swallow ...`
(no new request).

**Step 3: Implement** in `service.luau`

Above `configure`:

```lua
-- Forget everything about a key: identity, state, pending mark, and any answer
-- still in flight (its generation no longer matches).
local function resetSource(key: string)
	identities[key] = nil
	states[key] = nil
	pending[key] = nil
	generation[key] = (generation[key] or 0) + 1
end

-- Start watching a path without consuming a change update() has not seen.
local function watch(path: string)
	if mtimes[path] == nil then
		changed(path)
	end
end
```

`configure`:

```lua
-- Rebuilds the sources from settings. A key whose dir changed, or that was
-- removed, is reset. Returns the sources that had no state before this call
-- (new or reset); they need a poll even when a cached snapshot was restored.
local function configure(): { any }
	local previous = {}
	for _, s in sources do
		previous[s.key] = s.dir
	end
	sources = accounts.sources(accounts.parseAccounts(noctalia.getConfig("claude_accounts")))
	local kept = {}
	local fresh = {}
	for _, s in sources do
		kept[s.key] = true
		if previous[s.key] ~= nil and previous[s.key] ~= s.dir then
			resetSource(s.key)
		end
		local isFresh = states[s.key] == nil
		watch(accounts.credPath(s))
		if s.provider == "claude" then
			watch(accounts.configPath(s))
			syncIdentity(s)
		end
		if states[s.key] == nil then
			states[s.key] = poll.restore(poll.createState(), accounts.cachedSnapshot(cache, s.key, uuidOf(s.key)))
		end
		if isFresh then
			table.insert(fresh, s)
		end
	end
	for key in previous do
		if not kept[key] then
			resetSource(key)
		end
	end
	return fresh
end
```

`syncIdentity` reads `.claude.json` itself, so `watch` (instead of `changed`) on the config
path does not change which account is adopted; `update` still reacts to a later rewrite.

**Step 4: Run to verify they pass**
Run: `./run-tests tests/service-events.test.luau` then `./run-tests`
Expected: all green, including `polls only an added account` and `resets an account whose
dir changed`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 5: Settings changes re-schedule the poll and retry Claude on a new User-Agent

**Requirement:** REQ-006 (findings `service.luau:349` `poll_minutes` not applied,
`claude_user_agent` change does nothing)
**Depends on:** Task 4
**Files:**
- Modify: `service.luau` (new `lastPollAt`, `lastUserAgent`, `interval`; `pollAll`, `start`,
  `onConfigChanged`)
- Test: `tests/service-events.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: test-driven-development)
- Reviewers: business-logic-reviewer, test-reviewer

**Why:** since the first fix round `onConfigChanged` no longer calls `pollAll`, so
`nextPollAt` keeps the old interval (60 → 2 min still waits up to 60 min), and fixing a bad
User-Agent (which causes 429s) does not retry until the next interval.

**Step 1: Write the failing tests** (in `describe("service settings changes", ...)`)

```lua
	it("applies a shorter poll interval from the last poll", function()
		local s = h.boot({ config = { poll_minutes = 60 } })
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 200, body = h.CLAUDE_BODY })
		mock.setNow(s.env, h.NOW + 3 * 60000)
		mock.setConfig(s.env, "poll_minutes", 2)
		s.call("onConfigChanged")
		s.call("update")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 2)
	end)

	it("retries Claude, not Grok, when the User-Agent changes", function()
		local s = answered()
		local claudeBefore = #h.requests(s, h.CLAUDE_URL)
		local grokBefore = #h.requests(s, h.GROK_URL)
		mock.setConfig(s.env, "claude_user_agent", "claude-cli/9.9.10 (external, cli)")
		s.call("onConfigChanged")
		local c = h.requests(s, h.CLAUDE_URL)
		assert.equal(#c > claudeBefore, true)
		assert.equal(h.header(s, c[#c], "User-Agent:"), "User-Agent: claude-cli/9.9.10 (external, cli)")
		assert.equal(#h.requests(s, h.GROK_URL), grokBefore)
	end)

	it("still honors a 429 backoff when the User-Agent changes", function()
		local s = h.boot()
		mock.respond(s.env, h.requests(s, h.CLAUDE_URL)[1], { ok = true, status = 429, body = "" })
		mock.setConfig(s.env, "claude_user_agent", "claude-cli/9.9.10 (external, cli)")
		s.call("onConfigChanged")
		assert.equal(#h.requests(s, h.CLAUDE_URL), 1)
	end)
```

(`answered()` is the helper already defined at the top of this `describe`; its sources include
`claude:work`, so "more than before" covers both Claude sources.)

**Step 2: Run to verify they fail**
Run: `./run-tests tests/service-events.test.luau`
Expected: `FAIL applies a shorter poll interval ...` (1 request) and `FAIL retries Claude ...`
(no new Claude request). The backoff test passes already; keep it as a guard.

**Step 3: Implement** in `service.luau`

Locals next to `nextPollAt`:

```lua
local lastPollAt = 0
local lastUserAgent = ""
```

Helpers and `pollAll`:

```lua
local function interval(): number
	return math.max(2, tonumber(noctalia.getConfig("poll_minutes")) or 5) * 60000
end

local function pollAll()
	lastPollAt = now()
	nextPollAt = lastPollAt + interval()
	for _, s in sources do
		pollSource(s)
	end
	publish()
end
```

`start`: set `lastUserAgent = tostring(noctalia.getConfig("claude_user_agent") or "")` before
`pollAll()`.

`onConfigChanged`, replace the trailing poll loop and `publish()`:

```lua
	for _, s in fresh do
		pollSource(s)
	end
	-- A new User-Agent may cure a 429 storm: retry Claude (backoff still applies).
	local userAgent = tostring(noctalia.getConfig("claude_user_agent") or "")
	if userAgent ~= lastUserAgent then
		lastUserAgent = userAgent
		for _, s in sources do
			if s.provider == "claude" then
				pollSource(s)
			end
		end
	end
	-- poll_minutes may have changed: count the new interval from the last poll.
	nextPollAt = lastPollAt + interval()
	publish()
```

A source just polled from `fresh` is in flight, so the User-Agent loop's `pollSource` returns
early for it (`poll.canRequest`), and a pending source waits for its tick (Task 3).

**Step 4: Run to verify they pass**
Run: `./run-tests tests/service-events.test.luau` then `./run-tests`
Expected: all green, including `does not poll when an unrelated setting changes`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 6: Look up `noctalia.tr` on every call

**Requirement:** REQ-018 (finding `widget.luau:9`, low severity)
**Files:**
- Modify: `widget.luau:9`, `panel.luau:10`, `service.luau:47`
- Test: `tests/widget.test.luau`

**Team:**
- Track: frontend
- Implementer: rpi-implementer (skills: test-driven-development)
- Reviewers: test-reviewer

**Why:** `present.translator(noctalia.tr)` binds the function at load; the old wrappers looked
`noctalia.tr` up per call. Keep the per-call lookup so a host that swaps the function (or a
test) is honored.

**Step 1: Write the failing test** (in `tests/widget.test.luau`)

```lua
	it("uses the current noctalia.tr on every render", function()
		local w = entry.load("widget.luau", {})
		w.env.noctalia.tr = function(key)
			return "T:" .. key
		end
		w.env.noctalia.state.set("view", VIEW)
		local tips = mock.calls(w.env, "barWidget.setTooltip")
		assert.equal(tips[#tips][1][1][1], "T:window.session")
	end)
```

**Step 2: Run to verify it fails**
Run: `./run-tests tests/widget.test.luau`
Expected: `FAIL uses the current noctalia.tr ...` (got `window.session`).

**Step 3: Implement** — in each of the three entries:

```lua
local tr = present.translator(function(...)
	return noctalia.tr(...)
end)
```

**Step 4: Run to verify it passes**
Run: `./run-tests tests/widget.test.luau` then `./run-tests` then `noctalia plugins lint .`
Expected: all green; lint `0 errors`.

**Step 5: Commit**
Run: `/git commit`

---

## Traceability

| Review finding | Task |
|----------------|------|
| `service.luau:220` floor at whole seconds | T1 |
| `lib/accounts.luau:28` `normalizeKey` without the 24-char cap | T2 |
| `service.luau:317` swap polled by `pollAll` / `refresh` | T3 |
| `service.luau:312` duplicate poll after `pollAll` | T3 |
| `service.luau:275` added account with cached id not polled | T4 |
| `service.luau:264` removed account keeps state | T4 |
| `service.luau:230` `configure` swallows a credential change | T4 |
| `service.luau:349` `poll_minutes` change not applied | T5 |
| `service.luau:349` `claude_user_agent` change does nothing | T5 |
| `widget.luau:9` translator bound at load | T6 |
