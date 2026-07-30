-- kilnrc.lua - the default desktop: a complete session against kiln's public
-- API only. One require, zero compositor primitives; a behavior in here that
-- needs anything else is a defect in the API, not in this file.
--
-- Four numbered SUBSTITUTIONS, each commented in place where it lands. A
-- substitution is a behavior this file expresses through a different
-- mechanism than the obvious one, because the obvious one would need a
-- capability kiln does not have:
--   1. wallpaper pipeline: no drawing api, so the gradient and mark are an
--      SVG string rendered once to a cached PNG by rsvg-convert.
--   2. launcher glyph: a Clay-composed square with two cuts, no image asset.
--   3. per-axis maximize: maximized is one boolean, so the vertical and
--      horizontal chords both toggle it.
--   4. interactive snip: a live selection overlay becomes the same
--      slurp | grim region pipeline the Shift+Print binding uses.

local kiln = require("kiln")
local ui, key, rule, button = kiln.ui, kiln.key, kiln.rule, kiln.button
local widgets = kiln.widgets
local th = kiln.theme

-- The modkey is the config's to set, read live at each key/button bind.
kiln.modkey = "super"

-- ---------------------------------------------------------------------
-- Error handling. The kiln.on("error") bus carries every pcall-caught config
-- error; each one surfaces as a critical notification.
kiln.on("error", function(_, err)
	kiln.notify {
		urgency = "critical",
		title = "Oops, an error happened!",
		message = tostring(err),
	}
end)

-- ---------------------------------------------------------------------
-- Theme. Persisted in $XDG_CONFIG_HOME/kiln/theme, defaults to catppuccin.
-- Three inline palettes map onto the theme keys; switch_theme writes the file
-- and reloads, and the reload re-runs this file, which re-reads the name.

local theme_dir = (os.getenv("XDG_CONFIG_HOME")
	or (os.getenv("HOME") or "") .. "/.config") .. "/kiln"
local theme_file = theme_dir .. "/theme"

local palettes = {
	gruvbox = {
		bg = "#282828", bg2 = "#1d2021", fg = "#ebdbb2", accent = "#83a598",
		muted = "#665c54", titlebar = "#3c3836", titlebar_focus = "#504945",
		close = "#cc241d", urgent = "#d79921",
	},
	-- Mocha: base, surface0, text, mauve, overlay0. The titlebar takes base so
	-- it reads as one band with the bar.
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

-- The write is sync so the reload's re-read sees it.
local function switch_theme(name)
	os.execute("mkdir -p '" .. theme_dir .. "'")
	local f = io.open(theme_file, "w")
	if f ~= nil then
		f:write(name .. "\n")
		f:close()
	end
	kiln.reload()
end

-- ---------------------------------------------------------------------
-- ASSETS. The desktop's look is made of IMAGES: line-art glyphs recolored per
-- theme for the layoutbox, the titlebar buttons and the submenu chevron, plus
-- a corner-to-corner gradient wallpaper with the logo centered on it. kiln has
-- no way to MAKE an image, only to declare one, so this config makes its own:
-- build the SVG as a string here, render it once with rsvg-convert, declare
-- the PNG through the `image = { path }` leaf that already exists.
--
-- Every glyph body speaks one line-art language (24x24 box, 2px stroke, round
-- caps and joins), so a shape added below inherits the set's look. A glyph a
-- config can generate is a file the project does not ship.
--
-- The render-and-cache half is kiln.asset. What stays here is the LOOK: which
-- shapes exist, what language they are drawn in, and how big the mark on the
-- wallpaper is. Those are this desktop's answers and not anyone else's.

local asset = kiln.asset

-- The glyph bodies: 24x24 user units, stroked, never filled.
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
	lock = '<rect x="3" y="11" width="18" height="11" rx="2"/>' ..
		'<path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
	power = '<path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.8 0"/>',
	restart = '<path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/>',
	edit = '<path d="M12 20h9"/>' ..
		'<path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/>',
	-- Two overlapping swatches, not a disc with three dots: the dots read as a
	-- face at 16px, which is the wrong word for a theme picker.
	palette = '<circle cx="9" cy="9" r="5.5"/><circle cx="15" cy="15" r="5.5"/>',
	keys = '<rect x="2" y="6" width="20" height="12" rx="2"/>' ..
		'<path d="M6 10h.01"/><path d="M10 10h.01"/><path d="M14 10h.01"/>' ..
		'<path d="M18 10h.01"/><path d="M8 14h8"/>',
}

-- One raster size for every glyph. 64 is larger than any cell that draws one, so
-- every cell downscales, which is sharp at 1x and at 2x both.
local GLYPH_PX = 64

local function glyph_svg(name, color)
	return string.format(
		'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" ' ..
		'viewBox="0 0 24 24" fill="none" stroke="%s" stroke-width="2" ' ..
		'stroke-linecap="round" stroke-linejoin="round">%s</svg>',
		color, glyph_body[name])
end

-- Which glyph each layout family draws. layout.name returns "family.variant" for
-- a variant, so the lookup splits on the dot and falls back to the family.
local layout_glyph = {
	tile = "tile", fair = "fair", dwindle = "dwindle", spiral = "spiral",
	corner = "corner", magnifier = "magnifier", carousel = "carousel",
	max = "maximize", floating = "move",
}

-- The glyph set this config asks for, name and colour both, because the colour
-- is part of the file. The titlebar's two ink states are two entries.
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

-- Request everything, render it in one fork, then resolve each to a path.
-- G[name][colour] is the path or false; nothing after this point forks.
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

-- glyph(name, colour) -> a readable PNG path, or nil. nil is not an error: it is
-- the answer every call site is written to take.
local function glyph(name, color)
	local by = G[name]
	return (by ~= nil and by[color]) or nil
end

-- The logo mark: one stroked path plus a copy of itself turned half a turn
-- about the middle of the 500x1100 viewBox. Written as geometry rather than
-- loaded from a file because the mark is drawn at the screen's exact pixel
-- count, and the geometry is what the generator needs to do that; the stroke
-- colour rides the same document because it is already being written.
local LOGO_D = "M300 900V700L100 500V300L300 100 500 300V500L400 600"
local LOGO_VB_X, LOGO_VB_Y = 50, 50
local LOGO_VB_W, LOGO_VB_H = 500, 1100

-- The wallpaper: the theme gradient corner to corner with the mark centered
-- on it, rendered at the screen's PHYSICAL size. s.width is LOGICAL, and the
-- renderer scales whatever it decodes into the solved box with no aspect
-- preservation, so generating at the panel's exact pixel count is what keeps
-- the mark true and the ramp free of banding.
--
-- The mark is 200 logical px tall and holds the logo's own 500:1100 aspect
-- rather than being letterboxed into a square. The bar launcher keeps its
-- Clay-composed block (SUBSTITUTION 2): the bar draws the blocky "s", the
-- desktop draws the stroked logo.
local wallpapers = {}
-- The scale each screen's canvas reading was last taken under. See wallpaper().
local canvas_scale = {}
local function wallpaper(s)
	local scale = s.scale or 1
	-- The canvas, not the output: the backdrop GROWS to the box Clay is solving
	-- into, and the renderer stretches whatever it decodes into that box with no
	-- aspect preservation, so an asset made for a wider box arrives with the mark
	-- squashed. The canvas is one solve stale and absent before the first one, so
	-- the output is the fallback; a stale answer costs one frame of a stretched
	-- mark and one extra render, never a wrong picture, because the memo is keyed
	-- by the size each file was actually made for.
	--
	-- Except across a SCALE change, where stale is not merely old but wrong by
	-- the ratio: logical geometry shrinks by exactly what the scale grew, so the
	-- previous solve's logical box times the new scale asks for a picture at
	-- neither the old size nor the new one, and that render is pure waste. The
	-- output's own logical size is already fresh on that frame, so it is the
	-- honest input until a solve has answered under the new scale.
	local c = s.canvas
	if canvas_scale[s.name] ~= scale then
		canvas_scale[s.name] = scale
		c = nil
	end
	local lw = (c ~= nil and c.width >= 1) and c.width or (s.width or 0)
	local lh = (c ~= nil and c.height >= 1) and c.height or (s.height or 0)
	local w = math.floor(lw * scale + 0.5)
	local h = math.floor(lh * scale + 0.5)
	if w < 1 or h < 1 then
		return nil
	end
	-- Memoized on the size AND the scale, which are the inputs that vary inside
	-- one process: a theme switch reloads the config and re-runs this file. This
	-- is the cheap gate, and it is what keeps the per-frame declare from
	-- rebuilding a panel-sized SVG string just to hash it.
	--
	-- The scale has to be in the key even though the pixel count already is. A
	-- pure set_scale on a fixed mode leaves w and h alone (logical shrinks by
	-- exactly what the scale grew), so a size-only key hits and serves the old
	-- picture, whose mark was sized for the old scale. The file names stay right
	-- either way, because the digest sees the mark's box.
	local dims = w .. "x" .. h
	local hit = wallpapers[dims .. "@" .. scale]
	if hit ~= nil then
		return hit or nil
	end
	-- The mark's box: the logo's aspect held against a 200-logical-px height,
	-- centered. A nested <svg> carrying the logo's own viewBox does the fit, so
	-- every number written into the document is an integer. That is deliberate:
	-- a transform="scale(0.27)" would be at the mercy of LC_NUMERIC, and one
	-- locale that formats a decimal comma would silently produce a blank mark.
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
	-- The size stays in the name so the cache dir reads at a glance; the digest
	-- carries the palette and the mark, the same as every glyph.
	local p = asset.svg("wallpaper-" .. dims, w, h, svg)
	wallpapers[dims .. "@" .. scale] = p or false
	return p
end

-- ---------------------------------------------------------------------
-- Defaults. The config file's own path feeds the "edit config" menu item: the
-- top-level chunk's source names it.
local terminal = os.getenv("TERMINAL") or "foot"
local editor = os.getenv("EDITOR") or "nano"
local editor_cmd = terminal .. " -e " .. editor
local conffile = (debug.getinfo(1, "S").source:match("^@(.+)$")) or "kilnrc.lua"

-- A separate history list for the lua-eval prompt, kept out of the shared
-- run-command history.
local eval_history = {}

-- ---------------------------------------------------------------------
-- Helpers the bindings and chrome share. All public-API arithmetic: no
-- primitives, no library internals.

-- View the tag `delta` steps from the current selection, wrapping. Shared by
-- the arrow keys, the taglist scroll, and the backdrop wheel.
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

-- The screen's visible client stack, deduped, in declare order (the union a
-- layout draws: selected tags then sticky). The basis for focus and swap by
-- index.
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

-- kiln.layout.next has no prev twin.
local function layout_prev(fn)
	local list = kiln.layout.list
	for i, f in ipairs(list) do
		if f == fn then
			return list[(i - 2) % #list + 1]
		end
	end
	return list[1]
end

-- Focus the next monitor's most recent client, else just move the active
-- screen.
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

-- The $PATH executable list for the run-prompt completion, memoized. Lua's
-- stdlib has no readdir, so this shells to `ls`. kiln.prompt.completion
-- filters by prefix.
local path_bins_cache
local function path_bins()
	if path_bins_cache ~= nil then
		return path_bins_cache
	end
	local set, out = {}, {}
	for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
		local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
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

-- ---------------------------------------------------------------------
-- Layouts: the cycle mod+space walks. No fullscreen layout is in it by
-- construction: fullscreen is a client property (c:toggle_fullscreen()), not
-- a tiling arrangement.
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

-- ---------------------------------------------------------------------
-- The hotkeys sheet is kiln.hotkeys.toggle / .show / .close. It reads the same
-- key registry this config fills, so the desc and group on every binding below
-- are the whole of what this config contributes to it.

-- ---------------------------------------------------------------------
-- The menu: the application menu and its theme submenu, built for the
-- launcher glyph, mod+w, and the root right-click.

-- `item.icon` is the stdlib hook: it takes a resolved path and renders it as
-- the leading cell, so a row's icon is config space and costs nothing but a
-- generated glyph. The chevron is the theme's, set once below.
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
			kiln.spawn(editor_cmd .. " " .. conffile)
		end },
		{ "restart", icon = glyph("restart", th.fg), kiln.reload },
		{ "lock", icon = glyph("lock", th.fg), kiln.lock },
		{ "quit", icon = glyph("power", th.fg), kiln.quit },
	}
end

-- The submenu chevron is a theme key: the stdlib menu renders it as an image
-- when it is set and keeps its text ">" when it is not, so an unset config is
-- unchanged and this one line is the whole wiring.
th.menu_submenu_icon = glyph("chevron", th.muted)

-- The main menu: the app submenu plus a direct terminal row.
local function main_menu(s)
	return {
		{ "kiln", icon = glyph("palette", th.fg), menu_items(s) },
		{ "open terminal", icon = glyph("terminal", th.fg),
			function() kiln.spawn(terminal) end },
	}
end

-- ---------------------------------------------------------------------
-- The app launcher, opened by mod+p: every installed .desktop app behind a
-- TYPE-TO-FILTER entry. It is kiln.launcher now, so what is left here is the
-- one thing about it that is this desktop's choice rather than the stdlib's.
--
-- launcher.filter is the ranking, and replacing it is the whole extension
-- point: this one keeps the stdlib's three tiers and puts a terminal app last,
-- because a launcher opened by keyboard is usually not reaching for one.
local default_rank = kiln.launcher.default_filter
kiln.launcher.filter = function(text)
	local out, term = {}, {}
	for _, a in ipairs(default_rank(text)) do
		-- A plain prefix compare, not a pattern: `terminal` comes from $TERMINAL
		-- and a dash in it is a Lua pattern metacharacter (the same trap the
		-- "pop%-up" role rule below escapes around).
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

-- ---------------------------------------------------------------------
-- The bar chrome, hand-rolled so each widget can fork on the press button and
-- modifiers (on_press handlers receive the button event). The stdlib
-- widgets.taglist/widgets.tasklist/widgets.layoutbox wire only the one gesture
-- they can name, so the mod+click and right-click gestures need these.

-- SUBSTITUTION 2: the launcher glyph, a blocky "s". A Clay-composed square in
-- accent with two thin cuts floated in the bar color at y=1/3 and y=2/3, no
-- image asset. Pressing it toggles the application menu.
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

-- The taglist. The widget declares the cells, the squares and the view default,
-- so only the added gestures live here: mod+left moves the focused client to
-- this tag, right toggles the tag into the selection, mod+right toggles the
-- focused client onto it, and the wheel walks the tags. Plain left is the
-- default and is therefore not written.
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
			-- Declined: the stdlib default views the tag.
		end,
		scroll = function(ev)
			view_relative(s, (ev.dy or 0) > 0 and 1 or -1)
		end,
	} })
end

-- The tasklist. Left on the focused row minimizes it; left on any other row
-- falls through to the default, which unminimizes and focuses. Right opens the
-- client-list menu and the wheel walks focus. The filter adds sticky clients to
-- the default predicate, which is the one thing about a task list that is this
-- config's choice.
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
				-- Declined: the stdlib default unminimizes and focuses.
			end,
			scroll = function(ev)
				focus_byidx((ev.dy or 0) > 0 and 1 or -1)
			end,
		},
	})
end

-- The layoutbox. Left steps forward, which is the default, so only right (step
-- back) and the wheel (both directions) are written here.
--
-- The cell draws a glyph rather than the layout's name. The glyphs are generated
-- above, and they reach the widget the way the menu chevron does, as a theme key
-- keyed by layout FAMILY: every variant of a family shares the family's glyph,
-- and the widget falls back to the text label for a family this table does not
-- name.
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
			-- Declined: the stdlib default steps forward.
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

-- SUBSTITUTION 1: the wallpaper PIPELINE. The gradient and the centered mark
-- are pixels this config made itself: the SVG built as a string above,
-- rendered once to a content-addressed PNG by rsvg-convert, and declared as
-- one image leaf floated to root in the background band. There is no drawing
-- API here and there is not going to be one; a string and a cached file are
-- what a config has, and they are enough.
--
-- KILN_WALLPAPER still wins when it is set, and the theme fill is still the
-- answer when neither resolves. The backdrop also carries the root wheel
-- binding: a scroll over empty workarea rides it.
local function backdrop(s)
	local wp = os.getenv("KILN_WALLPAPER")
	if wp == nil or wp == "" then
		wp = wallpaper(s)
	end
	ui.box({
		id = "backdrop",
		-- passthrough is not decoration: a background float defaults to
		-- CAPTURE, and a captured full-screen root float sits over the in-flow
		-- chrome in Clay's pointer test, so clicks meant for the bar would land
		-- here instead. passthrough keeps the bar hittable while the backdrop
		-- still catches the wheel over empty desktop (it stays in the hit list,
		-- just non-blocking). A wallpaper is a label, not a target.
		float = { to = "root", band = "background", passthrough = true },
		-- Grown for the reason root-fill is: this is the fill OF the root, and
		-- the output stops being the root's size the moment anything takes a
		-- strip off it.
		w = "grow", h = "grow",
		-- The theme colour answers only when no wallpaper resolved. It cannot be
		-- a layer under the image, because a fill and an image on one box are one
		-- channel and not two: given both, the fill is the ink the image is drawn
		-- in. So the degraded case names it and the working case leaves it out.
		color = (wp == nil or wp == "") and th.bg or nil,
		image = (wp ~= nil and wp ~= "") and { path = wp } or nil,
		on_scroll = function(ev)
			view_relative(s, (ev.dy or 0) > 0 and 1 or -1)
		end,
	})
end

-- ---------------------------------------------------------------------
-- Titlebars: icon / title / floating / maximized / close. The stock
-- widgets.titlebar has icon/title/maximize/close; this override adds the
-- floating button, keeping the stock id scheme so probes stay stable.
-- widgets.client calls widgets.titlebar through the module table, so overriding
-- it is a public-symbol swap, zero stdlib. Press-anywhere drags, right-press
-- resizes from the nearest corner.
--
-- The buttons keep their ids and their handlers; only the child changes, so
-- every existing probe still finds them. The line-art ink follows focus, and
-- the two colours are two cache entries because the colour is part of the
-- file.
local function titlebar_button(id, name, color, press)
	ui.box({
		id = id, w = 14, h = 14, radius = 2, align = "center",
		on_press = press,
	}, function()
		local g = glyph(name, color)
		if g ~= nil then
			ui.image(g, { w = 12, h = 12 })
		else
			-- No glyph rendered: fall back to a plain coloured block, because
			-- a pressable button has to be visible.
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
		-- The title rides a single growing cell that centers its text. It has
		-- to be one grow cell rather than a spacer on each side: two spacers
		-- plus a long title overflow a narrow floating client and shove the
		-- buttons off the row.
		ui.box({ w = "grow", align = "center" }, function()
			ui.text(c.title or c.app_id or "",
				{ color = focused and th.fg or th.muted })
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

-- ---------------------------------------------------------------------
-- The screen: tags and the bar. Five tags on tile, tag 1 viewed; the bar
-- carries the launcher glyph, taglist, tasklist, systray, layoutbox, a
-- centered clock, and the launcher's result-list declare hook.
screen.on("added", function(s)
	tag.new { name = "dev", screen = s, layout = kiln.layout.tile }
	tag.new { name = "web", screen = s, layout = kiln.layout.tile }
	tag.new { name = "chat", screen = s, layout = kiln.layout.tile }
	tag.new { name = "files", screen = s, layout = kiln.layout.tile }
	tag.new { name = "media", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()

	-- Warm the wallpaper here rather than let the first declare do it: the render
	-- is a fork and the declare runs in the frame path. s.width is not seeded
	-- until the first frame handler on some boots, so this is an optimisation and
	-- not the wiring; backdrop() asks again and memoizes either way.
	wallpaper(s)

	-- Three percent-third regions, not grow: the solver sizes a percent
	-- child unconditionally (third_party/clay.h:2292-2297), so the middle
	-- third's center IS the bar's center at any tasklist width, where grow
	-- would cede the center as soon as one side's content outgrew its
	-- third. The side regions clip horizontally, so an overfull tasklist
	-- truncates at its third instead of painting across the middle, the
	-- same rows the old centered float used to occlude.
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
			-- A tooltip is the on_hover handler ui.tooltip makes,
			-- nothing else.
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

-- ---------------------------------------------------------------------
-- Key bindings. Each carries the desc and group the hotkeys popup reads.

-- kiln
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
key { mods = { "mod", "shift" }, key = "Escape", desc = "lock screen", group = "kiln",
	press = kiln.lock }
-- Clay's own debug inspector over the live desktop. The panel takes 400px off
-- the right of the screen while it is up, so the desktop reflows into what is
-- left rather than being covered.
key { mods = { "mod", "shift" }, key = "i", desc = "toggle clay inspector",
	group = "kiln", press = function() kiln.inspector() end }
key { mods = { "mod" }, key = "x", desc = "lua execute prompt", group = "kiln",
	press = function()
		kiln.prompt.run {
			label = "Run Lua code: ",
			history = eval_history,
			done = function(str)
				if str == "" then
					return
				end
				-- Try an expression first, fall back to a statement. loadstring
				-- is LuaJIT's Lua 5.1 name.
				local chunk, cerr = loadstring("return " .. str)
				if chunk == nil then
					chunk = loadstring(str)
				end
				if chunk == nil then
					kiln.notify { title = "Lua error", message = tostring(cerr) }
					return
				end
				local ok, res = pcall(chunk)
				kiln.notify { title = ok and "=" or "Lua error",
					message = tostring(res) }
			end,
		}
	end }
-- The do-not-disturb toggle. There is no way to exempt one notification from
-- suspension, so the ordering IS the trick: enabling notifies THEN suspends
-- (the confirmation shows); disabling unsuspends THEN notifies (the queue
-- flushes, then confirms).
key { mods = { "mod", "shift" }, key = "d", desc = "toggle do-not-disturb",
	group = "kiln",
	press = function()
		if notification.suspended then
			notification.suspended = false
			kiln.notify { title = "Notifications", message = "Resumed",
				timeout = 2 }
		else
			kiln.notify { title = "Notifications", message = "Do Not Disturb",
				timeout = 2 }
			notification.suspended = true
		end
	end }

-- launcher
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

-- tag
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

-- tag (numrow). Four Mod variants over the "1-9" range: each is ONE registry
-- entry that expands to nine chords, the handler taking the index.
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

-- client (global)
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

-- screen
key { mods = { "mod", "ctrl" }, key = "j", desc = "focus the next screen",
	group = "screen",
	press = function() focus_screen_relative(1) end }
key { mods = { "mod", "ctrl" }, key = "k", desc = "focus the previous screen",
	group = "screen",
	press = function() focus_screen_relative(-1) end }

-- audio. Shell strings run via /bin/sh -c.
key { mods = {}, key = "XF86AudioRaiseVolume", desc = "raise volume", group = "audio",
	press = function() kiln.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+") end }
key { mods = {}, key = "XF86AudioLowerVolume", desc = "lower volume", group = "audio",
	press = function() kiln.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-") end }
key { mods = {}, key = "XF86AudioMute", desc = "mute output", group = "audio",
	press = function() kiln.spawn("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle") end }
key { mods = {}, key = "XF86AudioMicMute", desc = "mute microphone", group = "audio",
	press = function() kiln.spawn("wpctl set-mute @DEFAULT_SOURCE@ toggle") end }

-- brightness
key { mods = {}, key = "XF86MonBrightnessUp", desc = "raise brightness",
	group = "brightness",
	press = function() kiln.spawn("brightnessctl set 5%+") end }
key { mods = {}, key = "XF86MonBrightnessDown", desc = "lower brightness",
	group = "brightness",
	press = function() kiln.spawn("brightnessctl set 5%-") end }

-- screenshot
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
-- SUBSTITUTION 4: the interactive screenshot is the same slurp | grim region
-- pipeline the Shift+Print binding uses. slurp draws the selection, grim
-- captures it, no compositor overlay.
key { mods = { "mod", "ctrl" }, key = "p", desc = "interactive screenshot",
	group = "screenshot",
	press = function()
		kiln.spawn(
			"mkdir -p ~/Pictures && slurp | grim -g - ~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png")
	end }

-- layout
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

-- layout (numpad). There is no keygroup mechanism, so layout-by-number is
-- nine explicit KP_n key{} calls, nine registry entries.
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

-- client (per-client). All kiln.focused: they act on the focused client or
-- no-op.
key { mods = { "mod" }, key = "f", desc = "toggle fullscreen", group = "client",
	press = kiln.focused(function(c)
		c:toggle_fullscreen()
		c:raise()
	end) }
-- The polite close. c:kill() is SIGKILL, which is no chord's job.
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
-- SUBSTITUTION 3: maximized is one boolean, so the per-axis chords mod+ctrl+m
-- (vertical) and mod+shift+m (horizontal) both toggle the single state.
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

-- ---------------------------------------------------------------------
-- Mouse bindings. Root right-click toggles the main menu, opened at the
-- launcher anchor rather than the pointer because a root button handler gets
-- the client, not the press point; the root wheel rides the backdrop
-- (declared above). Plain client left-click focuses (the built-in default);
-- mod+left drags, mod+right resizes from the nearest corner.
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

-- ---------------------------------------------------------------------
-- Rules. Three rule{} calls: global placement, floating apps, wlroots
-- routing. Titlebars need no rule: they are on by default, opted out with
-- titlebar = false.
--
-- An empty match clause matches NOTHING (a fire-on-everything rule is a
-- mistake worth catching), so "all clients" is match = { fn = function()
-- return true end }. focus/raise/screen ride kiln.defaults.activate and the
-- preferred-screen default, so only the placement is written here.
rule { match = { fn = function() return true end },
	on = function(c)
		kiln.placement.no_overlap(c)
		kiln.placement.no_offscreen(c)
	end }
-- Floating apps. app (Wayland) and class/instance/role (X11) are separate
-- facts, so the rule names both forms of each app and floats it whichever way
-- it arrives. The dash in "pop-up" is a Lua pattern metacharacter, so it is
-- escaped.
rule { match_any = {
		app = { "pinentry", "Blueman%-manager", "Gpick" },
		instance = { "pinentry" },
		class = { "Blueman%-manager", "Gpick" },
		role = { "pop%-up" },
	},
	props = { floating = true } }
-- Route nested wlroots compositors to the media tag without stealing focus.
-- A tag assignment never auto-switches the view, so focus = false is the
-- whole opt-out.
rule { match_any = { app = { "wlroots" }, class = { "wlroots" } },
	props = { tag = "media", focus = false } }

-- ---------------------------------------------------------------------
-- Notifications. The default per-urgency timeout is already 5s (low/normal 5,
-- critical sticky) and the display is kiln.defaults.notify_display, already
-- wired, so nothing needs writing here.

-- ---------------------------------------------------------------------
-- Sloppy focus: focus follows the mouse, and focus does not raise.
client.on("mouse::enter", function(c) c:focus() end)
