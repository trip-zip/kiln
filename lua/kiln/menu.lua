-- The menu: a float column of pressable rows, and a submenu is
-- the same thing floated off the row that opened it. There is no menu widget
-- object, no geometry code, and no popup surface: a menu is chrome in the
-- screen's one Clay context, declared while it is open and simply not declared
-- when it is not.
--
-- It lives beside prompt.lua rather than inside ui.lua for the same reason the
-- prompt does: it owns cross-frame state and a declare hook the runtime calls,
-- and ui.lua is the element layer. The public name is still ui.menu (init.lua
-- binds it), because ui.lua cannot require this module without a cycle.

local ui = require("kiln.ui")
local state = require("kiln.state")
local grab = require("kiln.grab")
-- icon.lua requires nothing, so this cannot cycle back into menu.
local icon = require("kiln.icon")

local menu = {}

-- The one open menu, as its chain of levels: the root, then one level per open
-- submenu, deepest last. A chain, not a tree, because only the open path is
-- ever declared, and truncating the list IS closing a submenu.
menu.open = nil

-- The keyboard claim an open chain holds, or nil. Forward declared with
-- the handler it runs, which is written beside the nav verbs it drives.
menu.claim = nil
local on_key

local function dirty()
	if menu.open ~= nil then
		core.dirty(menu.open.screen.name)
	end
end

-- Give the keyboard back. The field is cleared BEFORE the stop, so the
-- grabber's own stopped callback finds no claim of ours and does not come back
-- around through close.
local function release()
	local c = menu.claim
	if c == nil then
		return
	end
	menu.claim = nil
	c:stop()
end

function menu.close()
	if menu.open == nil then
		return
	end
	dirty()
	menu.open = nil
	release()
end

-- Open a menu on a screen, at a point (x, y) or under an element id (`under`,
-- the usual case: the bar button that opened it). Items are { name, action } or
-- { name, { subitems } }.
function menu.show(cfg)
	local s = cfg.screen or screen.focused or state.screens[1]
	if s == nil or cfg.items == nil then
		return
	end
	menu.open = {
		screen = s,
		levels = { {
			items = cfg.items, depth = 1, path = "",
			x = cfg.x or 0, y = cfg.y or 0, under = cfg.under,
		} },
	}
	-- The keygrabber IS the chain's lifetime, the way it is the prompt's. One
	-- claim per device with no stack (grab.lua), so an open menu outranks every
	-- binding, and a key the map does not know is consumed rather than leaking
	-- to a binding under the menu: a grab is a claim on the device, not a
	-- filter on some of its events. Our own previous claim goes first and by
	-- hand, because letting the grabber stop it would run its stopped callback
	-- against the chain that just replaced it.
	release()
	local c
	c = grab.keygrabber {
		key = function(ev) on_key(ev) end,
		stopped = function()
			-- Something else took the keyboard (a prompt, a config's grabber,
			-- the reload reset). A menu that cannot be driven is not the menu
			-- this opened, so the chain goes with the claim.
			if menu.claim == c then
				menu.claim = nil
				menu.close()
			end
		end,
	}
	menu.claim = c
	dirty()
	return menu.open
end

-- Closing a submenu is dropping the levels under it. Nothing else: the chain IS
-- the open state, so there is no visibility flag to clear and nothing to hide.
local function truncate(depth)
	local levels = menu.open.levels
	if levels[depth + 1] == nil then
		return false
	end
	for i = #levels, depth + 1, -1 do
		levels[i] = nil
	end
	return true
end

-- Navigate to a row: a submenu row opens its submenu, any other row closes
-- whatever the level below was showing. Re-entering the level already open is a
-- no-op, which is what keeps hover from re-declaring it forever.
local function navigate(lv, path, id, items)
	local levels = menu.open.levels
	if items ~= nil and levels[lv.depth + 1] ~= nil
			and levels[lv.depth + 1].path == path then
		return
	end
	local changed = truncate(lv.depth)
	if items ~= nil then
		table.insert(levels, {
			items = items, depth = lv.depth + 1, path = path, under = id,
		})
		changed = true
	end
	if changed then
		dirty()
	end
end

-- The hovered row, one field on the level that already carries the open chain.
-- A highlight needs to survive the pointer crossing from one row to the next,
-- and the two edges arrive in no guaranteed order, so the leave edge clears
-- only when the row leaving is still the one recorded.
local function set_hover(lv, path)
	if lv.hover == path then
		return
	end
	lv.hover = path
	dirty()
end

-- Take a row: a submenu row opens its submenu, an action row closes the chain
-- and runs. One function because a press and the keyboard's enter verb are the
-- same act, and two spellings of it would drift.
local function activate(lv, i)
	local item = lv.items[i]
	local path = lv.path .. "/" .. i
	local items = type(item[2]) == "table" and item[2] or nil
	if items ~= nil then
		navigate(lv, path, "menu:" .. path, items)
		return
	end
	-- Close BEFORE the action: the action may open another menu (a layoutlist
	-- entry does), and closing after would eat the one it just opened.
	menu.close()
	if type(item[2]) == "function" then
		item[2]()
	end
end

-- Keyboard navigation as VERBS on the open chain, with the key map a
-- thin layer over them. The verbs are the mechanism: a key, a config, and a
-- script over IPC all drive a menu the same way, and only one of the three
-- needs an input device.
--
-- Every verb acts on the DEEPEST level, because the chain is the open state and
-- its last entry is what "the current menu" means. So the arrows walk the
-- submenu the pointer just opened, and no verb has to choose between levels.

-- The selected row of a level as an index, 0 for none. hover holds a path, and
-- a path is the level's own path plus the row number, so this is a match rather
-- than a parse.
local function selected(lv)
	for i = 1, #lv.items do
		if lv.path .. "/" .. i == lv.hover then
			return i
		end
	end
	return 0
end

-- Move the selection one row, wrapping at both ends. Nothing selected is
-- position zero, which makes "up from nothing lands on the last row" wrap's own
-- algebra instead of a second rule. Moving never descends: opening the submenu
-- under a row merely walked past would deepen the chain and move the level the
-- next verb acts on.
local function step(lv, dir)
	local n = #lv.items
	if n == 0 then
		return
	end
	local i = selected(lv)
	if i == 0 then
		i = dir > 0 and 1 or n
	else
		i = (i - 1 + dir) % n + 1
	end
	set_hover(lv, lv.path .. "/" .. i)
end

-- menu.nav(verb): "down", "up", "enter" (descend or run), "back" (close one
-- level, or the chain at the root), "close". Returns whether the verb was
-- handled, which is what tells a no-op from a navigation.
function menu.nav(verb)
	if menu.open == nil then
		return false
	end
	local levels = menu.open.levels
	local lv = levels[#levels]
	if verb == "down" or verb == "up" then
		step(lv, verb == "down" and 1 or -1)
	elseif verb == "enter" then
		local i = selected(lv)
		if i == 0 then
			return false
		end
		-- The action may open a menu of its own (a layoutlist entry does), so
		-- the chain's identity is what says whether the level below is ours.
		local chain = menu.open
		activate(lv, i)
		local sub = menu.open == chain and menu.open.levels[lv.depth + 1] or nil
		-- A submenu that opened with nothing lit reads as inert, so a keyboard
		-- descent lands on its first row. A press does not, because a pointer
		-- is already saying where it is.
		if sub ~= nil and sub.hover == nil and #sub.items > 0 then
			set_hover(sub, sub.path .. "/1")
		end
	elseif verb == "back" then
		if #levels > 1 then
			if truncate(#levels - 1) then
				dirty()
			end
		else
			menu.close()
		end
	elseif verb == "close" then
		menu.close()
	else
		return false
	end
	return true
end

-- The map: keysym to verb, so a config adds a key with one assignment
-- (kiln.menu.keys.j = "down") and replaces the lot by assigning a table. Not a
-- theme value, because the theme is paint and metrics and a keysym is neither.
-- Escape is back rather than a close of its own: "one level, and the chain
-- when there is only one level" IS back.
menu.keys = {
	Down = "down", Up = "up",
	Right = "enter", Return = "enter", KP_Enter = "enter",
	Left = "back", Escape = "back",
}

-- One queued key, routed here by the claim ahead of every binding.
function on_key(ev)
	if not ev.pressed then
		return
	end
	local verb = menu.keys[ev.key]
	if verb ~= nil then
		menu.nav(verb)
	end
end

local function declare_level(lv, z)
	local th = state.theme
	-- The root level floats at its point; a submenu floats off the row that
	-- opened it, which is the whole of submenu placement. Clay attaches it,
	-- so there is no arithmetic here to get wrong.
	-- fit: Clay attaches, and the fit keeps the attachment on screen. A
	-- level near the right or bottom edge mirrors its attach pair so it opens the
	-- other way, and whatever still overhangs slides back into the workarea.
	local float = { band = "overlay", z = z, fit = true }
	if lv.under ~= nil then
		float.to, float.parent = "element", lv.under
		-- The submenu's left edge on the row's right edge: the two attach
		-- points differ, which is the whole of submenu placement. No width
		-- arithmetic, because Clay is doing the placing.
		-- A root level opened under an element (the launcher glyph) instead
		-- drops from that element's bottom edge, so the menu clears the bar
		-- rather than covering it.
		float.anchor = lv.depth == 1
			and { parent = "left_bottom", element = "left_top" }
			or { parent = "right_top", element = "left_top" }
	else
		float.to, float.offset = "root", { x = lv.x, y = lv.y }
	end
	ui.column({
		id = "menu:box" .. lv.path,
		float = float,
		w = th.menu_width,
		color = th.bg, radius = 6, pad = 4,
		border = { width = 1, color = th.accent },
	}, function()
		for i, item in ipairs(lv.items) do
			local path = lv.path .. "/" .. i
			local id = "menu:" .. path
			-- A table payload is a submenu, a function is an action. That one
			-- line is the entire item schema.
			local items = type(item[2]) == "table" and item[2] or nil
			-- Lit under the pointer, and lit while the submenu it opened is
			-- still up: walking into a submenu should not blank the row that
			-- led there.
			local sub = menu.open.levels[lv.depth + 1]
			local lit = lv.hover == path or (sub ~= nil and sub.path == path)
			ui.row({
				id = id,
				w = "grow", h = th.menu_height,
				-- The gap is what separates an icon cell from its label; a
				-- text-only row has one child and never shows it.
				pad = { x = 6 }, gap = 6, align = { y = "center" },
				radius = 3,
				color = lit and th.bg2 or nil,
				on_press = function()
					activate(lv, i)
				end,
				-- Hover is navigation too, and the same call. This path needs
				-- a real pointer, so no automated coverage exercises it and
				-- nothing else may depend on it. On enter only: leaving a
				-- row is not a navigation, it is the pointer on its way to the
				-- next one, and acting on it would close the submenu under it.
				on_hover = function(over)
					if over then
						set_hover(lv, path)
						navigate(lv, path, id, items)
					elseif lv.hover == path then
						set_hover(lv, nil)
					end
				end,
			}, function()
				-- An optional icon cell before the label: item.icon is a
				-- resolved path or cache key (kiln.icon.client feeds it), the
				-- hook the client-list menu row rides. Text-only rows skip it.
				if item.icon ~= nil then
					ui.image(item.icon, { w = 12, h = 12 })
				end
				ui.text(item[1], { size = 12 })
				if items ~= nil then
					ui.spacer()
					-- The submenu marker is a theme VALUE, the same way
					-- menu_width and menu_height are: a config that names an
					-- image gets the image, one that names nothing gets the
					-- text. Not a fallback chain, one choice with a default.
					if th.menu_submenu_icon ~= nil then
						ui.image(th.menu_submenu_icon, { w = 12, h = 12 })
					else
						ui.text(">", { size = 12, color = th.muted })
					end
				end
			end)
		end
	end)
end

-- The client-list menu: a row per mapped client,
-- labelled and iconed like a tasklist entry, whose action brings the client to
-- the fore. It is just a menu.show over client.all(), so under/screen/x/y all
-- behave as they do for any stdlib menu; cfg is passed through untouched but for
-- the items it fills in.
function menu.client_list(cfg)
	cfg = cfg or {}
	local items = {}
	for _, c in ipairs(client.all()) do
		if c.mapped then
			items[#items + 1] = {
				c.title or c.app_id or c.class or "?",
				function()
					c.minimized = false
					if c.tag ~= nil and not c.tag.selected then c.tag:view() end
					c:focus()
					c:raise()
				end,
				icon = icon.client(c),
			}
		end
	end
	cfg.items = items
	return menu.show(cfg)
end

-- Called by the runtime inside each screen's declare, after the prompt. Nothing
-- is declared when no menu is open, or when it belongs to another screen.
function menu.declare(s)
	local m = menu.open
	if m == nil or m.screen ~= s then
		return
	end
	-- The scrim: a screen-sized float under the menu that catches the press
	-- that lands outside it. Dispatch is innermost-first with no bubbling, so a
	-- press on a row hits the row and never reaches this; a press anywhere else
	-- dismisses. Alpha 1/255 because Clay emits a rect only above zero alpha,
	-- and a rect is what makes it a hittable scene node (the
	-- kiln.widgets.resize_handles trick). Without it a click on a client would
	-- leave the menu up.
	ui.box({
		id = "menu:scrim",
		float = { to = "root", band = "overlay" },
		w = s.width, h = s.height,
		color = "#00000001",
		on_press = menu.close,
	})
	for i, lv in ipairs(m.levels) do
		declare_level(lv, i)
	end
end

return menu
