-- The tooltip: a float box declared off the hovered element,
-- and nothing at all when nothing is hovered. There is no tooltip object, no
-- popup surface, and no timer: Clay attaches the box to the element by id, so the
-- module holds one table and does no geometry.
--
-- It lives beside menu.lua for the same reason the menu does: it owns cross-frame
-- state and a declare hook the runtime calls, and ui.lua is the element layer.
-- The public name is ui.tooltip (init.lua binds it), because ui.lua cannot require
-- this module without a cycle.

local ui = require("kiln.ui")
local state = require("kiln.state")

local tooltip = {}

-- The one shown tooltip: nil is closed. `key` is the hit it was raised from, so
-- re-hovering the same element every motion is a no-op instead of a dirty mark
-- per frame (the menu's navigate() guards the same way).
tooltip.open = nil

function tooltip.hide()
	if tooltip.open == nil then
		return
	end
	core.dirty(tooltip.open.screen.name)
	tooltip.open = nil
end

-- The screen the hovered element is on, which init.lua carries on the hit. NOT
-- screen.focused: hovering chrome does not focus a screen, and a tooltip declared
-- on the wrong screen's tree could not attach to its element at all (attach
-- targets must live in the same tree).
local function screen_named(name)
	for _, s in ipairs(state.screens) do
		if s.name == name then
			return s
		end
	end
end

-- ui.tooltip(text): the on_hover handler for the element it describes, and the
-- whole public API. The handler is told which element it fired on and on which
-- screen (init.lua carries both on the hit), so the config repeats no id, and an
-- element with an auto id gets a tooltip too. text is a string or a function read
-- at declare, which is what makes a live tooltip need no update path.
function tooltip.attach(text)
	return function(over, hit)
		if not over or hit == nil then
			return tooltip.hide()
		end
		-- Re-hovering the element already shown is a no-op, not a re-raise: this
		-- fires on every motion, and dirtying per motion would re-declare the
		-- screen for a box that did not change (the menu's navigate() guards the
		-- same way, for the same reason).
		local key = hit.name .. "#" .. hit.index
		if tooltip.open ~= nil and tooltip.open.key == key then
			return
		end
		local s = screen_named(hit.screen) or state.screens[1]
		if s == nil then
			return
		end
		tooltip.open = {
			screen = s, key = key, text = text,
			under = hit.index ~= 0 and { hit.name, hit.index } or hit.name,
		}
		core.dirty(s.name)
	end
end

-- Called by the runtime inside each screen's declare, after the menu.
function tooltip.declare(s)
	local t = tooltip.open
	if t == nil or t.screen ~= s then
		return
	end
	local th = state.theme
	-- It hangs under its target and says so once. Clay does not flip a float,
	-- so a tooltip under a bottom-bar widget would run off the screen; `fit`
	-- is what mirrors the pair and the offset when it would, and slides it
	-- back inside the workarea when no mirror can help. The fit flips only
	-- when the box actually leaves the workarea, never on a guess about where
	-- the target sits, and covers both axes.
	ui.box({
		id = "tooltip",
		float = {
			to = "element", parent = t.under, band = "overlay", fit = true,
			anchor = { parent = "center_bottom", element = "center_top" },
			offset = { x = 0, y = th.tooltip_gap },
			-- A capturing tooltip would swallow the press on the very widget it
			-- describes; it is a label, not a target.
			passthrough = true,
		},
		color = th.bg, radius = 4, pad = { x = 6, y = 3 },
		border = { width = 1, color = th.muted },
	}, function()
		ui.text(type(t.text) == "function" and t.text() or t.text, { size = 12 })
	end)
end

return tooltip
