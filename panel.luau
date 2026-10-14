-- AI Bar panel: one card per provider; Claude accounts share one card with a
-- tab row. Renders only from the service's `view`.

local present = require("./lib/present.luau")

local isOpen = false
local claudeTab = 1
local current = nil

local tr = present.translator(function(...)
	return noctalia.tr(...)
end)

local function usageRow(row: any): any
	local children = {
		ui.row({ align = "center", gap = 8 }, {
			ui.label({ text = row.label, fontSize = 12, flexGrow = 1 }),
			ui.label({ text = row.percentText, fontSize = 12, fontWeight = "bold" }),
		}),
		ui.progress({ progress = row.fraction, fill = row.fill, track = "on_surface/0.15", height = 6, radius = 3 }),
	}
	if row.detail ~= "" then
		table.insert(children, ui.label({ text = row.detail, fontSize = 11, color = "on_surface_variant" }))
	end
	return ui.column({ gap = 4 }, children)
end

local function note(text: string, color: string): any
	return ui.label({ text = text, fontSize = 11, color = color })
end

local function card(c: any, tabs: any): any
	local header = {
		ui.glyph({ name = c.glyph, size = 16 }),
		ui.label({ text = c.title, fontSize = 14, fontWeight = "bold" }),
	}
	if c.plan ~= "" then
		table.insert(header, ui.label({ text = c.plan, fontSize = 12, color = "on_surface_variant" }))
	end
	table.insert(header, ui.spacer({ flexGrow = 1 }))
	if c.updated ~= "" then
		table.insert(header, ui.label({ text = c.updated, fontSize = 10, color = "on_surface_variant" }))
	end
	if c.badge then
		table.insert(header, ui.box({ fill = c.badge.color .. "/0.18", radius = 8 }, {
			ui.label({ text = c.badge.text, fontSize = 10, color = c.badge.color }),
		}))
	end
	local body = { ui.row({ align = "center", gap = 8 }, header) }
	if c.email ~= "" or #tabs > 0 then
		local line = { ui.label({ text = c.email, fontSize = 10, color = "on_surface_variant", flexGrow = 1 }) }
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
		table.insert(body, ui.row({ align = "center", gap = 4 }, line))
	end
	if c.empty ~= "" then
		table.insert(body, note(c.empty, "on_surface_variant"))
	end
	for _, row in c.rows do
		table.insert(body, usageRow(row))
	end
	if c.extra then
		table.insert(body, usageRow(c.extra))
	end
	for _, p in c.products do
		table.insert(body, ui.row({ gap = 8 }, {
			ui.label({ text = p.name, fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
			ui.label({ text = p.percentText, fontSize = 11, color = "on_surface_variant" }),
		}))
	end
	if c.limit ~= "" then
		table.insert(body, note(c.limit, "error"))
	end
	if c.error ~= "" then
		table.insert(body, note(c.error, "error"))
	end
	return ui.column({ key = "card-" .. c.key, gap = 8, padding = 12, radius = 12, fill = "surface_variant" }, body)
end

function render()
	if not isOpen then
		return
	end
	local m = present.panel(current, claudeTab, tr)
	local cards = {}
	if m.claude then
		table.insert(cards, card(m.claude, m.tabs))
	end
	for _, c in m.others do
		table.insert(cards, card(c, {}))
	end
	panel.render(ui.column({ gap = 10, padding = 10 }, {
		ui.row({ align = "center", gap = 8 }, {
			ui.label({ text = m.title, fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
			ui.button({ glyph = "refresh", variant = "ghost", tooltip = m.refresh, enabled = not m.busy, onClick = onRefresh }),
		}),
		ui.scroll({ flexGrow = 1, gap = 10 }, cards),
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
