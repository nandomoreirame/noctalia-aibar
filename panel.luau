-- AI Bar panel: one section per provider, one card per usage window; Claude
-- accounts share one section with a tab row. Renders only from the service's
-- `view`. The host already pads the panel, so the root adds no padding.

local present = require("./lib/present.luau")

local isOpen = false
local claudeTab = 1
local current = nil

local tr = present.translator(function(...)
	return noctalia.tr(...)
end)

local function muted(text: string, size: number?): any
	return ui.label({ text = text, fontSize = size or 12, color = "on_surface_variant" })
end

local function card(key: string, children: any): any
	return ui.column({ key = key, gap = 8, padding = 14, radius = 12, fill = "surface_variant/0.45", align = "stretch" }, children)
end

local function note(text: string, color: string): any
	return ui.label({ text = text, fontSize = 12, color = color, maxLines = 3 })
end

-- Usage bar over a thin time-elapsed bar: a fill longer than the clock bar is
-- quota burning ahead of time.
local function windowCard(key: string, row: any, footer: any): any
	local children = {
		ui.row({ align = "center", justify = "space_between" }, {
			ui.label({ text = row.label, fontSize = 14, fontWeight = "medium" }),
			ui.label({ text = row.percentText, fontSize = 14, fontWeight = "bold", color = row.fill }),
		}),
		ui.progress({ progress = row.fraction, fill = row.fill, track = "on_surface/0.14", height = 8, radius = 4 }),
	}
	if row.elapsed ~= nil then
		table.insert(children, ui.progress({ progress = row.elapsed, fill = "on_surface/0.45", track = "on_surface/0.10", height = 3, radius = 2 }))
	end
	if row.detail ~= "" then
		table.insert(children, muted(row.detail, 11))
	end
	for _, node in footer do
		table.insert(children, node)
	end
	return card(key, children)
end

local function sectionHeader(c: any, tabs: any): any
	local title = {
		ui.glyph({ name = c.glyph, size = 16, color = "primary" }),
		ui.label({ text = c.title, fontSize = 14, fontWeight = "bold" }),
	}
	if c.plan ~= "" then
		table.insert(title, muted(c.plan, 12))
	end
	table.insert(title, ui.spacer({ flexGrow = 1 }))
	if c.badge then
		table.insert(title, ui.box({ fill = c.badge.color .. "/0.18", radius = 8, paddingH = 6 }, {
			ui.label({ text = c.badge.text, fontSize = 10, color = c.badge.color }),
		}))
	elseif c.updated ~= "" then
		table.insert(title, muted(c.updated, 11))
	end
	local rows = { ui.row({ align = "center", gap = 8 }, title) }
	if c.email ~= "" or #tabs > 0 then
		local line = { ui.label({ text = c.email, fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }) }
		for i, tab in tabs do
			table.insert(line, ui.button({
				key = "tab-" .. i,
				text = tab.label,
				variant = "ghost",
				controlSize = "sm",
				selected = tab.selected,
				onClick = function()
					claudeTab = i
					render()
				end,
			}))
		end
		table.insert(rows, ui.row({ align = "center", gap = 4 }, line))
	end
	return ui.column({ gap = 2, paddingH = 2, align = "stretch" }, rows)
end

local function section(c: any, tabs: any): any
	local products = {}
	for _, p in c.products do
		table.insert(products, ui.row({ align = "center", justify = "space_between" }, {
			muted(p.name, 12),
			muted(p.percentText, 12),
		}))
	end
	local windows = {}
	for _, row in c.rows do
		table.insert(windows, row)
	end
	if c.extra then
		table.insert(windows, c.extra)
	end
	-- Grok products share the billing period, and the limit and error notes are
	-- about the same source, so all of them close the last window card: a card of
	-- their own would push the panel past its fixed height.
	local footer = products
	if c.empty ~= "" then
		table.insert(footer, note(c.empty, "on_surface_variant"))
	end
	if c.limit ~= "" then
		table.insert(footer, note(c.limit, "error"))
	end
	if c.error ~= "" then
		table.insert(footer, note(c.error, "error"))
	end
	local children = { sectionHeader(c, tabs) }
	for i, row in windows do
		table.insert(children, windowCard("window-" .. c.key .. "-" .. i, row, if i == #windows then footer else {}))
	end
	if #windows == 0 and #footer > 0 then
		table.insert(children, card("notes-" .. c.key, footer))
	end
	return ui.column({ key = "section-" .. c.key, gap = 8, align = "stretch" }, children)
end

local function header(m: any): any
	return ui.row({ align = "center", gap = 10 }, {
		ui.glyph({ name = "chart-bar", size = 22, color = "primary" }),
		ui.label({ text = m.title, fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
		ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = m.refresh, enabled = not m.busy, onClick = onRefresh }),
		ui.button({
			glyph = "settings",
			variant = "ghost",
			controlSize = "sm",
			tooltip = tr("panel.settings"),
			onClick = function()
				noctalia.openSettings()
			end,
		}),
		ui.button({
			glyph = "x",
			variant = "ghost",
			controlSize = "sm",
			tooltip = tr("panel.close"),
			onClick = function()
				panel.close()
			end,
		}),
	})
end

function render()
	if not isOpen then
		return
	end
	local m = present.panel(current, claudeTab, tr)
	local sections = {}
	if m.claude then
		table.insert(sections, section(m.claude, m.tabs))
	end
	for _, c in m.others do
		table.insert(sections, section(c, {}))
	end
	panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
		header(m),
		ui.scroll({ flexGrow = 1, gap = 16, align = "stretch" }, sections),
	}))
end

function onRefresh()
	noctalia.state.set("cmd.refresh", present.bump(noctalia.state.get("cmd.refresh")))
end

-- The panel opens on the active account, like v4.
function onOpen(_context: any)
	isOpen = true
	claudeTab = 1
	render()
end

function onClose()
	isOpen = false
end

noctalia.state.watch("view", function(v)
	current = v
	render()
end)
current = noctalia.state.get("view")
