
local ui = require("kiln.ui")
local state = require("kiln.state")
local grab = require("kiln.grab")
local icon = require("kiln.icon")

local widgets = {}

local function clamp01(v)
	if type(v) ~= "number" then
		return 0
	end
	return math.max(0, math.min(1, v))
end

local function percent(v)
	return { "percent", percent = clamp01(v) }
end

function widgets.progress(cfg)
	local th = state.theme
	local h = cfg.h or 4
	local radius = cfg.radius or 2
	ui.box({
		id = cfg.id,
		w = cfg.w or "grow", h = h,
		color = cfg.track or th.muted,
		radius = radius,
	}, function()
		ui.box({
			id = cfg.fill_id,
			w = percent(cfg.value), h = h,
			color = cfg.color or th.accent,
			radius = radius,
		})
	end)
end

function widgets.separator(cfg)
	cfg = cfg or {}
	local t = cfg.thickness or 1
	local len = cfg.length or "grow"
	ui.box({
		id = cfg.id,
		w = cfg.vertical and t or len,
		h = cfg.vertical and len or t,
		color = cfg.color or state.theme.muted,
	})
end

function widgets.toggle(cfg)
	local th = state.theme
	local h = cfg.h or 16
	local pad = cfg.pad or 2
	local knob = h - 2 * pad
	ui.box({
		id = cfg.id,
		w = cfg.w or 32, h = h,
		color = cfg.on and (cfg.color or th.accent) or (cfg.track or th.muted),
		radius = cfg.radius or math.floor(h / 2),
		pad = pad,
		align = { x = cfg.on and "right" or "left", y = "center" },
		on_press = cfg.press,
	}, function()
		ui.box({
			id = cfg.id ~= nil and (cfg.id .. ":knob") or nil,
			w = knob, h = knob,
			color = cfg.knob or th.fg,
			radius = math.floor(knob / 2),
		})
	end)
end

local function value_at(b, x)
	if b == nil or b.width <= 0 or type(x) ~= "number" then
		return nil
	end
	return clamp01((x - b.x) / b.width)
end

function widgets.slider(cfg)
	local th = state.theme
	local id = cfg.id
	if id == nil then
		error("kiln.widgets.slider needs a stable id: it reads its own solved box", 2)
	end
	local h = cfg.h or 16
	local radius = cfg.radius or 3
	local function set(v)
		if v ~= nil and cfg.changed ~= nil then
			cfg.changed(v)
		end
	end
	ui.box({
		id = id,
		w = cfg.w or 120, h = h,
		color = cfg.track or th.bg2,
		radius = radius,
		on_press = function(ev)
			local owner
            for _, sc in ipairs(screen.all()) do if ev and sc.name==ev.screen then owner=sc end end
            if not owner then return end
            local box=core.box(id)
            local v = value_at(box, ev.x-owner.x)
			if v == nil then
				return
			end
			set(v)
            core.dirty(owner.name)
			local c
			local removed = function() if c then c:stop() end end
			c = grab.mousegrabber {
				motion = function(mev)
					set(value_at(box, mev.x-owner.x))
					core.dirty(owner.name)
				end,
				button = function(bev)
					if not bev.pressed and bev.button == ev.button then
						c:stop()
					end
				end,
				stopped = function() owner:off('removed', removed) end,
			}
			if c.active then owner:on('removed', removed) end
		end,
	}, function()
		ui.box({
			id = id .. ":fill",
			w = percent(cfg.value), h = h,
			color = cfg.color or th.accent,
			radius = radius,
		})
	end)
end

function widgets.titlebar(c, focused)
	local th = state.theme
	ui.row({
		id = { "titlebar", c.handle },
		w = "grow", h = th.titlebar_height,
		color = focused and th.titlebar_focus or th.titlebar,
		pad = { x = 4 }, gap = 4, align = { y = "center" },
		on_press = function(ev) if ev.button==1 then c:focus(); c:grab_move() end end,
	}, function()
		local ic = icon.client(c)
		if ic ~= nil then
			ui.image(ic, { w = 12, h = 12 })
		else
			ui.box({ w = 12, h = 12, color = th.accent, radius = 2 })
		end
		ui.box({ w = "grow", align = "center", clip={horizontal=true} }, function()
			ui.text(c.title or c.app_id or "",
				{ color = focused and th.fg or th.muted, ellipsize=true })
		end)
		ui.box({
			id = { "maximize", c.handle }, w = 14, h = 14,
			color = th.accent, radius = 2,
			on_press = function() c:toggle_maximized() end,
		})
		ui.box({
			id = { "close", c.handle }, w = 14, h = 14,
			color = th.close, radius = 2,
			on_press = function() c:close() end,
		})
	end)
end

local resize_specs = {
	{ e = "n", anchor = "center_top", axis = "x" },
	{ e = "s", anchor = "center_bottom", axis = "x" },
	{ e = "w", anchor = "left_center", axis = "y" },
	{ e = "e", anchor = "right_center", axis = "y" },
	{ e = "nw", anchor = "left_top" },
	{ e = "ne", anchor = "right_top" },
	{ e = "sw", anchor = "left_bottom" },
	{ e = "se", anchor = "right_bottom" },
}

function widgets.resize_handles(c, z)
	local hs = state.theme.resize_handle
	local f = c.float or {}
	local cw = f.width or (c.width > 0 and c.width or 400)
	local ch = f.height or (c.height > 0 and c.height or 300)
	local hz = (z or 0) + 1
	for _, s in ipairs(resize_specs) do
		local w, h
		if s.axis == "x" then
			w, h = cw - 2 * hs, hs
		elseif s.axis == "y" then
			w, h = hs, ch - 2 * hs
		else
			w, h = hs, hs
		end
		ui.box({
			id = { "resize_" .. s.e, c.handle },
			float = { to = "parent", anchor = s.anchor, z = hz },
			w = w > 1 and w or 1, h = h > 1 and h or 1,
			color = "#00000001",
			on_press = function(e) if e.button==1 then c:grab_resize(s.e) end end,
			on_hover = function(over)
				if over then
					core.input.set_cursor(state.theme.cursors.resize[s.e])
				end
			end,
		})
	end
end


function widgets.client(c, cfg)
	cfg = cfg or {}
	local th = state.theme
	local focused = client.focus == c
	local border_color = focused and th.accent
		or (c.urgent and th.urgent or th.bg)
	ui.column({
		id = { "client", c.handle },
		w = cfg.w or "grow", h = cfg.h or "grow",
		pad = th.border_width,
		border = { width = th.border_width, color = border_color },
		radius = th.client_radius,
	}, function()
		if c.titlebar ~= false then
			widgets.titlebar(c, focused)
		end
		ui.surface(c, { w = "grow", h = "grow" })
		if c.floating then
			widgets.resize_handles(c, cfg.z)
		end
	end)
end


local function handled(fn, item, ev)
	return fn ~= nil and fn(item, ev)
end

function widgets.taglist(s, cfg)
	cfg = cfg or {}
	local on = cfg.on or {}
	local th = state.theme
	ui.row({
		id = "taglist:" .. s.name,
		gap = 4, align = { y = "center" },
		on_scroll = on.scroll,
	}, function()
		for i, t in ipairs(s.tags) do
			local occupied = #t.clients > 0
			ui.box({
				id = { "tag", i },
				color = t.selected and th.accent or nil,
				h = 18, radius = 3, pad = { x = 6 }, align = "center",
				on_press = function(ev)
					if handled(on.press, t, ev) then
						return
					end
					t:view()
				end,
			}, function()
				ui.text(t.name, { size = 12,
					color = (t.selected or occupied) and th.fg or th.muted })
				if occupied then
					local lit = client.focus ~= nil and client.focus.tag == t
					ui.box({
						id = { "tagsquare", i },
						float = { to = "parent", passthrough = true,
							anchor = { parent = "left_top",
								element = "left_top" },
							offset = { x = 2, y = 2 } },
						w = 4, h = 4,
						color = lit and th.fg or nil,
						border = lit and nil or { width = 1, color = th.fg },
					})
				end
			end)
		end
	end)
end

local function on_screen(c, s)
	for _, t in ipairs(c.tags or {}) do
		if t.screen == s and t.selected then
			return true
		end
	end
	return false
end

widgets.filter = {
	currenttags = on_screen,
	alltags = function()
		return true
	end,
	minimized = function(c, s)
		return c.minimized and on_screen(c, s)
	end,
}

local function task_key(c)
	return "task:" .. c.handle
end

function widgets.tasklist(s, cfg)
	cfg = cfg or {}
	local on = cfg.on or {}
	local th = state.theme
	local filter = cfg.filter or widgets.filter.currenttags
	local cs, seen = {}, {}
	for _, t in ipairs(s.tags) do
		for _, c in ipairs(t.clients) do
			if not seen[c] and c.mapped and not c.override_redirect
					and filter(c, s) then
				seen[c] = true
				table.insert(cs, c)
			end
		end
	end
	ui.row({
		id = "tasklist:" .. s.name,
		gap = 4, align = { y = "center" },
		on_scroll = on.scroll,
	}, function()
		local slot = 0
		ui.each(cs, task_key, function(c, id)
			slot = slot + 1
			local clip_id = "taskclip:" .. s.name .. ":" .. slot
			ui.row({
				id = id,
				w = cfg.width or { "grow", max = 180 }, h = "grow",
				pad = { x = 6 }, gap = 4, align = { y = "center" },
				radius = 3,
				color = c == client.focus and th.accent
					or (c.urgent and th.urgent or nil),
				on_press = function(ev)
					if handled(on.press, c, ev) then
						return
					end
					if c.minimized then
						c:emit("request::minimize", false)
					end
					c:focus()
				end,
			}, function()
				local ic = icon.client(c)
				if ic ~= nil then
					ui.image(ic, { id = { "taskicon", c.handle },
						w = 10, h = 10 })
				else
					ui.box({ id = { "taskicon", c.handle }, w = 10, h = 10,
						color = th.muted, radius = 2 })
				end
				ui.box({ id = clip_id, w = "grow", h = "grow",
						align = { y = "center" },
						clip = { horizontal = true } }, function()
					ui.text(c.title or c.app_id or "", { size = 12,
						ellipsize = true,
						color = c.minimized and th.muted or th.fg })
				end)
			end)
		end)
	end)
end

function widgets.layoutbox(s, cfg)
	cfg = cfg or {}
	local on = cfg.on or {}
	local t = s.selected_tag
	if t == nil then
		return
	end
	local layout = require("kiln.layout")
	ui.box({
		id = "layoutbox:" .. s.name,
		color = state.theme.bg2, radius = 4, pad = { x = 6 }, align = "center",
		on_press = function(ev)
			local sel = s.selected_tag
			if sel == nil then
				return
			end
			if handled(on.press, sel, ev) then
				return
			end
			sel.layout = layout.next(sel.layout)
		end,
		on_scroll = on.scroll,
	}, function()
		local name = layout.name(t.layout)
		local icons = state.theme.layout_icons
		local img = icons ~= nil and name ~= nil
			and icons[name:match("^([^.]+)") or name] or nil
		if img ~= nil then
			ui.image(img, { id = "layoutbox:glyph:" .. s.name, w = 16, h = 16 })
		else
			ui.text(name or "?", { size = 12 })
		end
	end)
end

function widgets.layoutlist(s, cfg)
	local layout = require("kiln.layout")
	local items = {}
	for _, fn in ipairs(layout.list) do
		table.insert(items, { layout.name(fn), function()
			s.selected_tag.layout = fn
		end })
	end
	cfg = cfg or {}
	cfg.items, cfg.screen = items, s
	ui.menu(cfg)
end

local default_titlebar = widgets.titlebar
local clock_timer
local clock_generation = 0
local function schedule_clock()
	local ms = (60 - (os.time() % 60)) * 1000 + 50
	local generation=clock_generation
	clock_timer=core.timer(ms, function()
        if generation~=clock_generation then return end
		core.dirty()
		schedule_clock()
	end)
end

function widgets.clock()
	if not clock_timer then
		schedule_clock()
	end
	ui.text(os.date("%a %b %d  %H:%M"))
end

function widgets.reset()
    widgets.titlebar=default_titlebar
    clock_generation=clock_generation+1
    if clock_timer then core.timer_cancel(clock_timer) end
    clock_timer=nil
end
local function tray_key(it)
	return "tray:" .. it.service
end

-- widgets.systray: the SNI items as image cells, in registration order, keyed by
-- the item's service. One declare over the registry the C watcher feeds; no
-- model and no update path, the widgets.tasklist discipline, since a tray change
-- dirties the screen and the next solve is the new tray. A "tray:" entry is a
-- cache key C decoded from the item's IconPixmap; a bare IconName resolves
-- through the icon lookup (the tray row's own promised Lua leg), falling back to
-- the name as a path. An item that offered no icon still gets a hittable, muted
-- cell.
--
-- Press activates and scroll forwards the delta, each one method call on the item
-- (core.tray_activate). The chrome press edge carries no button, so the default
-- widget wires the one gesture it can name; SecondaryActivate stays a verb a
-- config can call directly.
function widgets.systray(cfg)
	cfg = cfg or {}
	local systray = require("kiln.systray")
	local size = cfg.size or 18
	ui.each(systray.items(), tray_key, function(it, id)
        local function current()
            for _, live in ipairs(systray.items()) do if live==it then return true end end
            return false
        end
		local img = it.icon
		if img ~= nil and img:sub(1, 5) ~= "tray:" then
			img = icon.path(img) or img
		end
		ui.box({
			id = id,
			image = img ~= nil and { path = img } or nil,
			color = it.icon == nil and state.theme.muted or nil,
			w = size, h = size, radius = 2,
			on_press = function()
				if current() then core.tray_activate(it.service, "activate", 0) end
			end,
			on_scroll = function(sev)
				if not current() then return end
				local delta, orient
				if sev.dy ~= 0 then
					delta, orient = sev.dy, "vertical"
				else
					delta, orient = sev.dx, "horizontal"
				end
				core.tray_activate(it.service, "scroll", delta, orient)
			end,
		})
	end)
end


return widgets
