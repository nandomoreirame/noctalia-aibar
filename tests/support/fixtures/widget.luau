--!strict
-- Tiny bar-widget entry used by entry.test.luau.
-- Host globals (barWidget, noctalia) come from the mock env via entry.load.

function update()
	local title = noctalia.getConfig("title")
	barWidget.setText(tostring(title))
end

function onClick()
	noctalia.notify("clicked", "widget")
end

function onIpc(action: string, _payload: any)
	noctalia.log("ipc:" .. action)
end
