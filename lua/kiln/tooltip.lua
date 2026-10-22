
local ui = require("kiln.ui")
local state = require("kiln.state")

local tooltip = {}
local services=require("kiln.desktop_services")

tooltip.open = nil

function tooltip.hide()
	if tooltip.open == nil then
		return
	end
	core.dirty(tooltip.open.screen.name)
	tooltip.open = nil
end

local function screen_named(name)
	for _, s in ipairs(screen.all()) do
		if s.name == name then
			return s
		end
	end
end

function tooltip.attach(text)
	return function(over, hit)
		if not over or hit == nil then
			return tooltip.hide()
		end
		local key = hit.screen .. ":" .. hit.name .. "#" .. hit.index
		if tooltip.open ~= nil and tooltip.open.key == key then
			return
		end
		local s = screen_named(hit.screen) or screen.all()[1]
		if not services.live(s) then
			return
		end
        tooltip.hide()
		tooltip.open = {
			screen = s, key = key, text = text,
			under = hit.index ~= 0 and { hit.name, hit.index } or hit.name,
		}
		core.dirty(s.name)
	end
end

function tooltip.declare(s)
	local t = tooltip.open
	if t == nil or t.screen ~= s then
		return
	end
    if not core._declared(t.under) then tooltip.hide(); return end
	local th = state.theme
	ui.box({
		id = "tooltip",
		float = {
			to = "element", parent = t.under, band = "overlay", fit = true,
			anchor = { parent = "center_bottom", element = "center_top" },
			offset = { x = 0, y = th.tooltip_gap },
			passthrough = true,
		},
		color = th.bg, radius = 4, pad = { x = 6, y = 3 },
		border = { width = 1, color = th.muted },
	}, function()
		ui.text(type(t.text) == "function" and t.text() or t.text, { size = 12 })
	end)
end

return tooltip
