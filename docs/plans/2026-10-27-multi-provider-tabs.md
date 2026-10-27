# Plan: Codex, Antigravity and Cursor usage with provider tabs

> **Spec:** docs/specs/multi-provider-tabs/SPEC.md

**Goal:** Add Codex, Antigravity (`agy`) and Cursor plan usage to aibar and split the panel into one tab per provider (`Claude // Grok // Codex // Agy // Cursor`).
**Architecture:** Each new provider gets a pure parser in `lib/` (`codex`, `cursor`, `agy`) that turns its answer into the existing snapshot shape (`windows`, `products`, `plan`). `service.luau` dispatches polling through a `pollers` table: Codex is a GET like Claude, Cursor reads its token with `sqlite3` through `noctalia.runAsync` and then POSTs a Connect RPC, Agy runs `agy -p "/quota" --output-format json` and never touches a token. `lib/present.luau` builds a provider-tab model and `panel.luau` renders one provider at a time, Claude accounts staying as sub-tabs.
**Tech Stack:** Luau (Noctalia v5 plugin API 22), `./run-tests` (luau CLI + mock host), `noctalia plugins lint`.
**Total Tasks:** 18
**Estimated Complexity:** large

**Precondition (owner, before `/rpi-implement`):** the working tree has uncommitted changes in `panel.luau`, `lib/present.luau`, `plugin.toml`, `tests/panel.test.luau`, `tests/present.test.luau` and both translations. This plan was written against that working tree; commit (or discard) it first so each task's diff stays its own.

**Conventions for every task**
- Run tests from the repo root: `cd ~/dev/projects/noctalia-plugins/aibar`.
- `./run-tests tests/<file>.test.luau` prints `N passed, M failed`; read that line, not the pipe's exit code.
- Fake translator in tests (`mock.fakeTr`) returns the key, then ` name=value` per var in name order.
- Never write an absolute home path in a file (`/mock/home` and `/data/u` are fine).
- Tabs for indentation in Luau, like the existing code.

**Dependency order:** T1..T7 are independent. T8 before T9..T13. T9 needs T2, T3. T9 → T10 → T11. T12 needs T5..T7. T13 needs T1, T8, T12. T14 needs T5, T13. T15 needs T6, T13. T16 needs T2, T7, T13. T17 needs T2, T4, T16. T18 last.

| Batch | Tasks |
|---|---|
| 1 (pure libs) | T1, T2, T3, T4, T5, T6, T7 |
| 2 (sources and presentation) | T8, T9, T10, T11, T12 |
| 3 (service) | T13, T14, T15, T16, T17 |
| 4 (docs) | T18 |

---

### Task 1: Mock answers `commandExists` from a `commands` option

**Requirement:** REQ-003, REQ-006 (test support)
**Files:**
- Modify: `tests/support/noctalia_mock.luau` (`MockOpts` ~line 30, `EnvPrivate` ~line 42, `commandExists` ~line 602, `Mock.new` ~line 778)
- Test: `tests/mock.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: niri-noctalia)
- Reviewers: test-reviewer, business-logic-reviewer

**Step 1: Write the failing test**
Append inside the `describe("mock extensions", ...)` block of `tests/mock.test.luau` (before its closing `end)` at line 58):
```lua
	it("answers commandExists from the commands option", function()
		local env = mock.new({ commands = { "sqlite3" } })
		assert.equal(env.noctalia.commandExists("sqlite3"), true)
		assert.equal(env.noctalia.commandExists("agy"), false)
		assert.equal(mock.new({}).noctalia.commandExists("sqlite3"), false)
	end)
```

**Step 2: Run test to verify it fails**
Run: `./run-tests tests/mock.test.luau`
Expected: FAIL, `expected true, got false` on the first assertion.

**Step 3: Write minimal implementation**
In `MockOpts` add `commands: { string }?,`. In `EnvPrivate` add `commands: { [string]: boolean },`.
Replace the `commandExists` member with:
```lua
		commandExists = function(name: string): boolean
			record(priv, "noctalia.commandExists", { name })
			return priv.commands[name] == true
		end,
```
In `Mock.new`, before `local priv: EnvPrivate = {`, add:
```lua
	local commands = {}
	for _, name in o.commands or {} do
		commands[name] = true
	end
```
and add `commands = commands,` to the `priv` table.

**Step 4: Run test to verify it passes**
Run: `./run-tests`
Expected: PASS, `0 failed`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 2: Grouped window labels, provider login errors and agy backoff

**Requirement:** REQ-002, REQ-006, REQ-007, REQ-012
**Files:**
- Modify: `lib/format.luau` (`windowKey` ~line 52, `LOGIN_ERRORS`/`errorMessage` ~lines 59-80)
- Modify: `lib/poll.luau` (header comment, `Poll.fail` ~lines 40-58)
- Test: `tests/format.test.luau`, `tests/poll.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: niri-noctalia)
- Reviewers: business-logic-reviewer, test-reviewer

**Step 1: Write the failing tests**
Append inside `describe("format", ...)` of `tests/format.test.luau` (before its last `end)`):
```lua
	it("labels windows by span and prefixes their group", function()
		local function tr(key)
			return key
		end
		assert.equal(format.windowKey({ id = "gemini-5h", span = "session" }), "window.session")
		assert.equal(format.windowKey({ id = "x", span = "quota" }), "window.quota")
		assert.equal(format.windowLabel({ id = "gemini-5h", group = "Gemini Models", span = "session" }, tr), "Gemini Models · window.session")
		assert.equal(format.windowLabel({ id = "weekly" }, tr), "window.weekly")
		assert.equal(format.windowLabel({ id = "period", periodType = "monthly", group = "" }, tr), "window.period-monthly")
	end)

	it("maps auth to each provider's login message and quiets their login errors", function()
		for provider, key in { grok = "error.grok-login", codex = "error.codex-login", cursor = "error.cursor-login", agy = "error.agy-login", claude = "error.claude-expired" } do
			assert.equal(format.errorMessage({ error = "auth" }, provider, 0).key, key)
		end
		for _, e in { "codex-login", "cursor-login", "agy-login" } do
			assert.equal(format.errorMessage({ error = e }, "x", 0, true), nil)
			assert.equal(format.errorMessage({ error = e }, "x", 0).key, "error." .. e)
		end
	end)
```
Append inside `describe("poll", ...)` of `tests/poll.test.luau`:
```lua
	it("backs off after a failed agy run, not after other login errors", function()
		local s = poll.fail(poll.createState(), "agy-login", 0, 1000)
		assert.equal(s.error, "agy-login")
		assert.equal(s.retryAt, 1000 + poll.BACKOFF_MS)
		assert.equal(poll.canRequest(s, 1000 + poll.BACKOFF_MS - 1), false)
		assert.equal(poll.canRequest(s, 1000 + poll.BACKOFF_MS), true)
		assert.equal(poll.fail(poll.createState(), "codex-login", 0, 1000).retryAt, 0)
	end)
```

**Step 2: Run tests to verify they fail**
Run: `./run-tests tests/format.test.luau tests/poll.test.luau`
Expected: FAIL, `attempt to call a nil value (field 'windowLabel')` and `expected 301000, got 0`.

**Step 3: Write minimal implementation**
`lib/format.luau`: replace `Format.windowKey` and add `Format.windowLabel` after it:
```lua
-- span (agy buckets, Codex extra limits) names the window kind; id names the
-- window itself.
function Format.windowKey(w: any): string
	if w.span ~= nil then
		return "window." .. w.span
	end
	if w.id == "period" then
		return "window.period-" .. (if w.periodType == "monthly" then "monthly" else "weekly")
	end
	return "window." .. w.id
end

-- "Gemini Models · Weekly" for a window of a named group, else the plain label.
function Format.windowLabel(w: any, tr: any): string
	local base = tr(Format.windowKey(w))
	if typeof(w.group) == "string" and w.group ~= "" then
		return w.group .. " · " .. base
	end
	return base
end
```
Replace `LOGIN_ERRORS` and the `auth` branch of `Format.errorMessage`:
```lua
local LOGIN_ERRORS = {
	auth = true,
	["grok-login"] = true,
	["claude-login"] = true,
	["claude-expired"] = true,
	["codex-login"] = true,
	["cursor-login"] = true,
	["agy-login"] = true,
}
local AUTH_KEY = { grok = "error.grok-login", codex = "error.codex-login", cursor = "error.cursor-login", agy = "error.agy-login" }
```
```lua
	if e == "auth" then
		return { key = AUTH_KEY[provider] or "error.claude-expired" }
	end
```
`lib/poll.luau`: extend the header comment's error list with `| "codex-login" | "cursor-login" | "cursor-sqlite" | "agy-login" | "agy-missing"`. Below `Poll.REQUEST_TIMEOUT_MS` add:
```lua
-- A failed agy run waits for the backoff like a 429: each run costs seconds.
local BACKOFF_KINDS = { ["agy-login"] = true }
```
In `Poll.fail`, right after the `if kind == "http" then ... end` block, add:
```lua
	if BACKOFF_KINDS[kind] then
		retryAt = nowMs + Poll.BACKOFF_MS
	end
```

**Step 4: Run tests to verify they pass**
Run: `./run-tests`
Expected: PASS, `0 failed`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 3: The bar shows the most-used window of an agy snapshot

**Requirement:** REQ-007, REQ-010
**Files:**
- Modify: `lib/pace.luau` (`Pace.primaryWindow` ~lines 37-50)
- Test: `tests/pace.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: niri-noctalia)
- Reviewers: business-logic-reviewer, test-reviewer

**Step 1: Write the failing test**
Append at the end of `tests/pace.test.luau`:
```lua
describe("pace.primaryWindow max", function()
	it("picks the most-used window when the snapshot asks for it", function()
		local snap = { primary = "max", windows = { { id = "session", percent = 10 }, { id = "b", percent = 100 }, { id = "c", percent = 40 } } }
		assert.equal(pace.primaryWindow(snap).id, "b")
		assert.equal(pace.primaryWindow({ windows = snap.windows }).id, "session")
	end)
end)
```

**Step 2: Run test to verify it fails**
Run: `./run-tests tests/pace.test.luau`
Expected: FAIL, `expected "b", got "session"`.

**Step 3: Write minimal implementation**
Replace the comment and the start of `Pace.primaryWindow`:
```lua
-- The window the bar shows: the most-used one when the snapshot sets
-- primary = "max" (agy groups block independently), else Claude's 5 h session,
-- Grok's period, else the first.
function Pace.primaryWindow(snapshot: any): any
	if not snapshot or not snapshot.windows or #snapshot.windows == 0 then
		return nil
	end
	if snapshot.primary == "max" then
		local best = snapshot.windows[1]
		for _, w in snapshot.windows do
			if w.percent > best.percent then
				best = w
			end
		end
		return best
	end
```
(the existing `for _, id in PRIMARY do` loop and fallback stay below it).

**Step 4: Run test to verify it passes**
Run: `./run-tests`
Expected: PASS, `0 failed`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 4: Notifications carry the group and span of a window

**Requirement:** REQ-011
**Files:**
- Modify: `lib/notify.luau` (`table.insert(fire, ...)` ~line 21)
- Test: `tests/notify.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: niri-noctalia)
- Reviewers: business-logic-reviewer, test-reviewer

**Step 1: Write the failing test**
Append inside `describe("notify.crossings", ...)` of `tests/notify.test.luau`:
```lua
	it("carries the group and span of a grouped window", function()
		local s = { provider = "agy", windows = { { id = "gemini-5h", group = "Gemini Models", span = "session", percent = 99, endMs = 5 } } }
		local fired = notify.crossings(s, {}, 97, "agy").fire[1]
		assert.equal(fired.group, "Gemini Models")
		assert.equal(fired.span, "session")
		assert.equal(fired.id, "gemini-5h")
	end)
```

**Step 2: Run test to verify it fails**
Run: `./run-tests tests/notify.test.luau`
Expected: FAIL, `expected "Gemini Models", got nil`.

**Step 3: Write minimal implementation**
```lua
			table.insert(fire, { provider = snapshot.provider, id = w.id, periodType = w.periodType, group = w.group, span = w.span, percent = w.percent, endMs = w.endMs })
```

**Step 4: Run test to verify it passes**
Run: `./run-tests`
Expected: PASS, `0 failed` (existing `deepEqual`s still hold: nil fields are absent).

**Step 5: Commit**
Run: `/git commit`

---

### Task 5: Codex parser and credential reader

**Requirement:** REQ-001, REQ-002
**Files:**
- Create: `lib/codex.luau`
- Create: `tests/fixtures/codex-usage.json`
- Modify: `lib/creds.luau` (append before `return Creds`)
- Test: `tests/codex.test.luau` (create), `tests/creds.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: niri-noctalia)
- Reviewers: business-logic-reviewer, security-reviewer, test-reviewer

**Step 1: Write the failing tests**
`tests/fixtures/codex-usage.json` (real `wham/usage` answer of 2026-10-27, identifiers replaced):
```json
{"user_id":"user-x","account_id":"acct-x","email":"u@x.dev","plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":96,"limit_window_seconds":18000,"reset_after_seconds":14234,"reset_at":1793125633},"secondary_window":{"used_percent":33,"limit_window_seconds":604800,"reset_after_seconds":521963,"reset_at":1793633362}},"code_review_rate_limit":null,"additional_rate_limits":null,"model_usage":{"gpt-6-astra":{"available":true,"available_at":null,"credits_would_enable":false}},"credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":"0","approx_local_messages":[0],"approx_cloud_messages":[0]},"spend_control":{"reached":false,"individual_limit":null},"rate_limit_reached_type":null,"promo":null,"rate_limit_reset_credits":{"available_count":0,"applicable_available_count":0}}
```
`tests/codex.test.luau`:
```lua
local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")

local describe, it = runner.describe, runner.it
local codex = modules.load("lib/codex.luau")
local NOW = 1793110000000

local function fixture(name)
	return mock.json.decode(modules.text("tests/fixtures/" .. name))
end

describe("codex.parseUsage", function()
	it("maps the 5h and weekly windows and the plan", function()
		local r = codex.parseUsage(fixture("codex-usage.json"), NOW)
		assert.equal(r.ok, true)
		assert.deepEqual(r.snapshot.windows, {
			{ id = "session", percent = 96, startMs = 1793107633000, endMs = 1793125633000 },
			{ id = "weekly", percent = 33, startMs = 1793028562000, endMs = 1793633362000 },
		})
		assert.equal(r.snapshot.plan, "plus")
		assert.equal(r.snapshot.provider, "codex")
		assert.deepEqual(r.snapshot.products, {})
		assert.equal(r.snapshot.fetchedAt, NOW)
	end)

	it("falls back to reset_after_seconds and classifies a weekly-only plan", function()
		local data = { plan_type = "free", rate_limit = { primary_window = { used_percent = 10, limit_window_seconds = 604800, reset_after_seconds = 60 } } }
		assert.deepEqual(codex.parseUsage(data, NOW).snapshot.windows, {
			{ id = "weekly", percent = 10, startMs = NOW + 60000 - 604800000, endMs = NOW + 60000 },
		})
	end)

	it("adds named additional limits as grouped windows", function()
		local data = {
			rate_limit = { primary_window = { used_percent = 1, limit_window_seconds = 18000, reset_at = 100 } },
			additional_rate_limits = { { limit_name = "GPT-6 Astra", rate_limit = { primary_window = { used_percent = 80, limit_window_seconds = 18000, reset_at = 200 } } } },
		}
		local w = codex.parseUsage(data, NOW).snapshot.windows
		assert.equal(#w, 2)
		assert.deepEqual(w[2], { id = "extra1:session", group = "GPT-6 Astra", span = "session", percent = 80, startMs = 200000 - 18000000, endMs = 200000 })
	end)

	it("refuses garbage and a body without windows", function()
		assert.deepEqual(codex.parseUsage(nil, NOW), { ok = false, error = "parse" })
		assert.deepEqual(codex.parseUsage({ plan_type = "plus", rate_limit = {} }, NOW), { ok = false, error = "parse" })
	end)
end)
```
Append to `tests/creds.test.luau` (top-level, after the last `end)`):
```lua
describe("creds.codexToken", function()
	it("reads the access token and the account id", function()
		local data = { auth_mode = "chatgpt", tokens = { access_token = "T", account_id = "A", refresh_token = "R" } }
		assert.deepEqual(creds.codexToken(data), { ok = true, token = "T", accountId = "A" })
		assert.deepEqual(creds.codexToken({ tokens = { access_token = "T" } }), { ok = true, token = "T", accountId = "" })
	end)

	it("asks for a login without a token", function()
		assert.deepEqual(creds.codexToken(nil), { ok = false, error = "codex-login" })
		assert.deepEqual(creds.codexToken({ tokens = { access_token = "" } }), { ok = false, error = "codex-login" })
		assert.deepEqual(creds.codexToken({ OPENAI_API_KEY = "k" }), { ok = false, error = "codex-login" })
	end)
end)
```
(If `tests/creds.test.luau` names its module variable differently, use that name.)

**Step 2: Run tests to verify they fail**
Run: `./run-tests tests/codex.test.luau tests/creds.test.luau`
Expected: FAIL, `modules.load: lib/codex.luau not found` (or similar) and `attempt to call a nil value (field 'codexToken')`.

**Step 3: Write minimal implementation**
`lib/codex.luau`:
```lua
-- chatgpt.com/backend-api/wham/usage (decoded) -> normalized snapshot.
-- Request contract (service): GET with Authorization: Bearer <access_token>,
-- ChatGPT-Account-Id: <account_id> (when known), User-Agent: codex-cli.

local Codex = {}

Codex.API_URL = "https://chatgpt.com/backend-api/wham/usage"
Codex.USER_AGENT = "codex-cli"

-- A window's kind from its length; free plans send the weekly window as primary.
local function spanOf(seconds: number?, fallback: string): string
	if seconds ~= nil and seconds <= 6 * 3600 then
		return "session"
	end
	if seconds ~= nil and seconds >= 6 * 86400 then
		return "weekly"
	end
	return fallback
end

-- Appends the windows of one rate_limit block. group names an extra limit.
local function addLimit(windows: { any }, limit: any, prefix: string, group: string?, nowMs: number)
	if typeof(limit) ~= "table" then
		return
	end
	for _, slot in { { limit.primary_window, "session" }, { limit.secondary_window, "weekly" } } do
		local raw = slot[1]
		if typeof(raw) == "table" and typeof(raw.used_percent) == "number" then
			local seconds = tonumber(raw.limit_window_seconds)
			local span = spanOf(seconds, slot[2])
			local endMs = nil
			if typeof(raw.reset_at) == "number" then
				endMs = raw.reset_at * 1000
			elseif typeof(raw.reset_after_seconds) == "number" then
				endMs = nowMs + raw.reset_after_seconds * 1000
			end
			local w: any = {
				id = prefix .. span,
				percent = raw.used_percent,
				startMs = if endMs ~= nil and seconds ~= nil and seconds > 0 then endMs - seconds * 1000 else nil,
				endMs = endMs,
			}
			if group ~= nil then
				w.group = group
				w.span = span
			end
			table.insert(windows, w)
		end
	end
end

function Codex.parseUsage(data: any, nowMs: number)
	if typeof(data) ~= "table" then
		return { ok = false, error = "parse" }
	end
	local windows = {}
	addLimit(windows, data.rate_limit, "", nil, nowMs)
	-- A named pool can block while the main limit reads low (null means none).
	if typeof(data.additional_rate_limits) == "table" then
		for i, extra in data.additional_rate_limits do
			if typeof(extra) == "table" then
				local name = if typeof(extra.limit_name) == "string" and extra.limit_name ~= "" then extra.limit_name
					elseif typeof(extra.metered_feature) == "string" then extra.metered_feature
					else "#" .. i
				addLimit(windows, extra.rate_limit, "extra" .. i .. ":", name, nowMs)
			end
		end
	end
	if #windows == 0 then
		return { ok = false, error = "parse" }
	end
	return {
		ok = true,
		snapshot = { provider = "codex", plan = if typeof(data.plan_type) == "string" then data.plan_type else "", windows = windows, products = {}, fetchedAt = nowMs },
	}
end

return Codex
```
`lib/creds.luau`, before `return Creds`:
```lua
-- ~/.codex/auth.json -> { ok, token, accountId } | { ok = false, error }. An
-- API-key login (OPENAI_API_KEY only) has no plan usage to read.
function Creds.codexToken(data: any)
	local t = if typeof(data) == "table" then data.tokens else nil
	if typeof(t) ~= "table" or typeof(t.access_token) ~= "string" or t.access_token == "" then
		return { ok = false, error = "codex-login" }
	end
	return { ok = true, token = t.access_token, accountId = if typeof(t.account_id) == "string" then t.account_id else "" }
end
```

**Step 4: Run tests to verify they pass**
Run: `./run-tests`
Expected: PASS, `0 failed`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 6: Cursor parser and token reader

**Requirement:** REQ-003, REQ-004, REQ-005
**Files:**
- Create: `lib/cursor.luau`
- Create: `tests/fixtures/cursor-usage.json`
- Test: `tests/cursor.test.luau` (create)

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: niri-noctalia)
- Reviewers: business-logic-reviewer, security-reviewer, test-reviewer

**Step 1: Write the failing test**
`tests/fixtures/cursor-usage.json` (real `GetCurrentPeriodUsage` shape of 2026-10-27; the account is on the free plan, so the three percentages were raised from 0 to exercise the mapping):
```json
{"billingCycleStart":"1791224760450","billingCycleEnd":"1793903160450","planUsage":{"remainingBonus":false,"bonusTooltip":"","autoPercentUsed":12.5,"apiPercentUsed":3,"totalPercentUsed":15.5},"spendLimitUsage":{"pooledLimit":"0","pooledRemaining":"0","individualLimit":0,"limitType":"user","overallLimit":0,"overallRemaining":0},"displayThreshold":200,"displayMessage":"You've used 15% of your included usage","autoModelSelectedDisplayMessage":"","namedModelSelectedDisplayMessage":"","autoBucketModels":["default"]}
```
`tests/cursor.test.luau`:
```lua
local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")

local describe, it = runner.describe, runner.it
local cursor = modules.load("lib/cursor.luau")
local NOW = 1793110000000

local function fixture(name)
	return mock.json.decode(modules.text("tests/fixtures/" .. name))
end

describe("cursor.parseUsage", function()
	it("maps the billing cycle to a monthly period with Auto and API products", function()
		local r = cursor.parseUsage(fixture("cursor-usage.json"), NOW)
		assert.equal(r.ok, true)
		assert.deepEqual(r.snapshot.windows, { { id = "period", periodType = "monthly", percent = 15.5, startMs = 1791224760450, endMs = 1793903160450 } })
		assert.deepEqual(r.snapshot.products, { { name = "Auto", percent = 12.5 }, { name = "API", percent = 3 } })
		assert.equal(r.snapshot.provider, "cursor")
		assert.equal(r.snapshot.plan, "")
		assert.equal(r.snapshot.fetchedAt, NOW)
	end)

	it("reads dropped zero fields as 0%", function()
		local r = cursor.parseUsage({ billingCycleStart = "1", billingCycleEnd = "2", planUsage = {} }, NOW)
		assert.equal(r.snapshot.windows[1].percent, 0)
		assert.deepEqual(r.snapshot.products, { { name = "Auto", percent = 0 }, { name = "API", percent = 0 } })
	end)

	it("refuses garbage", function()
		assert.deepEqual(cursor.parseUsage(nil, NOW), { ok = false, error = "parse" })
		assert.deepEqual(cursor.parseUsage({ displayMessage = "x" }, NOW), { ok = false, error = "parse" })
	end)
end)

describe("cursor token", function()
	it("builds a read-only sqlite3 argv that never holds the token", function()
		local db = "/mock/home/.config/Cursor/User/globalStorage/state.vscdb"
		assert.deepEqual(cursor.tokenArgv(db), { "sqlite3", "-readonly", db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'" })
		assert.equal(cursor.DB_PATH, "~/.config/Cursor/User/globalStorage/state.vscdb")
	end)

	it("trims the token and refuses failures", function()
		assert.deepEqual(cursor.tokenFrom({ exitCode = 0, stdout = "tok.en\n" }), { ok = true, token = "tok.en" })
		assert.deepEqual(cursor.tokenFrom({ exitCode = 0, stdout = "\n" }), { ok = false, error = "cursor-login" })
		assert.deepEqual(cursor.tokenFrom({ exitCode = 0, stdout = "a b" }), { ok = false, error = "cursor-login" })
		assert.deepEqual(cursor.tokenFrom({ exitCode = 1, stdout = "x" }), { ok = false, error = "cursor-login" })
		assert.deepEqual(cursor.tokenFrom(nil), { ok = false, error = "cursor-login" })
	end)
end)
```

**Step 2: Run test to verify it fails**
Run: `./run-tests tests/cursor.test.luau`
Expected: FAIL, `lib/cursor.luau` cannot be loaded.

**Step 3: Write minimal implementation**
`lib/cursor.luau`:
```lua
-- api2.cursor.sh DashboardService/GetCurrentPeriodUsage (decoded) -> snapshot.
-- Request contract (service): POST "{}" with Authorization: Bearer <token>,
-- Content-Type: application/json, Connect-Protocol-Version: 1. The token comes
-- from Cursor's state.vscdb through sqlite3; argv holds only the query.

local Cursor = {}

Cursor.API_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
Cursor.DB_PATH = "~/.config/Cursor/User/globalStorage/state.vscdb"
Cursor.TOKEN_QUERY = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"

-- dbPath must be expanded already: sqlite3 does not expand "~".
function Cursor.tokenArgv(dbPath: string): { string }
	return { "sqlite3", "-readonly", dbPath, Cursor.TOKEN_QUERY }
end

-- runAsync result -> { ok, token } | { ok = false, error = "cursor-login" }
function Cursor.tokenFrom(result: any)
	if typeof(result) ~= "table" or result.exitCode ~= 0 or typeof(result.stdout) ~= "string" then
		return { ok = false, error = "cursor-login" }
	end
	local token = string.match(result.stdout, "^%s*(.-)%s*$")
	if token == nil or token == "" or string.find(token, "%s") then
		return { ok = false, error = "cursor-login" }
	end
	return { ok = true, token = token }
end

local function percentOf(v: any): number
	return if typeof(v) == "number" then v else 0
end

-- Protobuf JSON drops zero fields: a missing percent is 0%.
function Cursor.parseUsage(data: any, nowMs: number)
	if typeof(data) ~= "table" then
		return { ok = false, error = "parse" }
	end
	local endMs = tonumber(data.billingCycleEnd)
	if typeof(data.planUsage) ~= "table" and endMs == nil then
		return { ok = false, error = "parse" }
	end
	local usage = if typeof(data.planUsage) == "table" then data.planUsage else {}
	return {
		ok = true,
		snapshot = {
			provider = "cursor",
			plan = "",
			windows = { { id = "period", periodType = "monthly", percent = percentOf(usage.totalPercentUsed), startMs = tonumber(data.billingCycleStart), endMs = endMs } },
			products = { { name = "Auto", percent = percentOf(usage.autoPercentUsed) }, { name = "API", percent = percentOf(usage.apiPercentUsed) } },
			fetchedAt = nowMs,
		},
	}
end

return Cursor
```

**Step 4: Run test to verify it passes**
Run: `./run-tests`
Expected: PASS, `0 failed`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 7: Agy quota parser

**Requirement:** REQ-006, REQ-007
**Files:**
- Create: `lib/agy.luau`
- Create: `tests/fixtures/agy-quota.json`
- Test: `tests/agy.test.luau` (create)

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: niri-noctalia)
- Reviewers: business-logic-reviewer, test-reviewer

**Step 1: Write the failing test**
`tests/fixtures/agy-quota.json` (real `agy -p "/quota" --output-format json` stdout of 2026-10-27; it holds no personal field):
```json
{"conversation_id":"","status":"SUCCESS","response":"Gemini Models\tWeekly Limit Remaining\t100%\t2026-11-03T14:42:33Z\nGemini Models\tFive Hour Limit Remaining\t100%\t2026-10-27T19:42:33Z\nClaude and GPT models\tWeekly Limit Remaining\t100%\t2026-11-03T14:42:33Z\nClaude and GPT models\tFive Hour Limit Remaining\t100%\t2026-10-27T19:42:33Z\nGemini 4 Argon\tGemini 4 Argon Weekly Limit\t0%\t2026-10-31T13:01:29Z\n","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"command":{"name":"usage","data":{"description":"Within each group, models share a weekly limit and a 5-hour limit. Quota is consumed proportionally to the cost of the tokens. Thus, limits will last longer with shorter tasks or using more cost-effective models. The 5-hour limit smooths out aggregate demand to fairly distribute global capacity across all users, while your weekly limit is tied directly to your individual tier.","groups":[{"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-11-03T14:42:33Z"},{"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-10-27T19:42:33Z"}]},{"name":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[{"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-11-03T14:42:33Z"},{"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-10-27T19:42:33Z"}]},{"name":"Gemini 4 Argon","description":"For paid Pro plans, Argon quota is separate. Higher Argon quota (included as part of the larger Gemini quota bucket) is available on Ultra plans.","buckets":[{"id":"gemini-argon-wtu-weekly","name":"Gemini 4 Argon Weekly Limit","description":"You have hit your weekly limit, it refreshes in 3 days, 22 hours. If on a supported paid plan, you can use AI credits in the interim or upgrade to a higher tier.","window":"weekly","remaining_fraction":0,"reset_time":"2026-10-31T13:01:29Z"}]}]}}}
```
`tests/agy.test.luau`:
```lua
local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")

local describe, it = runner.describe, runner.it
local agy = modules.load("lib/agy.luau")
local NOW = 1793110000000
local H = 3600000
local WEEKLY_END = 1793716953000 -- 2026-11-03T14:42:33Z
local FIVE_END = 1793130153000 -- 2026-10-27T19:42:33Z
local ARGON_END = 1793451689000 -- 2026-10-31T13:01:29Z

local function fixture(name)
	return mock.json.decode(modules.text("tests/fixtures/" .. name))
end

describe("agy.parseQuota", function()
	it("maps every bucket to a window with its group and span", function()
		local r = agy.parseQuota(fixture("agy-quota.json"), NOW)
		assert.equal(r.ok, true)
		local w = r.snapshot.windows
		assert.equal(#w, 5)
		assert.deepEqual(w[1], { id = "gemini-weekly", group = "Gemini Models", span = "weekly", percent = 0, startMs = WEEKLY_END - 168 * H, endMs = WEEKLY_END })
		assert.deepEqual(w[2], { id = "gemini-5h", group = "Gemini Models", span = "session", percent = 0, startMs = FIVE_END - 5 * H, endMs = FIVE_END })
		assert.equal(w[3].group, "Claude and GPT models")
		assert.deepEqual(w[5], { id = "gemini-argon-wtu-weekly", group = "Gemini 4 Argon", span = "weekly", percent = 100, startMs = ARGON_END - 168 * H, endMs = ARGON_END })
		assert.equal(r.snapshot.primary, "max")
		assert.equal(r.snapshot.provider, "agy")
		assert.equal(r.snapshot.fetchedAt, NOW)
	end)

	it("keeps an unknown window kind as a plain quota without bounds", function()
		local data = { status = "SUCCESS", command = { data = { groups = { { name = "G", buckets = { { id = "x", window = "daily", remaining_fraction = 0.25, reset_time = "2026-10-27T19:42:33Z" } } } } } } }
		assert.deepEqual(agy.parseQuota(data, NOW).snapshot.windows, { { id = "x", group = "G", span = "quota", percent = 75, endMs = FIVE_END } })
	end)

	it("refuses a failed run and an empty summary", function()
		assert.deepEqual(agy.parseQuota({ status = "ERROR", error = "Individual quota reached." }, NOW), { ok = false, error = "agy-login" })
		assert.deepEqual(agy.parseQuota(nil, NOW), { ok = false, error = "agy-login" })
		assert.deepEqual(agy.parseQuota({ status = "SUCCESS", command = { data = { groups = {} } } }, NOW), { ok = false, error = "parse" })
	end)

	it("runs /quota in JSON print mode", function()
		assert.deepEqual(agy.ARGV, { "agy", "-p", "/quota", "--output-format", "json" })
	end)
end)
```

**Step 2: Run test to verify it fails**
Run: `./run-tests tests/agy.test.luau`
Expected: FAIL, `lib/agy.luau` cannot be loaded.

**Step 3: Write minimal implementation**
`lib/agy.luau`:
```lua
-- `agy -p "/quota" --output-format json` stdout (decoded) -> snapshot. The
-- command runs no model turn; agy authenticates and renews its own session, so
-- the plugin never sees an agy token.

local time = require("./time.luau")

local Agy = {}

Agy.ARGV = { "agy", "-p", "/quota", "--output-format", "json" }
local HOUR = 3600000
local SPAN = { ["5h"] = { key = "session", ms = 5 * HOUR }, weekly = { key = "weekly", ms = 168 * HOUR } }

function Agy.parseQuota(data: any, nowMs: number)
	if typeof(data) ~= "table" or data.status ~= "SUCCESS" then
		return { ok = false, error = "agy-login" }
	end
	local command = if typeof(data.command) == "table" then data.command else {}
	local body = if typeof(command.data) == "table" then command.data else {}
	local windows = {}
	for _, group in (if typeof(body.groups) == "table" then body.groups else {}) do
		if typeof(group) == "table" and typeof(group.buckets) == "table" then
			for _, b in group.buckets do
				if typeof(b) == "table" and typeof(b.id) == "string" and typeof(b.remaining_fraction) == "number" then
					local span = SPAN[b.window]
					local endMs = time.parseIso(b.reset_time)
					table.insert(windows, {
						id = b.id,
						group = if typeof(group.name) == "string" then group.name else "",
						span = if span then span.key else "quota",
						percent = math.clamp((1 - b.remaining_fraction) * 100, 0, 100),
						startMs = if span and endMs ~= nil then endMs - span.ms else nil,
						endMs = endMs,
					})
				end
			end
		end
	end
	if #windows == 0 then
		return { ok = false, error = "parse" }
	end
	-- Each group blocks on its own: the bar shows the most-used window.
	return { ok = true, snapshot = { provider = "agy", plan = "", primary = "max", windows = windows, products = {}, fetchedAt = nowMs } }
end

return Agy
```

**Step 4: Run test to verify it passes**
Run: `./run-tests`
Expected: PASS, `0 failed`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 8: Sources for every provider, with toggles

**Requirement:** REQ-008, REQ-011
**Files:**
- Modify: `lib/accounts.luau` (header comment, `Accounts.sources` ~line 99, `Accounts.credPath` ~line 108, `Accounts.cachedSnapshot` ~line 143)
- Modify: `service.luau` (`configure` ~line 296: sources from the toggles)
- Modify: `tests/support/service_helpers.luau` (`H.boot`)
- Test: `tests/accounts.test.luau`, `tests/view.test.luau`, `tests/service.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: niri-noctalia)
- Reviewers: business-logic-reviewer, consequences-reviewer, test-reviewer

**Step 1: Write the failing tests**
In `tests/accounts.test.luau`:
- Add at the top, after `local accounts = ...`: `local CLAUDE_GROK = { codex = false, agy = false, cursor = false }`.
- In `"lists the default Claude account, the extras, then Grok"`, change the first call to `accounts.sources(accounts.parseAccounts({ "Trabalho=~/.claude-trabalho" }), CLAUDE_GROK)` and the last line to `assert.deepEqual(keys(accounts.sources(nil, CLAUDE_GROK)), { "claude", "grok" })`.
- In `describe("accounts keys", ...)`, change the list to `accounts.sources(accounts.parseAccounts({ "T=~/.claude-t" }), CLAUDE_GROK)`.
- Append inside `describe("accounts.sources", ...)`:
```lua
	it("lists the other providers in tab order and drops disabled ones", function()
		assert.deepEqual(keys(accounts.sources(nil)), { "claude", "grok", "codex", "agy", "cursor" })
		assert.deepEqual(keys(accounts.sources(nil, { grok = false, agy = false })), { "claude", "codex", "cursor" })
		assert.deepEqual(accounts.sources(nil)[3], { key = "codex", provider = "codex", name = "", dir = "", frozen = false })
	end)
```
- Append inside `describe("accounts paths", ...)`:
```lua
	it("watches only credentials the plugin reads and that change with a login", function()
		assert.equal(accounts.credPath({ provider = "codex", dir = "" }), "~/.codex/auth.json")
		assert.equal(accounts.credPath({ provider = "cursor", dir = "" }), "")
		assert.equal(accounts.credPath({ provider = "agy", dir = "" }), "")
	end)
```
- In `"picks the cached snapshot by account id, else by provider"`, add `codex = { c = 1 }` to `cache` and `assert.deepEqual(accounts.cachedSnapshot(cache, "codex", ""), { c = 1 })`.

In `tests/view.test.luau`, change `SOURCES` to `accounts.sources(accounts.parseAccounts({ "Frozen=~/.claude-freeze" }), { codex = false, agy = false, cursor = false })`.

`tests/support/service_helpers.luau`, in `H.boot`: extend the default `config` with `show_grok = true, show_codex = false, show_agy = false, show_cursor = false` (existing service tests keep their Claude + Grok cycle; new-provider tests opt in), and pass the new mock options:
```lua
	return entry.load("service.luau", { config = config, fs = fs, now = opts.now or H.NOW, commands = opts.commands, async = opts.async })
```
Append inside the first `describe` of `tests/service.test.luau`:
```lua
	it("drops a disabled provider and polls it when turned back on", function()
		local s = boot({ config = { show_grok = false } })
		assert.equal(sourceOf(s, "grok"), nil)
		assert.equal(#requests(s, GROK_URL), 0)
		mock.setConfig(s.env, "show_grok", true)
		s.call("onConfigChanged")
		assert.equal(#requests(s, GROK_URL), 1)
		assert.equal(sourceOf(s, "grok").inFlight, true)
	end)
```

**Step 2: Run tests to verify they fail**
Run: `./run-tests tests/accounts.test.luau tests/view.test.luau tests/service.test.luau`
Expected: FAIL, `"lists the other providers..."` gets `{ "claude", "grok" }`; codex `credPath` returns `~/.claude/.credentials.json`; `sourceOf(s, "grok")` is not nil.

**Step 3: Write minimal implementation**
Header comment of `lib/accounts.luau`: replace `... and Grok. Keys: "claude", "claude:<slug>", "grok".` with `..., Grok, Codex, Agy and Cursor. Keys: "claude", "claude:<slug>", "grok", "codex", "agy", "cursor".`
Below `local DEFAULT_DIR = "~/.claude"` add:
```lua
-- One source each, after the Claude accounts, in tab order.
Accounts.PROVIDERS = { "grok", "codex", "agy", "cursor" }
-- Cursor's state.vscdb changes on every IDE write and agy keeps its session in
-- the keyring: neither is watched.
local CRED_PATH = { grok = "~/.grok/auth.json", codex = "~/.codex/auth.json" }
```
Replace `Accounts.sources`:
```lua
-- enabled: { [provider] = boolean }; a provider missing from it is on.
function Accounts.sources(extra: any, enabled: any?)
	local list = { { key = "claude", provider = "claude", name = "", dir = "", frozen = false } }
	for _, a in extra or {} do
		table.insert(list, { key = a.key, provider = "claude", name = a.name, dir = a.dir, frozen = true })
	end
	for _, provider in Accounts.PROVIDERS do
		if enabled == nil or enabled[provider] ~= false then
			table.insert(list, { key = provider, provider = provider, name = "", dir = "", frozen = false })
		end
	end
	return list
end
```
Replace `Accounts.credPath`:
```lua
-- "" for a source with no credential file to watch.
function Accounts.credPath(source: any): string
	if source.provider ~= "claude" then
		return CRED_PATH[source.provider] or ""
	end
	return (if source.dir ~= "" then source.dir else DEFAULT_DIR) .. "/.credentials.json"
end
```
In `Accounts.cachedSnapshot`, replace `if key == "claude" or key == "grok" then` with `if key == "claude" or table.find(Accounts.PROVIDERS, key) then`.

In `service.luau`, above `configure` add:
```lua
-- show_<provider> settings; Claude is always on.
local function enabledProviders(): any
	local map = {}
	for _, p in accounts.PROVIDERS do
		map[p] = noctalia.getConfig("show_" .. p) ~= false
	end
	return map
end
```
and in `configure` use `sources = accounts.sources(accounts.parseAccounts(noctalia.getConfig("claude_accounts")), enabledProviders())`. (The host returns nil for a setting `plugin.toml` does not declare yet, which reads as on; Task 12 declares them.)

**Step 4: Run tests to verify they pass**
Run: `./run-tests`
Expected: PASS, `0 failed`. Until Task 13, an enabled `cursor`/`agy` source falls through to the Claude poll path, reads the empty cred path and fails with `claude-login` without a request; no test enables them yet.

**Step 5: Commit**
Run: `/git commit`

---

### Task 9: Cards and bar for every provider

**Requirement:** REQ-005, REQ-007, REQ-010
**Files:**
- Modify: `lib/present.luau` (`glyphOf` ~line 9, `Present.bar` rows ~line 79, `Present.card` ~lines 121-190)
- Test: `tests/present.test.luau`

**Team:**
- Track: frontend
- Implementer: frontend-engineer (skills: niri-noctalia)
- Reviewers: type-safety-reviewer, test-reviewer, accessibility-guardrails

**Step 1: Write the failing tests**
Append inside `describe("present.bar", ...)` of `tests/present.test.luau`:
```lua
	it("shows each provider's glyph, plan, grouped labels and products", function()
		local snap = { provider = "agy", plan = "", primary = "max", windows = { { id = "gemini-5h", group = "Gemini Models", span = "session", percent = 40, startMs = 0, endMs = 5 * H } }, products = {}, fetchedAt = 0 }
		local c = present.card(source({ key = "agy", provider = "agy", snapshot = snap }), H, tr)
		assert.equal(c.glyph, "brand-google")
		assert.equal(c.title, "provider.agy")
		assert.equal(c.rows[1].label, "Gemini Models · window.session")
		local codex = present.card(source({ key = "codex", provider = "codex", snapshot = { provider = "codex", plan = "plus", windows = {}, products = {}, fetchedAt = 0 } }), 0, tr)
		assert.equal(codex.glyph, "brand-openai")
		assert.equal(codex.plan, "Plus")
		local cur = present.card(source({ key = "cursor", provider = "cursor", snapshot = { provider = "cursor", plan = "", windows = {}, products = { { name = "Auto", percent = 12.5 } }, fetchedAt = 0 } }), 0, tr)
		assert.equal(cur.glyph, "pointer")
		assert.deepEqual(cur.products, { { name = "Auto", percentText = "13%" } })
	end)

	it("shows the most-used agy window in the bar with its group", function()
		local snap = { provider = "agy", primary = "max", windows = {
			{ id = "a", group = "G", span = "session", percent = 10, startMs = 0, endMs = 5 * H },
			{ id = "b", group = "Argon", span = "weekly", percent = 100, startMs = 0, endMs = 168 * H },
		}, products = {}, fetchedAt = 0 }
		local m = present.bar({ now = H, barKey = "agy", sources = { source({ key = "agy", provider = "agy", snapshot = snap }) } }, tr)
		assert.equal(m.glyph, "brand-google")
		assert.equal(m.label, "100% · 6d23h")
		assert.equal(m.tooltip[2][1], "Argon · window.weekly")
	end)
```

**Step 2: Run tests to verify they fail**
Run: `./run-tests tests/present.test.luau`
Expected: FAIL, `expected "brand-google", got "asterisk"`.

**Step 3: Write minimal implementation**
Replace `glyphOf`:
```lua
local GLYPH = { claude = "asterisk", grok = "brand-x", codex = "brand-openai", agy = "brand-google", cursor = "pointer" }

local function glyphOf(provider: string): string
	return GLYPH[provider] or "asterisk"
end
```
In `Present.bar`, replace `table.insert(rows, { tr(format.windowKey(w)), value })` with `table.insert(rows, { format.windowLabel(w, tr), value })`.
In `Present.card`:
- replace `if entry.provider == "claude" and typeof(snap.plan) == "string" and snap.plan ~= "" then` with `if typeof(snap.plan) == "string" and snap.plan ~= "" then`;
- in the rows loop replace `label = tr(format.windowKey(w)),` with `label = format.windowLabel(w, tr),`;
- replace the `if entry.provider == "grok" then ... end` products block with:
```lua
	for _, p in snap.products or {} do
		table.insert(card.products, { name = p.name, percentText = format.percentText(p.percent) })
	end
```
Update the panel comment in `panel.luau` line 532 later (Task 11); no change here.

**Step 4: Run tests to verify they pass**
Run: `./run-tests`
Expected: PASS, `0 failed`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 10: Panel model with provider tabs

**Requirement:** REQ-009
**Files:**
- Modify: `lib/present.luau` (`Present.panel` ~lines 192-220)
- Test: `tests/present.test.luau` (replace the whole `describe("present.panel", ...)` block)

**Team:**
- Track: frontend
- Implementer: frontend-engineer (skills: niri-noctalia)
- Reviewers: type-safety-reviewer, test-reviewer, business-logic-reviewer

**Step 1: Write the failing test**
Replace the `describe("present.panel", ...)` block of `tests/present.test.luau` with:
```lua
describe("present.panel", function()
	local v = { now = 0, barKey = "claude", sources = {
		source({ email = "a@x.dev" }),
		source({ key = "claude:f", name = "F", frozen = true }),
		source({ key = "grok", provider = "grok", inFlight = true }),
		source({ key = "codex", provider = "codex", error = "codex-login" }),
	} }

	it("lists one tab per provider in source order and shows the selected one", function()
		local m = present.panel(v, 1, tr, "codex")
		assert.equal(m.title, "panel.title")
		assert.equal(m.refresh, "panel.refresh")
		assert.equal(m.busy, true)
		assert.deepEqual(m.providers, {
			{ key = "claude", label = "Claude", selected = false },
			{ key = "grok", label = "Grok", selected = false },
			{ key = "codex", label = "Codex", selected = true },
		})
		assert.equal(m.section.title, "provider.codex")
		assert.equal(m.section.error, "error.codex-login")
		assert.deepEqual(m.tabs, {})
	end)

	it("keeps the Claude accounts as sub-tabs of the Claude tab", function()
		local m = present.panel(v, 2, tr, "claude")
		assert.deepEqual(m.tabs, { { label = "panel.active", selected = false }, { label = "F", selected = true } })
		assert.equal(m.section.badge.text, "panel.frozen")
		assert.equal(present.panel(v, 9, tr, "claude").tabs[2].selected, true)
	end)

	it("falls back to the first provider and hides sub-tabs with one Claude account", function()
		local single = { now = 0, barKey = "claude", sources = { source({}), source({ key = "grok", provider = "grok" }) } }
		local m = present.panel(single, 1, tr, "cursor")
		assert.equal(m.providers[1].selected, true)
		assert.equal(m.section.title, "provider.claude")
		assert.deepEqual(m.tabs, {})
		assert.equal(m.busy, false)
	end)

	it("is empty before the first view", function()
		local m = present.panel(nil, 1, tr)
		assert.equal(m.section, nil)
		assert.deepEqual(m.providers, {})
		assert.deepEqual(m.tabs, {})
	end)

	it("opens on the provider of the bar source", function()
		assert.equal(present.providerOf(v, "codex"), "codex")
		assert.equal(present.providerOf(v, "claude:f"), "claude")
		assert.equal(present.providerOf(nil, "x"), "claude")
	end)
end)
```

**Step 2: Run test to verify it fails**
Run: `./run-tests tests/present.test.luau`
Expected: FAIL, `m.providers` is nil / `attempt to call a nil value (field 'providerOf')`.

**Step 3: Write minimal implementation**
Replace `Present.panel` (and its comment) with:
```lua
-- Short tab labels; the section title keeps the full provider name.
Present.TAB_LABEL = { claude = "Claude", grok = "Grok", codex = "Codex", agy = "Agy", cursor = "Cursor" }

-- The provider the panel opens on: the bar source's.
function Present.providerOf(view: any, key: string?): string
	local entry = if view and key then Present.find(view, key) else nil
	return if entry then entry.provider else "claude"
end

-- claudeTab: 1-based index of the Claude account shown under the Claude tab.
-- provider: the selected top tab; one without a source falls back to the first.
function Present.panel(view: any, claudeTab: number, tr: any, provider: string?)
	local model = { title = tr("panel.title"), refresh = tr("panel.refresh"), busy = false, providers = {}, tabs = {}, section = nil }
	if not view or not view.sources then
		return model
	end
	local now = view.now or 0
	local order = {}
	local byProvider = {}
	for _, s in view.sources do
		if s.inFlight then
			model.busy = true
		end
		if byProvider[s.provider] == nil then
			byProvider[s.provider] = {}
			table.insert(order, s.provider)
		end
		table.insert(byProvider[s.provider], s)
	end
	if #order == 0 then
		return model
	end
	local selected = if provider ~= nil and byProvider[provider] ~= nil then provider else order[1]
	for _, p in order do
		table.insert(model.providers, { key = p, label = Present.TAB_LABEL[p] or p, selected = p == selected })
	end
	local list = byProvider[selected]
	local index = math.clamp(claudeTab, 1, #list)
	model.section = Present.card(list[index], now, tr)
	if #list > 1 then
		for i, s in list do
			table.insert(model.tabs, { label = if s.frozen then s.name else tr("panel.active"), selected = i == index })
		end
	end
	return model
end
```
(Only Claude has more than one source, so `#list > 1` means Claude accounts.)

**Step 4: Run tests to verify they pass**
Run: `./run-tests tests/present.test.luau`
Expected: PASS. The full suite fails in `tests/panel.test.luau` until Task 11 (`panel.luau` still reads `m.claude`); run Task 11 next before committing, or commit both together.

**Step 5: Commit**
Run: `/git commit` (after Task 11 is green, together with it)

---

### Task 11: Panel renders the provider tab row

**Requirement:** REQ-009
**Files:**
- Modify: `panel.luau` (header comment lines 1-3, state ~line 8, `section` comment ~line 101, `render` ~lines 150-166, `onOpen` ~lines 172-177)
- Test: `tests/panel.test.luau`

**Team:**
- Track: frontend
- Implementer: frontend-engineer (skills: niri-noctalia, frontend-design)
- Reviewers: test-reviewer, accessibility-guardrails, type-safety-reviewer

**Step 1: Write the failing tests**
In `tests/panel.test.luau`, in `"renders the title, both cards and their content on open"`, rename it to `"renders the title, the provider tabs and the Claude section on open"` and replace its two Grok lines with:
```lua
		assert.equal(has(t, "Grok"), true)
		assert.equal(has(t, "provider.grok"), false)
```
Append inside `describe("panel", ...)`:
```lua
	it("shows one provider at a time behind the provider tabs", function()
		local p = entry.load("panel.luau", {})
		p.env.noctalia.state.set("view", VIEW)
		p.call("onOpen")
		local grokTab = find(p, function(n) return n.type == "button" and n.props.text == "Grok" end)
		assert.equal(grokTab.props.selected, false)
		grokTab.props.onClick()
		local t = texts(p)
		assert.equal(has(t, "provider.grok"), true)
		assert.equal(has(t, "error.grok-login"), true)
		assert.equal(has(t, "provider.claude"), false)
		assert.equal(find(p, function(n) return n.type == "button" and n.props.text == "Grok" end).props.selected, true)
	end)

	it("opens on the provider of the bar source", function()
		local p = entry.load("panel.luau", {})
		local v = table.clone(VIEW)
		v.barKey = "grok"
		p.env.noctalia.state.set("view", v)
		p.call("onOpen")
		assert.equal(has(texts(p), "provider.grok"), true)
		assert.equal(has(texts(p), "provider.claude"), false)
	end)

	it("hides the provider row with a single provider", function()
		local p = entry.load("panel.luau", {})
		p.env.noctalia.state.set("view", { now = 0, barKey = "claude", sources = { src({ snapshot = SNAP }) } })
		p.call("onOpen")
		assert.equal(find(p, function(n) return n.type == "button" and n.props.text == "Claude" end), nil)
	end)
```

**Step 2: Run tests to verify they fail**
Run: `./run-tests tests/panel.test.luau`
Expected: FAIL, `attempt to index nil with 'claude'`-style errors from the old `render` (or `has(t, "Grok")` false).

**Step 3: Write minimal implementation**
Header comment of `panel.luau`:
```lua
-- AI Bar panel: a row of provider tabs and the selected provider's section, one
-- card per usage window; Claude accounts share their section with a sub-tab
-- row. Renders only from the service's `view`. The host already pads the
-- panel, so the root adds no padding.
```
State: below `local claudeTab = 1` add `local providerTab = "claude"`.
In `section`, change the comment starting `-- Grok products share the billing period` to start `-- Products (Grok, Cursor) share the billing period`.
Before `function render()` add:
```lua
local function providerTabs(list: any): any
	local buttons = {}
	for _, p in list do
		table.insert(buttons, ui.button({
			key = "provider-" .. p.key,
			text = p.label,
			variant = "ghost",
			controlSize = "sm",
			selected = p.selected,
			onClick = function()
				providerTab = p.key
				claudeTab = 1
				render()
			end,
		}))
	end
	return ui.row({ align = "center", gap = 4 }, buttons)
end
```
Replace `render`:
```lua
function render()
	if not isOpen then
		return
	end
	local m = present.panel(current, claudeTab, tr, providerTab)
	local children = { header(m) }
	if #m.providers > 1 then
		table.insert(children, providerTabs(m.providers))
	end
	local body = {}
	if m.section then
		table.insert(body, section(m.section, m.tabs))
	end
	table.insert(children, ui.scroll({ flexGrow = 1, gap = 16, align = "stretch" }, body))
	panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end
```
Replace `onOpen`:
```lua
-- The panel opens on the bar source's provider and its first account, like v4.
function onOpen(_context: any)
	isOpen = true
	providerTab = present.providerOf(current, if current then current.barKey else nil)
	claudeTab = 1
	render()
end
```
Note: `sectionHeader`'s `onClick` for account tabs keeps setting `claudeTab = i`.

**Step 4: Run tests to verify they pass**
Run: `./run-tests`
Expected: PASS, `0 failed`.

**Step 5: Commit**
Run: `/git commit` (Tasks 10 and 11 together)

---

### Task 12: Translations, provider toggles and manifest

**Requirement:** REQ-008, REQ-010, REQ-012, REQ-014
**Files:**
- Modify: `translations/en.json`, `translations/pt-BR.json`
- Modify: `plugin.toml` (version line 3, description line 8, tags line 9, settings after `claude_accounts` ~line 50)
- Test: `tests/manifest.test.luau` (translation count line ~47, version line ~53, purity list line ~66)

**Team:**
- Track: docs
- Implementer: rpi-implementer (skills: niri-noctalia)
- Reviewers: self-review (no panel); accents checked with pt-br-accent-fix

**Step 1: Write the failing test**
In `tests/manifest.test.luau`:
- `assert.equal(count, 9)` → `assert.equal(count, 13)`;
- `'version = "0.2.0"'` → `'version = "0.3.0"'`;
- purity list → `{ "accounts", "agy", "claude", "codex", "creds", "cursor", "format", "grok", "notify", "pace", "poll", "present", "time", "view" }`;
- append inside `describe("translations", ...)`:
```lua
	it("names every provider and its errors", function()
		for _, key in { "provider.codex", "provider.agy", "provider.cursor", "window.quota", "error.codex-login", "error.cursor-login", "error.cursor-sqlite", "error.agy-login", "error.agy-missing" } do
			if en[key] == nil then
				error("missing translation: " .. key)
			end
		end
	end)
```

**Step 2: Run test to verify it fails**
Run: `./run-tests tests/manifest.test.luau`
Expected: FAIL, `expected 13, got 9`.

**Step 3: Write minimal implementation**
`translations/en.json`:
- `"provider"`: `{ "claude": "Claude Code", "grok": "Grok", "codex": "Codex", "agy": "Antigravity", "cursor": "Cursor" }`
- `"window"`: add `"quota": "Quota"`
- `"error"`: add
  `"codex-login": "Codex token expired: open \`codex\` to renew it"`,
  `"cursor-login": "No Cursor session: sign in to Cursor"`,
  `"cursor-sqlite": "Install sqlite3 to read the Cursor session"`,
  `"agy-login": "Run \`agy\` to sign in"`,
  `"agy-missing": "Antigravity CLI (\`agy\`) not found"`
- `"settings"`: `bar_provider.description` → `"Source the bar shows: claude, grok, codex, agy, cursor or claude:<account name>. Middle click on the widget cycles through the sources; changing this setting overrides that choice."`; add
  `"show_grok": { "label": "Show Grok" }`, `"show_codex": { "label": "Show Codex" }`, `"show_agy": { "label": "Show Antigravity" }`, `"show_cursor": { "label": "Show Cursor" }`

`translations/pt-BR.json`:
- `"provider"`: `{ "claude": "Claude Code", "grok": "Grok", "codex": "Codex", "agy": "Antigravity", "cursor": "Cursor" }`
- `"window"`: add `"quota": "Cota"`
- `"error"`: add
  `"codex-login": "Token do Codex expirou: abra o \`codex\` para renovar"`,
  `"cursor-login": "Sem sessão do Cursor: entre no Cursor"`,
  `"cursor-sqlite": "Instale o sqlite3 para ler a sessão do Cursor"`,
  `"agy-login": "Rode \`agy\` para entrar"`,
  `"agy-missing": "CLI do Antigravity (\`agy\`) não encontrado"`
- `"settings"`: `bar_provider.description` → `"Fonte exibida na barra: claude, grok, codex, agy, cursor ou claude:<nome da conta>. O clique do meio no widget alterna entre as fontes; mudar esta opção substitui essa escolha."`; add
  `"show_grok": { "label": "Mostrar Grok" }`, `"show_codex": { "label": "Mostrar Codex" }`, `"show_agy": { "label": "Mostrar Antigravity" }`, `"show_cursor": { "label": "Mostrar Cursor" }`

(The backticks are literal inside the JSON strings; do not escape them with `\`.)

`plugin.toml`:
```toml
version = "0.3.0"
```
```toml
description = "Claude Code, Grok, Codex, Antigravity and Cursor plan usage in the bar: percent, reset countdown and a progress bar."
tags = ["ai", "usage", "claude", "grok", "codex", "antigravity", "cursor"]
```
(116 characters, within the 120 limit.) After the `claude_accounts` setting block add:
```toml
[[setting]]
key = "show_grok"
type = "bool"
label_key = "settings.show_grok.label"
default = true

[[setting]]
key = "show_codex"
type = "bool"
label_key = "settings.show_codex.label"
default = true

[[setting]]
key = "show_agy"
type = "bool"
label_key = "settings.show_agy.label"
default = true

[[setting]]
key = "show_cursor"
type = "bool"
label_key = "settings.show_cursor.label"
default = true
```

**Step 4: Run test to verify it passes**
Run: `./run-tests && noctalia plugins lint .`
Expected: PASS, `0 failed`; lint clean.

**Step 5: Commit**
Run: `/git commit`

---

### Task 13: Service dispatches pollers per provider and skips unwatched credentials

**Requirement:** REQ-008, REQ-011, REQ-013
**Files:**
- Modify: `service.luau` (`saveSnapshot` ~line 70, `request` ~line 104, `pollSource` ~lines 131-172, `configure` ~line 296, `update` ~line 350)
- Test: `tests/service.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: niri-noctalia)
- Reviewers: business-logic-reviewer, security-reviewer, consequences-reviewer, test-reviewer

**Step 1: Write the failing test**
Append inside the first `describe` of `tests/service.test.luau`:
```lua
	it("never watches a source without a credential file and leaves it unpolled", function()
		local s = boot({ config = { show_agy = true, show_cursor = true } })
		s.call("update")
		for _, call in mock.calls(s.env, "noctalia.fileInfo") do
			assert.equal(call[1] ~= "", true)
		end
		assert.equal(sourceOf(s, "agy").error ~= "claude-login", true)
		assert.equal(sourceOf(s, "cursor").error ~= "claude-login", true)
		assert.equal(#requests(s), 2)
	end)
```
(Without a poller the new sources stay untouched; Tasks 15 and 16 give them one, which reports `agy-missing`/`cursor-sqlite` here since the mock has no commands.)

**Step 2: Run test to verify it fails**
Run: `./run-tests tests/service.test.luau`
Expected: FAIL, a `fileInfo("")` call is recorded and the sources carry `claude-login`.

**Step 3: Write minimal implementation**
In `service.luau`:
- `refresh()` calls `syncIdentity` only for Claude and then `pollSource`; no change needed there.
- `saveSnapshot`: replace `elseif key == "claude" or key == "grok" then` with `elseif key == "claude" or table.find(accounts.PROVIDERS, key) then`.
- `request`: add an optional body (a body makes it a POST):
```lua
-- headers is a local list; nothing in it is logged. An answer is dropped when a
-- newer request replaced it or the source's account changed meanwhile. A body
-- makes it a POST.
local function request(source: any, url: string, headers: { string }, parse: (any) -> any, body: string?)
```
  and the call `noctalia.http({ url = url, method = if body ~= nil then "POST" else "GET", headers = headers, body = body }, function(res)`.
- Replace `pollSource` with a `pollers` table plus a dispatcher (the Claude and Grok bodies are the current ones, moved):
```lua
-- provider -> function(source, state, nowMs) that starts one poll.
local pollers = {}

pollers.grok = function(source: any, current: any, t: number)
	local cred = creds.grokKey(decodeFile(accounts.credPath(source)))
	if not cred.ok then
		states[source.key] = poll.fail(current, cred.error, 0, t)
		return
	end
	request(source, grok.API_URL, {
		"Authorization: Bearer " .. cred.key,
		"X-XAI-Token-Auth: " .. grok.TOKEN_AUTH,
		"Accept: application/json",
	}, function(data)
		return grok.parseBilling(data, now())
	end)
end

pollers.claude = function(source: any, current: any, t: number)
	local cred = creds.claudeToken(decodeFile(accounts.credPath(source)), t)
	if not cred.ok then
		states[source.key] = poll.fail(current, cred.error, 0, t)
		return
	end
	local plan = cred.plan
	request(source, claude.API_URL, {
		"Authorization: Bearer " .. cred.token,
		"anthropic-beta: " .. claude.BETA,
		"User-Agent: " .. tostring(noctalia.getConfig("claude_user_agent") or ""),
		"Accept: application/json",
	}, function(data)
		return claude.parseUsage(data, plan, now())
	end)
end

local function pollSource(source: any): boolean
	local key = source.key
	-- Marked this tick (file change or swap): wait for a later tick, whoever asks.
	if pending[key] == tick then
		return false
	end
	local t = now()
	local current = stateOf(key)
	local poller = pollers[source.provider]
	if poller == nil or not poll.canRequest(current, t) then
		return false
	end
	poller(source, current, t)
	return true
end
```
- In `configure`, replace `watch(accounts.credPath(s))` with:
```lua
		local cred = accounts.credPath(s)
		if cred ~= "" then
			watch(cred)
		end
```
- In `update`, replace the credential loop body with:
```lua
	for _, s in sources do
		local cred = accounts.credPath(s)
		if cred ~= "" and changed(cred) and pending[s.key] == nil then
			pending[s.key] = tick
		end
	end
```

**Step 4: Run test to verify it passes**
Run: `./run-tests`
Expected: PASS, `0 failed`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 14: Service polls Codex

**Requirement:** REQ-001, REQ-002, REQ-011, REQ-013
**Files:**
- Modify: `service.luau` (requires at the top, new `pollers.codex` after `pollers.claude`)
- Test: `tests/service-providers.test.luau` (create)

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: niri-noctalia)
- Reviewers: business-logic-reviewer, security-reviewer, test-reviewer

**Step 1: Write the failing test**
`tests/service-providers.test.luau`:
```lua
local assert = require("./support/assert")
local runner = require("./support/runner")
local modules = require("./support/modules")
local mock = require("./support/noctalia_mock")
local h = require("./support/service_helpers")

local describe, it = runner.describe, runner.it

local DATA = "/mock/plugin-data"
local CODEX_URL = "https://chatgpt.com/backend-api/wham/usage"
local CODEX_AUTH = '{"auth_mode":"chatgpt","tokens":{"access_token":"SECRET-CODEX","account_id":"acct-1","refresh_token":"SECRET-REFRESH"}}'

-- No token may reach the published view or a log line.
local function assertNoSecret(s)
	local text = mock.json.encode(h.view(s))
	assert.equal(string.find(text, "SECRET", 1, true), nil)
	for _, call in mock.calls(s.env, "noctalia.log") do
		assert.equal(string.find(tostring(call[1]), "SECRET", 1, true), nil)
	end
end

describe("service codex", function()
	it("polls Codex with its token and account id and caches the windows", function()
		local s = h.boot({ config = { show_codex = true }, fs = { ["~/.codex/auth.json"] = CODEX_AUTH } })
		local i = h.requests(s, CODEX_URL)[1]
		assert.equal(mock.pendingHttp(s.env)[i].request.method, "GET")
		assert.equal(h.header(s, i, "Authorization"), "Authorization: Bearer SECRET-CODEX")
		assert.equal(h.header(s, i, "ChatGPT-Account-Id"), "ChatGPT-Account-Id: acct-1")
		assert.equal(h.header(s, i, "User-Agent"), "User-Agent: codex-cli")
		mock.respond(s.env, i, { ok = true, status = 200, body = modules.text("tests/fixtures/codex-usage.json") })
		local c = h.sourceOf(s, "codex")
		assert.equal(c.snapshot.windows[1].percent, 96)
		assert.equal(c.snapshot.plan, "plus")
		assert.equal(mock.json.decode(s.env.noctalia.readFile(DATA .. "/snapshots.json")).codex.plan, "plus")
		assertNoSecret(s)
	end)

	it("reports a missing login without a request and maps 401 to auth", function()
		local s = h.boot({ config = { show_codex = true } })
		assert.equal(h.sourceOf(s, "codex").error, "codex-login")
		assert.equal(#h.requests(s, CODEX_URL), 0)
		local t = h.boot({ config = { show_codex = true }, fs = { ["~/.codex/auth.json"] = CODEX_AUTH } })
		mock.respond(t.env, h.requests(t, CODEX_URL)[1], { ok = true, status = 401, body = "" })
		assert.equal(h.sourceOf(t, "codex").error, "auth")
		assertNoSecret(t)
	end)

	it("restores the cached Codex snapshot stale at boot", function()
		local cached = '{"byAccount":{},"codex":{"provider":"codex","plan":"plus","windows":[{"id":"session","percent":50}],"products":[],"fetchedAt":1}}'
		local s = h.boot({ config = { show_codex = true }, fs = { [DATA .. "/snapshots.json"] = cached } })
		local c = h.sourceOf(s, "codex")
		assert.equal(c.snapshot.windows[1].percent, 50)
		assert.equal(c.stale, true)
	end)
end)
```

**Step 2: Run test to verify it fails**
Run: `./run-tests tests/service-providers.test.luau`
Expected: FAIL, no request to `CODEX_URL` (`attempt to index nil`), since `pollers.codex` is missing.

**Step 3: Write minimal implementation**
Add `local codex = require("./lib/codex.luau")` to the requires (alphabetical). After `pollers.claude` add:
```lua
pollers.codex = function(source: any, current: any, t: number)
	local cred = creds.codexToken(decodeFile(accounts.credPath(source)))
	if not cred.ok then
		states[source.key] = poll.fail(current, cred.error, 0, t)
		return
	end
	local headers = {
		"Authorization: Bearer " .. cred.token,
		"User-Agent: " .. codex.USER_AGENT,
		"Accept: application/json",
	}
	if cred.accountId ~= "" then
		table.insert(headers, "ChatGPT-Account-Id: " .. cred.accountId)
	end
	request(source, codex.API_URL, headers, function(data)
		return codex.parseUsage(data, now())
	end)
end
```

**Step 4: Run test to verify it passes**
Run: `./run-tests`
Expected: PASS, `0 failed`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 15: Service polls Cursor (sqlite3 token, POST RPC)

**Requirement:** REQ-003, REQ-004, REQ-005, REQ-013
**Files:**
- Modify: `service.luau` (requires, new `command` helper after `request`, new `pollers.cursor`)
- Test: `tests/service-providers.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: niri-noctalia)
- Reviewers: business-logic-reviewer, security-reviewer, test-reviewer

**Step 1: Write the failing test**
Append to `tests/service-providers.test.luau`:
```lua
local DB = "/mock/home/.config/Cursor/User/globalStorage/state.vscdb"
local CURSOR_ARGV = "sqlite3 -readonly " .. DB .. " SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"
local CURSOR_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"

local function run(exitCode, stdout)
	return { exitCode = exitCode, stdout = stdout, stderr = "", timedOut = false, stdoutTruncated = false, stderrTruncated = false }
end

describe("service cursor", function()
	it("reads the token with sqlite3 and posts the usage RPC", function()
		local s = h.boot({ config = { show_cursor = true }, commands = { "sqlite3" }, async = { [CURSOR_ARGV] = run(0, "SECRET-CURSOR\n") } })
		for _, part in mock.calls(s.env, "noctalia.runAsync")[1][1] do
			assert.equal(string.find(part, "SECRET", 1, true), nil)
		end
		local i = h.requests(s, CURSOR_URL)[1]
		local req = mock.pendingHttp(s.env)[i].request
		assert.equal(req.method, "POST")
		assert.equal(req.body, "{}")
		assert.equal(h.header(s, i, "Authorization"), "Authorization: Bearer SECRET-CURSOR")
		assert.equal(h.header(s, i, "Connect-Protocol-Version"), "Connect-Protocol-Version: 1")
		mock.respond(s.env, i, { ok = true, status = 200, body = modules.text("tests/fixtures/cursor-usage.json") })
		local c = h.sourceOf(s, "cursor")
		assert.equal(c.snapshot.windows[1].periodType, "monthly")
		assert.equal(c.snapshot.products[1].name, "Auto")
		assertNoSecret(s)
	end)

	it("reports a missing sqlite3 or Cursor session without a request", function()
		local s = h.boot({ config = { show_cursor = true } })
		assert.equal(h.sourceOf(s, "cursor").error, "cursor-sqlite")
		assert.equal(#mock.calls(s.env, "noctalia.runAsync"), 0)
		local t = h.boot({ config = { show_cursor = true }, commands = { "sqlite3" }, async = { [CURSOR_ARGV] = run(1, "") } })
		assert.equal(h.sourceOf(t, "cursor").error, "cursor-login")
		assert.equal(#h.requests(t, CURSOR_URL), 0)
	end)
end)
```

**Step 2: Run test to verify it fails**
Run: `./run-tests tests/service-providers.test.luau`
Expected: FAIL, `cursor` source has error `""` instead of `cursor-sqlite` (no poller).

**Step 3: Write minimal implementation**
Add `local cursor = require("./lib/cursor.luau")` to the requires. After `request` add:
```lua
-- runAsync counterpart of request: the result is dropped when a newer poll or a
-- reset replaced it. stdout may hold a token, so it is never logged.
local function command(source: any, argv: { string }, done: (any) -> ())
	local key = source.key
	local id = (generation[key] or 0) + 1
	generation[key] = id
	states[key] = poll.begin(stateOf(key), now())
	noctalia.runAsync(argv, function(res)
		if generation[key] ~= id then
			return
		end
		done(res)
	end)
end
```
After `pollers.codex` add:
```lua
-- Token from Cursor's own state.vscdb (read-only); argv holds only the query.
pollers.cursor = function(source: any, current: any, t: number)
	if not noctalia.commandExists("sqlite3") then
		states[source.key] = poll.fail(current, "cursor-sqlite", 0, t)
		return
	end
	command(source, cursor.tokenArgv(noctalia.expandPath(cursor.DB_PATH)), function(res)
		local cred = cursor.tokenFrom(res)
		if not cred.ok then
			applyResult(source, cred.error, 0, nil)
			return
		end
		request(source, cursor.API_URL, {
			"Authorization: Bearer " .. cred.token,
			"Content-Type: application/json",
			"Connect-Protocol-Version: 1",
			"Accept: application/json",
		}, function(data)
			return cursor.parseUsage(data, now())
		end, "{}")
	end)
end
```

**Step 4: Run test to verify it passes**
Run: `./run-tests`
Expected: PASS, `0 failed`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 16: Service polls agy `/quota`

**Requirement:** REQ-006, REQ-007, REQ-013
**Files:**
- Modify: `service.luau` (requires, new `pollers.agy`)
- Test: `tests/service-providers.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: niri-noctalia)
- Reviewers: business-logic-reviewer, security-reviewer, test-reviewer

**Step 1: Write the failing test**
Append to `tests/service-providers.test.luau`:
```lua
local AGY_ARGV = "agy -p /quota --output-format json"
local AGY_BODY = modules.text("tests/fixtures/agy-quota.json")

describe("service agy", function()
	it("runs agy /quota without HTTP and publishes one window per bucket", function()
		local s = h.boot({ config = { show_agy = true }, commands = { "agy" }, async = { [AGY_ARGV] = run(0, AGY_BODY) } })
		local a = h.sourceOf(s, "agy")
		assert.equal(#a.snapshot.windows, 5)
		assert.equal(a.snapshot.windows[5].percent, 100)
		assert.equal(a.error, "")
		assert.equal(#mock.pendingHttp(s.env), 2) -- Claude and Grok only
		assert.equal(mock.json.decode(s.env.noctalia.readFile(DATA .. "/snapshots.json")).agy.primary, "max")
	end)

	it("backs off after a failed run and reports a missing agy", function()
		local s = h.boot({ config = { show_agy = true }, commands = { "agy" }, async = { [AGY_ARGV] = run(3, "") } })
		local a = h.sourceOf(s, "agy")
		assert.equal(a.error, "agy-login")
		assert.equal(a.retryAt, h.NOW + 5 * 60000)
		s.env.noctalia.state.set("cmd.refresh", 1)
		assert.equal(#mock.calls(s.env, "noctalia.runAsync"), 1)
		local t = h.boot({ config = { show_agy = true } })
		assert.equal(h.sourceOf(t, "agy").error, "agy-missing")
	end)

	it("treats unreadable output as a failed run", function()
		local s = h.boot({ config = { show_agy = true }, commands = { "agy" }, async = { [AGY_ARGV] = run(0, "not json") } })
		assert.equal(h.sourceOf(s, "agy").error, "agy-login")
	end)
end)
```

**Step 2: Run test to verify it fails**
Run: `./run-tests tests/service-providers.test.luau`
Expected: FAIL, `agy` snapshot is nil (no poller).

**Step 3: Write minimal implementation**
Add `local agy = require("./lib/agy.luau")` to the requires. After `pollers.cursor` add:
```lua
-- agy prints its own Models & Quota summary: no token, no model turn.
pollers.agy = function(source: any, current: any, t: number)
	if not noctalia.commandExists("agy") then
		states[source.key] = poll.fail(current, "agy-missing", 0, t)
		return
	end
	command(source, agy.ARGV, function(res)
		if typeof(res) ~= "table" or res.exitCode ~= 0 then
			applyResult(source, "agy-login", 0, nil)
			return
		end
		local decoded, data = pcall(noctalia.json.decode, res.stdout or "")
		local parsed = agy.parseQuota(if decoded then data else nil, now())
		if not parsed.ok then
			applyResult(source, parsed.error, 0, nil)
			return
		end
		applyResult(source, "", 0, parsed.snapshot)
	end)
end
```

**Step 4: Run test to verify it passes**
Run: `./run-tests`
Expected: PASS, `0 failed`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 17: Notifications name the window's group

**Requirement:** REQ-011
**Files:**
- Modify: `service.luau` (`fireNotifications` ~line 47)
- Test: `tests/service-providers.test.luau`

**Team:**
- Track: backend
- Implementer: backend-engineer (skills: niri-noctalia)
- Reviewers: business-logic-reviewer, test-reviewer

**Step 1: Write the failing test**
Append inside `describe("service agy", ...)`:
```lua
	it("names the agy group in a threshold notification", function()
		local s = h.boot({ config = { show_agy = true, notify_threshold = 97 }, commands = { "agy" }, async = { [AGY_ARGV] = run(0, AGY_BODY) } })
		local n = mock.calls(s.env, "noctalia.notify")
		assert.equal(#n, 1)
		assert.equal(n[1][1], "notify.title n=100 provider=provider.agy window=Gemini 4 Argon · window.weekly")
	end)
```

**Step 2: Run test to verify it fails**
Run: `./run-tests tests/service-providers.test.luau`
Expected: FAIL, title ends with `window=window.weekly`.

**Step 3: Write minimal implementation**
In `fireNotifications`, replace `window = tr(format.windowKey(item))` with `window = format.windowLabel(item, tr)`.

**Step 4: Run test to verify it passes**
Run: `./run-tests`
Expected: PASS, `0 failed`.

**Step 5: Commit**
Run: `/git commit`

---

### Task 18: Docs for five providers

**Requirement:** REQ-014
**Files:**
- Modify: `CLAUDE.md` (Status, What it is, Architecture module list and window ids, Endpoints table)
- Modify: `README.md`
- Modify: `docs/SMOKE.md`
- Test: none (docs); the suite and lint must stay green.

**Team:**
- Track: docs
- Implementer: rpi-implementer
- Reviewers: self-review (no panel)

**Step 1: Write the change list (no failing test for docs)**
- `CLAUDE.md`:
  - Status: version `0.3.0`; add `Spec: docs/specs/multi-provider-tabs/SPEC.md` and `Plan: docs/plans/2026-10-27-multi-provider-tabs.md`.
  - What it is: "Claude Code, Grok, Codex, Antigravity (`agy`) and Cursor plan usage ... and in a panel with one tab per provider."
  - Architecture: modules list adds `codex`, `cursor`, `agy`; window ids add Codex `session`/`weekly` (extra limits `extra<i>:<span>` with `group`/`span`), Cursor `period` monthly, agy bucket ids with `group`/`span` and `snapshot.primary = "max"`; the service dispatches through `pollers`; `command()` is the `runAsync` counterpart of `request()`.
  - Endpoints table adds:
    | Codex | `GET https://chatgpt.com/backend-api/wham/usage`, headers `Authorization: Bearer`, `ChatGPT-Account-Id`, `User-Agent: codex-cli` | `~/.codex/auth.json` → `tokens.access_token`, `tokens.account_id` |
    | Cursor | `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`, body `{}`, `Authorization: Bearer`, `Connect-Protocol-Version: 1` | `sqlite3 -readonly ~/.config/Cursor/User/globalStorage/state.vscdb` → `cursorAuth/accessToken` |
    | Agy | `agy -p "/quota" --output-format json` (no HTTP, no model turn) | none: agy authenticates itself |
  - Hard constraints: "argv never holds a token; `runAsync` stdout is never logged".
- `README.md`: provider list, the four `show_*` settings, `bar_provider` values, requirements (`sqlite3` for Cursor, `agy` on PATH), a note that agy's figures are those of its own Models & Quota page.
- `docs/SMOKE.md`: add steps: five tabs in order; Codex 5h + weekly match `codex` `/status`; Cursor monthly cycle; Agy groups and percentages match `agy` → `/quota`; turn `show_cursor` off → tab and middle-click entry disappear; `noctalia.http` POST with a body reaches Cursor (200, not 4xx).

**Step 2: Verify nothing else broke**
Run: `./run-tests && noctalia plugins lint . && grep -rn "/home/" CLAUDE.md README.md docs/SMOKE.md`
Expected: `0 failed`, lint clean, grep prints nothing.

**Step 3: Apply the edits listed in Step 1.**

**Step 4: Re-run the Step 2 command.**
Expected: same as Step 2.

**Step 5: Commit**
Run: `/git commit`

---

## Notes for the implementer

- **Codex window classification** (Task 5) refines REQ-002: a window is `session` when it lasts ≤ 6 h and `weekly` when ≥ 6 d, else by position (primary/secondary). Free plans send the weekly window as `primary_window` (ai-usagebar's weekly-only format); mapping by position alone would mislabel it as the 5 h session.
- **Cursor fixture** (Task 6) keeps the real shape but raises three percentages from 0 so the mapping is tested; say so if `CLAUDE.md`'s "fixtures are real responses" line is updated in Task 18.
- **`noctalia.http` POST with `body`** is not exercised by any existing plugin here; the mock accepts it, the host binary names `body`/`method` fields. Task 18's smoke step confirms it on the desktop.
- **Agy cost:** each `/quota` run takes 4 to 6 s; it runs once per `poll_minutes` (default 5) and on refresh, and a failure backs off 5 min (Task 2).
- **Out of scope** (spec): Claude `limits[]` scoped weekly caps, banked resets, Cursor credit grants, other ai-usagebar vendors.
