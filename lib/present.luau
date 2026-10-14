-- View -> display models for the bar widget and the panel. Pure: every string
-- comes from the tr(key, vars?) function the entry passes in.

local format = require("./format.luau")
local pace = require("./pace.luau")

local Present = {}

local FILL = { ok = "primary", ahead = "tertiary", critical = "error" }

local function glyphOf(provider: string): string
	return if provider == "grok" then "brand-x" else "asterisk"
end

local function fraction(p: any): number
	if typeof(p) ~= "number" then
		return 0
	end
	return math.clamp(p, 0, 100) / 100
end

function Present.find(view: any, key: string): any
	if not view or not view.sources then
		return nil
	end
	for _, s in view.sources do
		if s.key == key then
			return s
		end
	end
	return nil
end

-- "Claude Code", "Claude Code · Trabalho" or "Grok".
function Present.sourceName(source: any, tr: any): string
	local base = tr("provider." .. source.provider)
	if source.name ~= nil and source.name ~= "" then
		return base .. " · " .. source.name
	end
	return base
end

function Present.errorText(entry: any, nowMs: number, tr: any): string
	local quiet = entry.frozen or pace.exhausted(entry.snapshot, nowMs) ~= nil
	local msg = format.errorMessage(entry, entry.provider, nowMs, quiet)
	if not msg then
		return ""
	end
	return tr(msg.key, msg.vars)
end

local function claudeCount(view: any): number
	local n = 0
	for _, s in view.sources do
		if s.provider == "claude" then
			n += 1
		end
	end
	return n
end

function Present.bar(view: any, tr: any)
	local entry = if view then Present.find(view, view.barKey) else nil
	if not entry then
		return { glyph = "asterisk", label = "—", fraction = 0, fill = "primary", stale = false, tooltip = {} }
	end
	local now = view.now or 0
	local snap = entry.snapshot
	local rows = {}
	if claudeCount(view) > 1 then
		table.insert(rows, { Present.sourceName(entry, tr), "" })
	end
	for _, w in (if snap then snap.windows else {}) do
		local value = format.percentText(w.percent)
		local reset = format.countdown(w.endMs, now)
		if reset ~= "" then
			value ..= " · " .. tr("panel.resets", { t = reset })
		end
		table.insert(rows, { tr(format.windowKey(w)), value })
	end
	local limit = format.limitMessage(pace.exhausted(snap, now), now)
	if limit then
		table.insert(rows, { tr(limit.key, limit.vars), "" })
	end
	local err = Present.errorText(entry, now, tr)
	if err ~= "" then
		table.insert(rows, { err, "" })
	end
	local w = pace.primaryWindow(snap)
	return {
		glyph = glyphOf(entry.provider),
		label = format.barText(w, now),
		fraction = fraction(if w then w.percent else nil),
		fill = FILL[pace.status(w, now)],
		stale = entry.stale,
		tooltip = rows,
	}
end

local function detailLine(w: any, nowMs: number, tr: any): string
	local reset = format.countdown(w.endMs, nowMs)
	local resets = if reset ~= "" then tr("panel.resets", { t = reset }) else ""
	local p = pace.pace(w, nowMs)
	local paceText = ""
	if p.delta ~= nil then
		local points = math.abs(p.delta)
		if points <= 2 then
			paceText = tr("pace.on")
		elseif p.delta > 0 then
			paceText = tr("pace.ahead", { n = points })
		else
			paceText = tr("pace.behind", { n = points })
		end
	end
	if resets ~= "" and paceText ~= "" then
		return resets .. " · " .. paceText
	end
	return if resets ~= "" then resets else paceText
end

function Present.card(entry: any, nowMs: number, tr: any)
	local snap = entry.snapshot
	local card = {
		key = entry.key,
		glyph = glyphOf(entry.provider),
		title = tr("provider." .. entry.provider),
		plan = "",
		email = entry.email or "",
		updated = "",
		badge = nil,
		rows = {},
		extra = nil,
		products = {},
		limit = "",
		error = Present.errorText(entry, nowMs, tr),
		empty = "",
	}
	if entry.frozen then
		card.badge = { text = tr("panel.frozen"), color = "primary" }
	elseif entry.stale then
		card.badge = { text = tr("panel.stale"), color = "error" }
	end
	if not snap then
		if card.error == "" then
			card.empty = tr("panel.no-data")
		end
		return card
	end
	if entry.provider == "claude" and typeof(snap.plan) == "string" and snap.plan ~= "" then
		card.plan = string.upper(string.sub(snap.plan, 1, 1)) .. string.sub(snap.plan, 2)
	end
	-- A frozen account's last status is the point, so its age stays visible.
	if entry.frozen or not entry.stale then
		if format.minutesAgo(snap.fetchedAt, nowMs) == 0 then
			card.updated = tr("panel.updated-now")
		else
			card.updated = tr("panel.updated", { t = format.ago(snap.fetchedAt, nowMs) })
		end
	end
	for _, w in snap.windows or {} do
		table.insert(card.rows, {
			label = tr(format.windowKey(w)),
			percentText = format.percentText(w.percent),
			fraction = fraction(w.percent),
			fill = FILL[pace.status(w, nowMs)],
			detail = detailLine(w, nowMs, tr),
		})
	end
	if snap.extra then
		card.extra = {
			label = tr("window.extra"),
			percentText = format.percentText(snap.extra.percent),
			fraction = fraction(snap.extra.percent),
			fill = if snap.extra.percent >= pace.CRITICAL then "error" else "primary",
			detail = format.moneyText(snap.extra, tr("format.decimal")),
		}
	end
	if entry.provider == "grok" then
		for _, p in snap.products or {} do
			table.insert(card.products, { name = p.name, percentText = format.percentText(p.percent) })
		end
	end
	local limit = format.limitMessage(pace.exhausted(snap, nowMs), nowMs)
	if limit then
		card.limit = tr(limit.key, limit.vars)
	end
	return card
end

-- claudeTab: 1-based index of the Claude account shown in the shared card.
function Present.panel(view: any, claudeTab: number, tr: any)
	local model = { title = tr("panel.title"), refresh = tr("panel.refresh"), busy = false, tabs = {}, claude = nil, others = {} }
	if not view or not view.sources then
		return model
	end
	local now = view.now or 0
	local claudes = {}
	for _, s in view.sources do
		if s.inFlight then
			model.busy = true
		end
		if s.provider == "claude" then
			table.insert(claudes, s)
		else
			table.insert(model.others, Present.card(s, now, tr))
		end
	end
	if #claudes > 0 then
		local index = math.clamp(claudeTab, 1, #claudes)
		model.claude = Present.card(claudes[index], now, tr)
		if #claudes > 1 then
			for i, s in claudes do
				table.insert(model.tabs, { label = if s.frozen then s.name else tr("panel.active"), selected = i == index })
			end
		end
	end
	return model
end

return Present
