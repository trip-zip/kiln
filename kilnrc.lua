
local kiln = require("kiln")
local ui, key, rule, button = kiln.ui, kiln.key, kiln.rule, kiln.button
local widgets = kiln.widgets
local th = kiln.theme

kiln.modkey = "super"
kiln.on("error", function(_, err)
    kiln.notify { urgency="critical", title="Oops, an error happened!", message=tostring(err) }
end)

local function shell_quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
local theme_dir = (os.getenv("XDG_CONFIG_HOME")
	or (os.getenv("HOME") or "") .. "/.config") .. "/kiln"
local theme_file = theme_dir .. "/theme"

local palettes = {
	gruvbox = {
		bg = "#282828", bg2 = "#1d2021", fg = "#ebdbb2", accent = "#83a598",
		muted = "#665c54", titlebar = "#3c3836", titlebar_focus = "#504945",
		close = "#cc241d", urgent = "#d79921",
	},
	catppuccin = {
		bg = "#1e1e2e", bg2 = "#313244", fg = "#cdd6f4", accent = "#cba6f7",
		muted = "#6c7086", titlebar = "#1e1e2e", titlebar_focus = "#313244",
		close = "#f38ba8", urgent = "#f38ba8",
	},
	nord = {
		bg = "#2e3440", bg2 = "#272c36", fg = "#eceff4", accent = "#88c0d0",
		muted = "#4c566a", titlebar = "#3b4252", titlebar_focus = "#434c5e",
		close = "#bf616a", urgent = "#ebcb8b",
	},
}

local theme_name = "catppuccin"
do
	local f = io.open(theme_file, "r")
	if f ~= nil then
		local name = f:read("*l")
		if name ~= nil and name ~= "" and palettes[name] ~= nil then
			theme_name = name
		end
		f:close()
	end
end
for k, v in pairs(palettes[theme_name]) do
	th[k] = v
end

local function switch_theme(name)
	os.execute("mkdir -p -- " .. shell_quote(theme_dir))
	local f = io.open(theme_file, "w")
	if f ~= nil then
		f:write(name .. "\n")
		f:close()
	end
	kiln.reload()
end

local asset = kiln.asset

local glyph_body = {
	close = '<path d="M6 6 18 18"/><path d="M18 6 6 18"/>',
	move = '<path d="M12 3v18"/><path d="M3 12h18"/>' ..
		'<path d="m9 6 3-3 3 3"/><path d="m9 18 3 3 3-3"/>' ..
		'<path d="m6 9-3 3 3 3"/><path d="m18 9 3 3-3 3"/>',
	maximize = '<path d="M4 9V4h5"/><path d="M15 4h5v5"/>' ..
		'<path d="M20 15v5h-5"/><path d="M9 20H4v-5"/>',
	chevron = '<path d="m10 6 6 6-6 6"/>',
	tile = '<rect x="3" y="3" width="18" height="18" rx="2"/>' ..
		'<path d="M10 3v18"/>',
	fair = '<rect x="3" y="3" width="18" height="18" rx="2"/>' ..
		'<path d="M12 3v18"/><path d="M3 12h18"/>',
	dwindle = '<rect x="3" y="3" width="18" height="18" rx="2"/>' ..
		'<path d="M12 3v18"/><path d="M12 12h9"/><path d="M16.5 12v9"/>',
	spiral = '<circle cx="12" cy="12" r="3"/>' ..
		'<ellipse cx="12" cy="12" rx="10" ry="4.5" ' ..
		'transform="rotate(-30 12 12)"/>',
	corner = '<rect x="3" y="3" width="18" height="18" rx="2"/>' ..
		'<path d="M3 9h18"/><path d="M9 9v12"/>',
	magnifier = '<circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/>',
	carousel = '<rect x="3" y="3" width="18" height="18" rx="2"/>' ..
		'<path d="M3 12h18"/>',
	terminal = '<path d="m4 17 6-6-6-6"/><path d="M12 19h8"/>',
	lock = '<rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
	power = '<path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.8 0"/>',
	restart = '<path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/>',
	edit = '<path d="M12 20h9"/>' ..
		'<path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/>',
	palette = '<circle cx="9" cy="9" r="5.5"/><circle cx="15" cy="15" r="5.5"/>',
	keys = '<rect x="2" y="6" width="20" height="12" rx="2"/>' ..
		'<path d="M6 10h.01"/><path d="M10 10h.01"/><path d="M14 10h.01"/>' ..
		'<path d="M18 10h.01"/><path d="M8 14h8"/>',
}

local GLYPH_PX = 64

local function glyph_svg(name, color)
	return string.format(
		'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" ' ..
		'viewBox="0 0 24 24" fill="none" stroke="%s" stroke-width="2" ' ..
		'stroke-linecap="round" stroke-linejoin="round">%s</svg>',
		color, glyph_body[name])
end

local layout_glyph = {
	tile = "tile", fair = "fair", dwindle = "dwindle", spiral = "spiral",
	corner = "corner", magnifier = "magnifier", carousel = "carousel",
	max = "maximize", floating = "move",
}

local glyph_use = {}
local function want(name, color)
	if glyph_body[name] ~= nil and color ~= nil then
		glyph_use[#glyph_use + 1] = { name, color }
	end
end
for _, name in pairs(layout_glyph) do
	want(name, th.fg)
end
for _, name in ipairs({ "terminal", "lock", "power", "restart", "edit",
		"palette", "keys" }) do
	want(name, th.fg)
end
want("move", th.muted)
want("maximize", th.muted)
want("move", th.fg)
want("maximize", th.fg)
want("close", th.close)
want("chevron", th.muted)

local G = {}
for _, u in ipairs(glyph_use) do
	local svg = glyph_svg(u[1], u[2])
	u[3] = asset.request(u[1], GLYPH_PX, GLYPH_PX, svg)
end
asset.flush()
for _, u in ipairs(glyph_use) do
	G[u[1]] = G[u[1]] or {}
	G[u[1]][u[2]] = asset.path(u[3]) or false
end

local function glyph(name, color)
	local by = G[name]
	return (by ~= nil and by[color]) or nil
end

local LOGO_D = "M300 900V700L100 500V300L300 100 500 300V500L400 600"
local LOGO_VB_X, LOGO_VB_Y = 50, 50
local LOGO_VB_W, LOGO_VB_H = 500, 1100

local wallpapers = {}
local function wallpaper(s)
	local scale = s.scale or 1
	local w = math.floor((s.width or 0) * scale + 0.5)
	local h = math.floor((s.height or 0) * scale + 0.5)
	if w < 1 or h < 1 then
		return nil
	end
	local dims = w .. "x" .. h
	local hit = wallpapers[dims .. "@" .. scale]
	if hit ~= nil then
		return hit or nil
	end
	local size = math.floor(200 * scale + 0.5)
	local lw = math.floor(size * LOGO_VB_W / LOGO_VB_H + 0.5)
	local lx, ly = math.floor((w - lw) / 2), math.floor((h - size) / 2)
	local svg = string.format(
		'<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" ' ..
		'viewBox="0 0 %d %d"><defs>' ..
		'<linearGradient id="g" gradientUnits="userSpaceOnUse" ' ..
		'x1="0" y1="0" x2="%d" y2="%d">' ..
		'<stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/>' ..
		'</linearGradient></defs>' ..
		'<rect width="%d" height="%d" fill="url(#g)"/>' ..
		'<svg x="%d" y="%d" width="%d" height="%d" ' ..
		'viewBox="%d %d %d %d" preserveAspectRatio="xMidYMid meet" ' ..
		'fill="none" stroke="%s" stroke-width="40" stroke-linecap="round" ' ..
		'stroke-linejoin="round">' ..
		'<path d="%s"/>' ..
		'<path d="%s" transform="rotate(180 300 600)"/>' ..
		'</svg></svg>',
		w, h, w, h, w, h, th.bg, th.bg2,
		w, h,
		lx, ly, lw, size,
		LOGO_VB_X, LOGO_VB_Y, LOGO_VB_W, LOGO_VB_H, th.accent,
		LOGO_D, LOGO_D)
	local p = asset.svg("wallpaper-" .. dims, w, h, svg)
	wallpapers[dims .. "@" .. scale] = p or false
	return p
end

local terminal = os.getenv("TERMINAL") or "foot"
local editor = os.getenv("EDITOR") or "nano"
local editor_cmd = terminal .. " -e " .. editor
local conffile = (debug.getinfo(1, "S").source:match("^@(.+)$")) or "kilnrc.lua"

local eval_history = {}

local function view_relative(s, delta)
	local sel = s.selected_tag
	if sel == nil or #s.tags == 0 then
		return
	end
	for i, t in ipairs(s.tags) do
		if t == sel then
			s.tags[(i - 1 + delta) % #s.tags + 1]:view()
			return
		end
	end
end

local function visible_union(s)
	local out, seen = {}, {}
	for _, t in ipairs(s.tags) do
		if t.selected then
			for _, c in ipairs(t.clients) do
				if not seen[c] and c.mapped and not c.minimized
						and not c.override_redirect then
					seen[c] = true
					out[#out + 1] = c
				end
			end
		end
	end
	for _, t in ipairs(s.tags) do
		for _, c in ipairs(t.clients) do
			if c.sticky and not seen[c] and c.mapped and not c.minimized then
				seen[c] = true
				out[#out + 1] = c
			end
		end
	end
	return out
end

local function focus_byidx(delta)
	local s = screen.focused
	if s == nil then
		return
	end
	local cs = visible_union(s)
	if #cs == 0 then
		return
	end
	local idx = 1
	for i, c in ipairs(cs) do
		if c == client.focus then
			idx = i
		end
	end
	cs[(idx - 1 + delta) % #cs + 1]:focus()
end

local function swap_byidx(delta)
	local s = screen.focused
	if s == nil or client.focus == nil then
		return
	end
	local cs = visible_union(s)
	if #cs < 2 then
		return
	end
	local idx = 1
	for i, c in ipairs(cs) do
		if c == client.focus then
			idx = i
		end
	end
	client.focus:swap(cs[(idx - 1 + delta) % #cs + 1])
end

local function layout_prev(fn)
	local list = kiln.layout.list
	for i, f in ipairs(list) do
		if f == fn then
			return list[(i - 2) % #list + 1]
		end
	end
	return list[1]
end

local function focus_screen_relative(delta)
	local all = screen.all()
	if #all < 2 then
		return
	end
	local idx = 1
	for i, sc in ipairs(all) do
		if sc == screen.focused then
			idx = i
		end
	end
	local target = all[(idx - 1 + delta) % #all + 1]
	local cs = visible_union(target)
	if #cs > 0 then
		cs[#cs]:focus()
	else
		screen.focused = target
	end
end

local function restore_minimized()
	local s = screen.focused
	if s == nil then
		return
	end
	for _, t in ipairs(s.tags) do
		if t.selected then
			for i = #t.clients, 1, -1 do
				local c = t.clients[i]
				if c.minimized then
					c.minimized = false
					c:focus()
					return
				end
			end
		end
	end
end

local function jump_urgent()
	for _, c in ipairs(client.all()) do
		if c.urgent then
			if c.tag ~= nil and not c.tag.selected then
				c.tag:view()
			end
			c:focus()
			return
		end
	end
end

local path_bins_cache
local function path_bins()
	if path_bins_cache ~= nil then
		return path_bins_cache
	end
	local set, out = {}, {}
	for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
		local p = io.popen("ls -1 -- " .. shell_quote(dir) .. " 2>/dev/null")
		if p ~= nil then
			for name in p:lines() do
				if not set[name] then
					set[name] = true
					out[#out + 1] = name
				end
			end
			p:close()
		end
	end
	path_bins_cache = out
	return out
end

kiln.layout.list = {
	kiln.layout.tile,
	kiln.layout.tile.left,
	kiln.layout.tile.bottom,
	kiln.layout.tile.top,
	kiln.layout.carousel,
	kiln.layout.fair,
	kiln.layout.fair.horizontal,
	kiln.layout.max,
	kiln.layout.corner.nw,
	kiln.layout.floating,
	kiln.layout.spiral,
	kiln.layout.dwindle,
	kiln.layout.magnifier,
}


local function menu_items(s)
	return {
		{ "hotkeys", icon = glyph("keys", th.fg), function()
			kiln.hotkeys.show(s)
		end },
		{ "terminal", icon = glyph("terminal", th.fg),
			function() kiln.spawn(terminal) end },
		{ "theme", icon = glyph("palette", th.fg), {
			{ "gruvbox", function() switch_theme("gruvbox") end },
			{ "catppuccin", function() switch_theme("catppuccin") end },
			{ "nord", function() switch_theme("nord") end },
		} },
		{ "edit config", icon = glyph("edit", th.fg), function()
			kiln.spawn(editor_cmd .. " " .. shell_quote(conffile))
		end },
		{ "lock", icon = glyph("lock", th.fg), kiln.lock },
		{ "restart", icon = glyph("restart", th.fg), kiln.reload },
		{ "quit", icon = glyph("power", th.fg), kiln.quit },
	}
end

th.menu_submenu_icon = glyph("chevron", th.muted)

local function main_menu(s)
	return {
		{ "kiln", icon = glyph("palette", th.fg), menu_items(s) },
		{ "open terminal", icon = glyph("terminal", th.fg),
			function() kiln.spawn(terminal) end },
	}
end

local default_rank = kiln.launcher.default_filter
kiln.launcher.filter = function(text)
	local out, term = {}, {}
	for _, a in ipairs(default_rank(text)) do
		if a.exec:sub(1, #terminal) == terminal then
			term[#term + 1] = a
		else
			out[#out + 1] = a
		end
	end
	for _, a in ipairs(term) do
		out[#out + 1] = a
	end
	return out
end

local function launcher_glyph(s)
	local size = th.bar_height - 4
	local cut = math.max(1, math.floor(size / 9))
	ui.box({
		id = "launcher",
		w = size, h = size, color = th.accent, radius = 2, align = "center",
		on_press = function()
			if kiln.menu.open ~= nil then
				kiln.menu.close()
			else
				kiln.menu.show { under = "launcher", screen = s,
					items = main_menu(s) }
			end
		end,
	}, function()
		ui.box({
			float = { to = "parent",
				anchor = { parent = "right_top", element = "right_top" },
				offset = { x = 0, y = math.floor(size / 3) } },
			w = math.floor(size * 2 / 3), h = cut, color = th.bg,
		})
		ui.box({
			float = { to = "parent",
				anchor = { parent = "left_top", element = "left_top" },
				offset = { x = 0, y = math.floor(size * 2 / 3) } },
			w = math.floor(size * 2 / 3), h = cut, color = th.bg,
		})
	end)
end

local function taglist(s)
	widgets.taglist(s, { on = {
		press = function(t, ev)
			local mod = ev ~= nil and ev.mods ~= nil and ev.mods[kiln.modkey]
			local btn = (ev ~= nil and ev.button) or 1
			local c = client.focus
			if btn == 1 and mod then
				if c ~= nil then
					c.tags = { t }
				end
				return true
			elseif btn == 3 and mod then
				if c ~= nil then
					local nt, has = {}, false
					for _, tt in ipairs(c.tags) do
						if tt == t then
							has = true
						else
							nt[#nt + 1] = tt
						end
					end
					if not has then
						nt[#nt + 1] = t
					end
					if #nt > 0 then
						c.tags = nt
					end
				end
				return true
			elseif btn == 3 then
				t:toggle()
				return true
			end
		end,
		scroll = function(ev)
			view_relative(s, (ev.dy or 0) > 0 and 1 or -1)
		end,
	} })
end

local function tasklist(s)
	widgets.tasklist(s, {
		filter = function(c, sc)
			if c.sticky then
				return true
			end
			return widgets.filter.currenttags(c, sc)
		end,
		on = {
			press = function(c, ev)
				local btn = (ev ~= nil and ev.button) or 1
				if btn == 3 then
					kiln.menu.client_list { screen = s }
					return true
				elseif c == client.focus then
					c.minimized = true
					return true
				end
			end,
			scroll = function(ev)
				focus_byidx((ev.dy or 0) > 0 and 1 or -1)
			end,
		},
	})
end

th.layout_icons = {}
for family, name in pairs(layout_glyph) do
	th.layout_icons[family] = glyph(name, th.fg)
end

local function layoutbox(s)
	widgets.layoutbox(s, { on = {
		press = function(t, ev)
			if ev ~= nil and ev.button == 3 then
				t.layout = layout_prev(t.layout)
				return true
			end
		end,
		scroll = function(ev)
			local sel = s.selected_tag
			if sel == nil then
				return
			end
			if (ev.dy or 0) > 0 then
				sel.layout = kiln.layout.next(sel.layout)
			else
				sel.layout = layout_prev(sel.layout)
			end
		end,
	} })
end

screen.on("changed", function(s) wallpaper(s) end)
local function backdrop(s)
	local wp = os.getenv("KILN_WALLPAPER")
	if wp == nil or wp == "" then
		wp = wallpaper(s)
	end
	ui.box({
		id = "backdrop",
		float = { to = "root", band = "background", passthrough = true },
		w = "grow", h = "grow",
		color = (wp == nil or wp == "") and th.bg or nil,
		image = (wp ~= nil and wp ~= "") and { path = wp } or nil,
		on_scroll = function(ev)
			view_relative(s, (ev.dy or 0) > 0 and 1 or -1)
		end,
	})
end

local function titlebar_button(id, name, color, press)
	ui.box({
		id = id, w = 14, h = 14, radius = 2, align = "center",
		on_press = press,
	}, function()
		local g = glyph(name, color)
		if g ~= nil then
			ui.image(g, { w = 12, h = 12 })
		else
			ui.box({ w = 12, h = 12, color = color, radius = 2 })
		end
	end)
end

kiln.widgets.titlebar = function(c, focused)
	ui.row({
		id = { "titlebar", c.handle },
		w = "grow", h = th.titlebar_height,
		color = focused and th.titlebar_focus or th.titlebar,
		pad = { x = 4 }, gap = 4, align = { y = "center" },
		on_press = function(ev)
            c:focus()
			if ev ~= nil and ev.button == 3 then
				c:grab_resize_nearest()
			else
				c:grab_move()
			end
		end,
	}, function()
		local ic = kiln.icon.client(c)
		if ic ~= nil then
			ui.image(ic, { w = 12, h = 12 })
		else
			ui.box({ w = 12, h = 12, color = th.accent, radius = 2 })
		end
		ui.box({ w = "grow", align = "center", clip={horizontal=true} }, function()
			ui.text(c.title or c.app_id or "",
				{ color = focused and th.fg or th.muted, ellipsize=true })
		end)
		local ink = focused and th.fg or th.muted
		titlebar_button({ "float", c.handle }, "move", ink, function()
			c.floating = not c.floating
		end)
		titlebar_button({ "maximize", c.handle }, "maximize", ink,
			function() c:toggle_maximized() end)
		titlebar_button({ "close", c.handle }, "close", th.close,
			function() c:close() end)
	end)
end

screen.on("added", function(s)
	tag.new { name = "dev", screen = s, layout = kiln.layout.tile }
	tag.new { name = "web", screen = s, layout = kiln.layout.tile }
	tag.new { name = "chat", screen = s, layout = kiln.layout.tile }
	tag.new { name = "files", screen = s, layout = kiln.layout.tile }
	tag.new { name = "media", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()

	wallpaper(s)

	ui.bar(s, { edge = "top", dir = "row", h = th.bar_height,
		color = th.bg, pad = { x = 8 } }, function()
		backdrop(s)
		ui.row({ w = "33.33%", h = "grow", gap = 6,
				clip = { horizontal = true },
				align = { y = "center" } }, function()
			launcher_glyph(s)
			taglist(s)
			tasklist(s)
		end)
		ui.row({ w = "33.33%", h = "grow", align = "center" }, function()
			ui.box({ id = "clock", color = th.bg2, radius = 4,
				pad = { x = 8 },
				on_hover = ui.tooltip(function()
					return os.date("%A %d %B %Y")
				end),
			}, widgets.clock)
		end)
		ui.row({ w = "33.33%", h = "grow", gap = 6,
				clip = { horizontal = true },
				align = { x = "right", y = "center" } }, function()
			widgets.systray()
			layoutbox(s)
		end)
	end)
end)

key { mods = { "mod" }, key = "s", desc = "show help", group = "kiln",
	press = kiln.hotkeys.toggle }
key { mods = { "mod" }, key = "w", desc = "show main menu", group = "kiln",
	press = function()
		local s = screen.focused
		kiln.menu.show { under = "launcher", screen = s, items = main_menu(s) }
	end }
key { mods = { "mod", "ctrl" }, key = "r", desc = "reload kiln", group = "kiln",
	press = kiln.reload }
key { mods = { "mod", "shift" }, key = "q", desc = "quit kiln", group = "kiln",
	press = kiln.quit }
key { mods = { "mod" }, key = "x", desc = "lua execute prompt", group = "kiln",
	press = function()
		kiln.prompt.run {
			label = "Run Lua code: ",
			history = eval_history,
			done = function(str)
				if str == "" then
					return
				end
				local chunk, cerr = loadstring("return " .. str)
				if chunk == nil then
					chunk = loadstring(str)
				end
				if chunk == nil then
					kiln.notify { title="Lua error", message=tostring(cerr) }
					return
				end
				local ok, res = pcall(chunk)
				kiln.notify { title=ok and "=" or "Lua error", message=tostring(res) }
			end,
		}
	end }
key { mods={"mod","shift"}, key="d", desc="toggle do-not-disturb", group="kiln",
    press=function()
        if notification.suspended then
            notification.suspended=false
            kiln.notify {title="Notifications",message="Resumed",timeout=2}
        else
            kiln.notify {title="Notifications",message="Do Not Disturb",timeout=2}
            notification.suspended=true
        end
    end }
key { mods = { "mod" }, key = "Return", desc = "open a terminal", group = "launcher",
	press = function() kiln.spawn(terminal) end }
key { mods = { "mod" }, key = "r", desc = "run prompt", group = "launcher",
	press = function()
		kiln.prompt.run {
			label = "Run: ",
			completion = kiln.prompt.completion(function() return path_bins() end),
			done = function(cmd)
				if cmd ~= "" then
					kiln.spawn(cmd)
				end
			end,
		}
	end }
key { mods = { "mod" }, key = "p", desc = "show the menubar", group = "launcher",
	press = function() kiln.launcher.open() end }

key { mods = { "mod" }, key = "Left", desc = "view previous", group = "tag",
	press = function() view_relative(screen.focused, -1) end }
key { mods = { "mod" }, key = "Right", desc = "view next", group = "tag",
	press = function() view_relative(screen.focused, 1) end }
key { mods = { "mod" }, key = "Escape", desc = "go back", group = "tag",
	press = function() tag.history.restore(screen.focused) end }
key { mods = { "mod", "shift" }, key = "r", desc = "rename current tag", group = "tag",
	press = function()
		local s = screen.focused
		local t = s ~= nil and s.selected_tag or nil
		if t == nil then
			return
		end
		kiln.prompt.run {
			label = "Rename tag: ", text = t.name,
			done = function(name)
				if name ~= nil and name ~= "" then
					t.name = name
				end
			end,
		}
	end }

key { mods = { "mod" }, key = "1-9", desc = "only view tag", group = "tag",
	press = function(i)
		local t = screen.focused.tags[i]
		if t ~= nil then
			t:view()
		end
	end }
key { mods = { "mod", "ctrl" }, key = "1-9", desc = "toggle tag", group = "tag",
	press = function(i)
		local t = screen.focused.tags[i]
		if t ~= nil then
			t:toggle()
		end
	end }
key { mods = { "mod", "shift" }, key = "1-9", desc = "move focused client to tag",
	group = "tag",
	press = function(i)
		local c = client.focus
		local t = c ~= nil and screen.focused.tags[i] or nil
		if t ~= nil then
			c.tags = { t }
		end
	end }
key { mods = { "mod", "ctrl", "shift" }, key = "1-9",
	desc = "toggle focused client on tag", group = "tag",
	press = function(i)
		local c = client.focus
		local t = c ~= nil and screen.focused.tags[i] or nil
		if t == nil then
			return
		end
		local nt, has = {}, false
		for _, tt in ipairs(c.tags) do
			if tt == t then
				has = true
			else
				nt[#nt + 1] = tt
			end
		end
		if not has then
			nt[#nt + 1] = t
		end
		if #nt > 0 then
			c.tags = nt
		end
	end }

key { mods = { "mod" }, key = "j", desc = "focus next by index", group = "client",
	press = function() focus_byidx(1) end }
key { mods = { "mod" }, key = "k", desc = "focus previous by index", group = "client",
	press = function() focus_byidx(-1) end }
key { mods = { "mod" }, key = "Tab", desc = "go back", group = "client",
	press = function()
		local c = client.history.previous()
		if c ~= nil then
			c:focus()
			c:raise()
		end
	end }
key { mods = { "mod" }, key = "u", desc = "jump to urgent client", group = "client",
	press = jump_urgent }
key { mods = { "mod", "shift" }, key = "j", desc = "swap with next client by index",
	group = "client",
	press = function() swap_byidx(1) end }
key { mods = { "mod", "shift" }, key = "k",
	desc = "swap with previous client by index", group = "client",
	press = function() swap_byidx(-1) end }
key { mods = { "mod", "ctrl" }, key = "n", desc = "restore minimized", group = "client",
	press = restore_minimized }

key { mods = { "mod", "ctrl" }, key = "j", desc = "focus the next screen",
	group = "screen",
	press = function() focus_screen_relative(1) end }
key { mods = { "mod", "ctrl" }, key = "k", desc = "focus the previous screen",
	group = "screen",
	press = function() focus_screen_relative(-1) end }

key { mods = {}, key = "XF86AudioRaiseVolume", desc = "raise volume", group = "audio",
	press = function() kiln.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+") end }
key { mods = {}, key = "XF86AudioLowerVolume", desc = "lower volume", group = "audio",
	press = function() kiln.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-") end }
key { mods = {}, key = "XF86AudioMute", desc = "mute output", group = "audio",
	press = function() kiln.spawn("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle") end }
key { mods = {}, key = "XF86AudioMicMute", desc = "mute microphone", group = "audio",
	press = function() kiln.spawn("wpctl set-mute @DEFAULT_SOURCE@ toggle") end }

key { mods = {}, key = "XF86MonBrightnessUp", desc = "raise brightness",
	group = "brightness",
	press = function() kiln.spawn("brightnessctl set 5%+") end }
key { mods = {}, key = "XF86MonBrightnessDown", desc = "lower brightness",
	group = "brightness",
	press = function() kiln.spawn("brightnessctl set 5%-") end }

key { mods = {}, key = "Print", desc = "screenshot full output", group = "screenshot",
	press = function()
		kiln.spawn(
			"mkdir -p ~/Pictures && grim ~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png")
	end }
key { mods = { "shift" }, key = "Print", desc = "screenshot region",
	group = "screenshot",
	press = function()
		kiln.spawn(
			"mkdir -p ~/Pictures && slurp | grim -g - ~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png")
	end }
key { mods = { "mod", "ctrl" }, key = "p", desc = "interactive screenshot",
	group = "screenshot",
	press = function()
		kiln.spawn(
			"mkdir -p ~/Pictures && slurp | grim -g - ~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png")
	end }

key { mods = { "mod" }, key = "l", desc = "increase master width factor",
	group = "layout",
	press = function()
		local t = screen.focused.selected_tag
		if t ~= nil then
			t.master_width_factor = math.min(0.95,
				(t.master_width_factor or 0.5) + 0.05)
		end
	end }
key { mods = { "mod" }, key = "h", desc = "decrease master width factor",
	group = "layout",
	press = function()
		local t = screen.focused.selected_tag
		if t ~= nil then
			t.master_width_factor = math.max(0.05,
				(t.master_width_factor or 0.5) - 0.05)
		end
	end }
key { mods = { "mod", "shift" }, key = "h", desc = "increase the number of master clients",
	group = "layout",
	press = function()
		local t = screen.focused.selected_tag
		if t ~= nil then
			t.master_count = (t.master_count or 1) + 1
		end
	end }
key { mods = { "mod", "shift" }, key = "l", desc = "decrease the number of master clients",
	group = "layout",
	press = function()
		local t = screen.focused.selected_tag
		if t ~= nil then
			t.master_count = math.max(1, (t.master_count or 1) - 1)
		end
	end }
key { mods = { "mod", "ctrl" }, key = "h", desc = "increase the number of columns",
	group = "layout",
	press = function()
		local t = screen.focused.selected_tag
		if t ~= nil then
			t.column_count = (t.column_count or 1) + 1
		end
	end }
key { mods = { "mod", "ctrl" }, key = "l", desc = "decrease the number of columns",
	group = "layout",
	press = function()
		local t = screen.focused.selected_tag
		if t ~= nil then
			t.column_count = math.max(1, (t.column_count or 1) - 1)
		end
	end }
key { mods = { "mod" }, key = "space", desc = "select next", group = "layout",
	press = function()
		local t = screen.focused.selected_tag
		if t ~= nil then
			t.layout = kiln.layout.next(t.layout)
		end
	end }
key { mods = { "mod", "shift" }, key = "space", desc = "select previous",
	group = "layout",
	press = function()
		local t = screen.focused.selected_tag
		if t ~= nil then
			t.layout = layout_prev(t.layout)
		end
	end }

for i = 1, 9 do
	key { mods = { "mod" }, key = "KP_" .. i, desc = "select layout " .. i,
		group = "layout",
		press = function()
			local t = screen.focused.selected_tag
			if t ~= nil then
				t.layout = kiln.layout.list[i] or t.layout
			end
		end }
end

key { mods = { "mod" }, key = "f", desc = "toggle fullscreen", group = "client",
	press = kiln.focused(function(c)
		c:toggle_fullscreen()
		c:raise()
	end) }
key { mods = { "mod", "shift" }, key = "c", desc = "close", group = "client",
	press = kiln.focused(function(c) c:close() end) }
key { mods = { "mod", "ctrl" }, key = "space", desc = "toggle floating",
	group = "client",
	press = kiln.focused(function(c)
		c.floating = not c.floating
	end) }
key { mods = { "mod", "ctrl" }, key = "Return", desc = "move to master",
	group = "client",
	press = kiln.focused(function(c)
		local s = (c.tag ~= nil and c.tag.screen) or screen.focused
		if s == nil then
			return
		end
		for _, o in ipairs(visible_union(s)) do
			if o ~= c and not o.floating then
				c:swap(o)
				return
			end
		end
	end) }
key { mods = { "mod" }, key = "o", desc = "move to screen", group = "client",
	press = kiln.focused(function(c)
		local all = screen.all()
		if #all < 2 or c.tag == nil then
			return
		end
		for i, sc in ipairs(all) do
			if sc == c.tag.screen then
				c:move_to(all[i % #all + 1])
				return
			end
		end
	end) }
key { mods = { "mod" }, key = "t", desc = "toggle keep on top", group = "client",
	press = kiln.focused(function(c) c.ontop = not c.ontop end) }
key { mods = { "mod" }, key = "comma", desc = "toggle sticky", group = "client",
	press = kiln.focused(function(c) c.sticky = not c.sticky end) }
key { mods = { "mod" }, key = "n", desc = "minimize", group = "client",
	press = kiln.focused(function(c) c.minimized = true end) }
key { mods = { "mod" }, key = "m", desc = "(un)maximize", group = "client",
	press = kiln.focused(function(c)
		c:toggle_maximized()
		c:raise()
	end) }
key { mods = { "mod", "ctrl" }, key = "m", desc = "(un)maximize vertically",
	group = "client",
	press = kiln.focused(function(c)
		c:toggle_maximized()
		c:raise()
	end) }
key { mods = { "mod", "shift" }, key = "m", desc = "(un)maximize horizontally",
	group = "client",
	press = kiln.focused(function(c)
		c:toggle_maximized()
		c:raise()
	end) }

button { mods = {}, button = 3, on = "root", press = function()
	local s = screen.focused
	if kiln.menu.open ~= nil then
		kiln.menu.close()
	else
		kiln.menu.show { under = "launcher", screen = s, items = main_menu(s) }
	end
end }
button { mods = { "mod" }, button = 1, press = function(c) c:grab_move() end }
button { mods = { "mod" }, button = 3,
	press = function(c) c:grab_resize_nearest() end }

rule { match = { fn = function() return true end },
	on = function(c)
		kiln.placement.no_overlap(c)
		kiln.placement.no_offscreen(c)
	end }
rule { match_any = {
		app = { "pinentry", "Blueman%-manager", "Gpick" },
		instance = { "pinentry" },
		class = { "Blueman%-manager", "Gpick" },
		role = { "pop%-up" },
	},
	props = { floating = true } }
rule { match_any = { app = { "wlroots" }, class = { "wlroots" } },
	props = { tag = "media", focus = false } }

client.on("mouse::enter", function(c) c:focus() end)

key {mods={"alt"},key="Escape",desc="quit kiln",group="kiln",press=kiln.quit}

key {mods={"mod","shift"},key="Escape",desc="lock screen",group="kiln",press=kiln.lock}

key { mods = { "mod", "shift" }, key = "i", desc = "toggle clay inspector",
    group = "kiln", press = function() kiln.inspector() end }
