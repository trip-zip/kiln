
local ui = require("kiln.ui")
local state = require("kiln.state")
local grab = require("kiln.grab")
local icon = require("kiln.icon")

local menu = {}
local services=require("kiln.desktop_services")

menu.open = nil

menu.claim = nil
local on_key

local function dirty()
	if menu.open ~= nil then
		core.dirty(menu.open.screen.name)
	end
end

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

function menu.show(cfg)
	local s = cfg.screen or screen.focused or screen.all()[1]
	if not services.live(s) or cfg.items == nil then
		return
	end
    menu.close()
	menu.open = {
		screen = s,
		levels = { {
			items = cfg.items, depth = 1, path = "",
			x = cfg.x or 0, y = cfg.y or 0, under = cfg.under,
		} },
	}
	release()
	local c
	c = grab.keygrabber {
		key = function(ev) on_key(ev) end,
		stopped = function()
			if menu.claim == c then
				menu.claim = nil
				menu.close()
			end
		end,
	}
	menu.claim = c
    if not c.active then menu.claim=nil; menu.close(); return end
	dirty()
	return menu.open
end

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

local function navigate(lv, path, id, items)
    if not menu.open or menu.open.levels[lv.depth]~=lv then return end
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

local function set_hover(lv, path)
    if not menu.open or menu.open.levels[lv.depth]~=lv then return end
	if lv.hover == path then
		return
	end
	lv.hover = path
	dirty()
end

local function activate(lv, i)
    if not menu.open or menu.open.levels[lv.depth]~=lv then return end
	local item = lv.items[i]
	local path = lv.path .. "/" .. i
	local items = type(item[2]) == "table" and item[2] or nil
	if items ~= nil then
		navigate(lv, path, "menu:" .. path, items)
		return
	end
	menu.close()
	if type(item[2]) == "function" then
		item[2]()
	end
end


local function selected(lv)
	for i = 1, #lv.items do
		if lv.path .. "/" .. i == lv.hover then
			return i
		end
	end
	return 0
end

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
		local chain = menu.open
		activate(lv, i)
		local sub = menu.open == chain and menu.open.levels[lv.depth + 1] or nil
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

menu.keys = {
	Down = "down", Up = "up",
	Right = "enter", Return = "enter", KP_Enter = "enter",
	Left = "back", Escape = "back",
}

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
	local float = { band = "overlay", z = z, fit = true }
	if lv.under ~= nil then
		float.to, float.parent = "element", lv.under
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
			local items = type(item[2]) == "table" and item[2] or nil
			local sub = menu.open.levels[lv.depth + 1]
			local lit = lv.hover == path or (sub ~= nil and sub.path == path)
			ui.row({
				id = id,
				w = "grow", h = th.menu_height,
				pad = { x = 6 }, gap = 6, align = { y = "center" },
				radius = 3,
				color = lit and th.bg2 or nil,
				on_press = function()
					activate(lv, i)
				end,
				on_hover = function(over)
					if over then
						set_hover(lv, path)
						navigate(lv, path, id, items)
					elseif lv.hover == path then
						set_hover(lv, nil)
					end
				end,
			}, function()
				if item.icon ~= nil then
					ui.image(item.icon, { w = 12, h = 12 })
				end
				ui.text(item[1], { size = 12 })
				if items ~= nil then
					ui.spacer()
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

function menu.declare(s)
	local m = menu.open
	if m == nil or m.screen ~= s then
		return
	end
    local anchor=m.levels[1].under
    if anchor and not core._declared(anchor) then menu.close(); return end
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
