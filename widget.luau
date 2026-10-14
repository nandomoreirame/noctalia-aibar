-- AI Bar widget: the bar source chosen by the service (a Claude account or
-- Grok): glyph, "47% · 1h12m" and a short progress bar. Renders only from the
-- service's `view`; middle click asks the service to cycle the source.

local present = require("./lib/present.luau")

local PANEL = "nandomoreirame/aibar:panel"

local function tr(key: string, vars: any?): string
	if vars then
		return noctalia.tr(key, vars)
	end
	return noctalia.tr(key)
end

local function render(v: any)
	local m = present.bar(v, tr)
	local glyph = ui.glyph({ name = m.glyph })
	local progress = ui.progress({ progress = m.fraction, fill = m.fill, track = "on_surface/0.15", width = 40, height = 4, radius = 2 })
	if barWidget.isVertical() then
		barWidget.render(ui.column({ gap = 2, align = "center" }, { glyph, progress }))
	else
		barWidget.render(ui.row({ gap = 6, align = "center" }, {
			glyph,
			ui.label({ text = m.label, opacity = if m.stale then 0.6 else 1 }),
			progress,
		}))
	end
	if #m.tooltip > 0 then
		barWidget.setTooltip(m.tooltip)
	else
		barWidget.clearTooltip()
	end
end

function onClick()
	noctalia.togglePanel(PANEL)
end

function onMiddleClick()
	noctalia.state.set("cmd.cycle", (tonumber(noctalia.state.get("cmd.cycle")) or 0) + 1)
end

noctalia.state.watch("view", render)
render(noctalia.state.get("view"))
