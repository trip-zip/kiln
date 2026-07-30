-- The stock widgets: compositions of the ui.* primitives that read compositor
-- state (screens, tags, clients, the theme) and encode an opinion. Every one
-- is what a config would have written in the public element API, written once;
-- none of them computes a position, because Clay solves everything.
--
-- Widget-to-widget calls go through this module table, never a local upvalue,
-- so a config that swaps a public symbol (kiln.widgets.titlebar is the
-- exemplar) governs every caller, stdlib included.
--
-- The form widgets (progress, separator, toggle, slider) are CONTROLLED: the
-- caller owns the value and the widget draws it, so there is no state here to
-- go stale and no update path to keep in step.

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

-- The table form of a percent sizing, not the "NN%" string. Both reach the same
-- solver field, but the string has to be parsed back out of a number this would
-- have to format first, and a formatted decimal is at the mercy of LC_NUMERIC:
-- one locale writing a decimal comma fails ui.lua's percent match and the axis
-- silently becomes a sizing type named "0,75". The table hands the solver the
-- number it was already holding.
local function percent(v)
	return { "percent", percent = clamp01(v) }
end

-- widgets.progress: a fill across a track, both boxes named so a probe can read the
-- ratio back. fill_id is its own argument rather than derived, because a caller
-- porting an existing widget onto this has ids already in use and a widget is
-- not worth renaming an id over.
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

-- widgets.separator: a rule. Thin on one axis and long on the other, and which is
-- which is the whole of its configuration.
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

-- widgets.toggle: a switch. Controlled, so `on` comes in and `press` goes out and
-- the widget keeps nothing. The knob is placed by childAlignment, which means
-- the two states differ by one word and not by any arithmetic over the track.
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

-- Where the pointer sits along a solved track, as 0..1. Reading the box Clay
-- answered with is allowed; computing where the box should be is not, and this
-- does the first. Before the first solve there is no box and so no honest
-- answer, which is nil rather than a guess.
local function value_at(id, x)
	local b = core.box(id)
	if b == nil or b.width <= 0 or type(x) ~= "number" then
		return nil
	end
	return clamp01((x - b.x) / b.width)
end

-- widgets.slider: a value dragged along a track. Controlled like the toggle, so
-- `changed` is the whole output and the caller decides what the value means.
--
-- The drag is a mousegrabber, the same claim the interactive move and resize
-- use, and ending it is the claim's job: a config grabber that takes the
-- pointer mid-drag, or the reload's grab.reset, ends this one through the same
-- door. Nothing needs unwinding when that happens, because the value lives in
-- the caller and this holds no copy of it.
--
-- The value is read ABSOLUTELY at every step rather than accumulated from
-- deltas, so a press lands where it was pressed and a drag cannot drift away
-- from the pointer over a long slide. The span is the whole track: insetting it
-- by half a knob would be this widget doing layout, and the knob is Clay's to
-- place.
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
			local v = value_at(id, ev ~= nil and ev.x or nil)
			if v == nil then
				return
			end
			set(v)
			local c
			c = grab.mousegrabber {
				motion = function(mev)
					set(value_at(id, mev.x))
					core.dirty(mev.screen)
				end,
				-- The release of the button that STARTED the drag, not of any
				-- button: a second button going up mid-drag is not the end of
				-- this one. init.lua's own drag ends on the same test.
				button = function(bev)
					if not bev.pressed and bev.button == ev.button then
						c:stop()
					end
				end,
			}
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

-- The titlebar row: draw-leaves only, no place-leaf. Icon slot,
-- live title, maximize and close buttons. Pressing the empty bar drags; the
-- buttons sit topmost so a press on one wins the innermost-first hit. Colors
-- read focus at declare, so focus styling is a re-declare, never a C path.
function widgets.titlebar(c, focused)
	local th = state.theme
	ui.row({
		id = { "titlebar", c.handle },
		w = "grow", h = th.titlebar_height,
		color = focused and th.titlebar_focus or th.titlebar,
		pad = { x = 4 }, gap = 4, align = { y = "center" },
		on_press = function() c:grab_move() end,
	}, function()
		-- Icon slot: the client's icon when one resolves (the C fact for X11,
		-- else the app_id lookup), a placeholder square when none does. The row
		-- keeps its shape either way.
		local ic = icon.client(c)
		if ic ~= nil then
			ui.image(ic, { w = 12, h = 12 })
		else
			ui.box({ w = 12, h = 12, color = th.accent, radius = 2 })
		end
		-- The title rides one growing cell that centers its text. One grow
		-- cell rather than a spacer on each side, because two spacers plus a
		-- long title overflow a narrow floating client and shove the buttons
		-- off the row.
		ui.box({ w = "grow", align = "center" }, function()
			ui.text(c.title or c.app_id or "",
				{ color = focused and th.fg or th.muted })
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

-- The eight invisible resize handles for a floating client: thin
-- draw-leaves at the edges and corners, floated over the client with z above the
-- surface so the scene hit names them. A transparent rect is still a scene node,
-- but Clay emits a rect only for alpha > 0, so the color carries a 1/255 alpha:
-- imperceptible, yet a hittable node. Edges are inset by the handle width so they
-- never overlap the corners; a press starts the edge's resize grab, a hover sets
-- the edge cursor. Only declared for floating clients (a tiled client's geometry
-- is the Clay-solved cell, not a thing to drag).
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
	-- Sized to the composite box (c.float), so the handles span the whole
	-- window including the titlebar, not just the surface.
	local f = c.float or {}
	local cw = f.width or (c.width > 0 and c.width or 400)
	local ch = f.height or (c.height > 0 and c.height or 300)
	-- One z above the client's own float, never a fixed constant: Clay sorts
	-- all floats in the tree globally, so a constant would put every handle
	-- above every client body and an unfocused client's invisible edge could
	-- steal presses over the focused client stacked higher.
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
			on_press = function() c:grab_resize(s.e) end,
			-- On enter only: a handler now hears about the leave too, and
			-- setting the edge cursor on the way OUT is how a stale resize
			-- cursor gets stranded over the next thing. Leaving to bare chrome
			-- resets through on_hover's fallthrough; leaving onto a client
			-- leaves the cursor to C and the client.
			on_hover = function(over)
				if over then
					core.input.set_cursor(state.theme.cursors.resize[s.e])
				end
			end,
		})
	end
end

-- The composite client: column#client-<handle> of the titlebar row
-- over the surface place-leaf, bordered and rounded, colored by focus. Clay's
-- column solve subtracts the fixed titlebar height from the grow surface, so
-- the client is configured to the reduced box with no workarea math. A client
-- with c.titlebar == false is just the surface in the same bordered column, so
-- decoration presence is Lua policy read here, never a C frame.
--
-- Padding is the border width because a Clay border overlaps its contents
-- instead of reserving space: with no padding the ring paints over the titlebar
-- and over the surface, and the client is configured wider than it can show.
function widgets.client(c, cfg)
	cfg = cfg or {}
	local th = state.theme
	local focused = client.focus == c
	-- Border state is just the next declare reading properties:
	-- focused wins, else an urgent client flags itself, else the border sinks
	-- into the background so only the focus ring carries contrast.
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
		-- The surface grows to fill the composite. For a float the composite is
		-- a Lua-owned box (c.float, see layout.float_client) that
		-- commit_size never rewrites, so the surface fills the width with no gap
		-- and the client is not re-shrunk by the chrome each frame.
		ui.surface(c, { w = "grow", h = "grow" })
		-- Resize handles overlay the surface, one z above this client's own
		-- float (cfg.z, threaded from the layout's band slot); only a
		-- floating client owns a draggable geometry.
		if c.floating then
			widgets.resize_handles(c, cfg.z)
		end
	end)
end

-- Stdlib exemplars, written in the public API only.

-- THE HANDLER TABLE (`cfg.on`). A stdlib widget wires the one gesture it can
-- name by itself; every other gesture is policy, and a config that wanted one
-- had to fork the whole widget, losing ui.each with it. `on` is that policy as
-- named gestures, each a plain function, the shape widgets.filter already takes
-- here: `press(item, ev)` and `scroll(ev)`. Gestures are named rather than
-- matched because ev.button and ev.mods already say which chord arrived, and
-- `on` is a sub-table because `on_press` is already an ELEMENT cfg key meaning
-- "this box's own edge".
--
-- A handler receives WHAT THE CALL SITE CANNOT ALREADY KNOW: press gets the item
-- the gesture landed on, scroll gets nothing but the ev, because the screen and
-- the tag are arguments the caller passed in and has closed over.
--
-- A handler PREEMPTS: truthy means handled and the stdlib default does not run,
-- nil means declined and it does, which is the house convention
-- (grab.route_key, kiln.menu.nav). Silent replacement would make every config
-- taking a press re-implement view / focus / cycle, which IS the fork being
-- deleted. Only press has a default; scroll is pass-through on all three.
local function handled(fn, item, ev)
	return fn ~= nil and fn(item, ev)
end

function widgets.taglist(s, cfg)
	cfg = cfg or {}
	local on = cfg.on or {}
	local th = state.theme
	-- The cells live in a row of the widget's own, so the wheel has somewhere to
	-- land: the wheel over a taglist is about the list, and most of a taglist's
	-- area is the gaps between its cells.
	ui.row({
		id = "taglist:" .. s.name,
		gap = 4, align = { y = "center" },
		on_scroll = on.scroll,
	}, function()
		for i, t in ipairs(s.tags) do
			local occupied = #t.clients > 0
			ui.box({
				id = { "tag", i },
				-- t.selected, not an identity test against selected_tag: with two
				-- tags viewed at once, both are highlighted. Only a viewed cell
				-- carries a fill, so the rest read as plain labels.
				color = t.selected and th.accent or nil,
				-- Cells FIT their label. A fixed width clips the longer tag
				-- names, and a taglist that cannot show its own names is broken
				-- however the gestures are wired.
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
				-- A 4px mark floated into the cell's corner when the tag holds
				-- clients, filled when one of them has focus. It belongs to the
				-- widget rather than to a config because a config cannot float
				-- a child into a cell it does not declare. passthrough: a mark
				-- is a label, not a target, and a capturing float would eat the
				-- corner of its own cell's press.
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

-- Is this client on any tag the screen is currently showing? Tag VISIBILITY,
-- not tag identity: a client can be on several tags and a screen can be viewing
-- several at once, so neither side is a scalar to compare.
local function on_screen(c, s)
	for _, t in ipairs(c.tags or {}) do
		if t.screen == s and t.selected then
			return true
		end
	end
	return false
end

-- A tasklist filter is a predicate (client, screen), not a class, not a
-- registry: the whole extension point is "write a function". These three are
-- the exemplars, and any rc.lua predicate is their equal.
widgets.filter = {
	currenttags = on_screen,
	alltags = function()
		return true
	end,
	minimized = function(c, s)
		return c.minimized and on_screen(c, s)
	end,
}

-- Module level, not per call: ui.each scopes its per-key state store by this
-- function's identity, so a fresh closure each frame would be a fresh store.
local function task_key(c)
	return "task:" .. c.handle
end

-- widgets.tasklist: one declare fn over the clients of a screen, keyed by
-- handle. No model, no cache, no update path. Map, unmap, focus, minimize, a
-- title change and a tag switch all already dirty the screen, so every one of
-- them is just this function running again against the current facts.
function widgets.tasklist(s, cfg)
	cfg = cfg or {}
	local on = cfg.on or {}
	local th = state.theme
	local filter = cfg.filter or widgets.filter.currenttags
	local cs, seen = {}, {}
	for _, t in ipairs(s.tags) do
		for _, c in ipairs(t.clients) do
			-- Deduped: a client on two tags is on two client lists, and it is
			-- still one window, so it is still one row.
			--
			-- Unmapped and override-redirect clients are never tasks; that is
			-- not a filter's business, it is what a task IS.
			if not seen[c] and c.mapped and not c.override_redirect
					and filter(c, s) then
				seen[c] = true
				table.insert(cs, c)
			end
		end
	end
	-- The rows live in a row of the widget's own, for the taglist's reason: the
	-- wheel over a tasklist is about the list.
	ui.row({
		id = "tasklist:" .. s.name,
		gap = 4, align = { y = "center" },
		on_scroll = on.scroll,
	}, function()
		local slot = 0
		ui.each(cs, task_key, function(c, id)
			-- The clip below is keyed by ROW POSITION while the row itself stays
			-- keyed by handle, and the split is load-bearing. Clay makes every
			-- clipping element a scroll container, keeps ten per context, and
			-- frees a slot only inside the helper this project prohibits, so a
			-- clip id that varies per window spends a slot per window opened and
			-- aborts the compositor on the eleventh one ever. Positions are
			-- reused, so what is spent is bounded by how many rows a screen shows
			-- at once rather than by how many windows have ever existed.
			slot = slot + 1
			local clip_id = "taskclip:" .. s.name .. ":" .. slot
			ui.row({
				id = id,
				w = cfg.width or { "grow", max = 180 }, h = "grow",
				pad = { x = 6 }, gap = 4, align = { y = "center" },
				radius = 3,
				-- State read at declare, no styling subsystem. Only the focused
				-- row carries a fill, so the rest sit on the bar with no cell
				-- of their own.
				color = c == client.focus and th.accent
					or (c.urgent and th.urgent or nil),
				on_press = function(ev)
					if handled(on.press, c, ev) then
						return
					end
					-- Restoring goes through the same request the client itself
					-- raises, so a config that replaced the minimize policy
					-- governs this press too.
					if c.minimized then
						c:emit("request::minimize", false)
					end
					c:focus()
				end,
			}, function()
				-- Icon slot: the client's icon when one resolves, a placeholder
				-- square when none does (the same slot widgets.titlebar keeps).
				-- Named by handle so core.hits can find the cell; the id lets a
				-- probe assert the icon is live, and stays put across the
				-- placeholder branch.
				local ic = icon.client(c)
				if ic ~= nil then
					ui.image(ic, { id = { "taskicon", c.handle },
						w = 10, h = 10 })
				else
					ui.box({ id = { "taskicon", c.handle }, w = 10, h = 10,
						color = th.muted, radius = 2 })
				end
				-- What bounds the label: the row is only as wide as its max, and
				-- this box is what turns the width left over from the icon into
				-- something the title has to answer to. One line, always, because
				-- a clipping parent leaves its children at full width rather than
				-- compressing them, so a long title overflows along one line
				-- instead of wrapping onto a second one a bar has no height for.
				-- The ellipsis then ends what the clip would have cut mid-glyph.
				--
				-- Inner rather than on the row, so the cut lands inside the row's
				-- padding instead of against its outer edge, which is what a
				-- scissor taken at a clipping box's own bounds would have done.
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

-- Module level, like task_key: ui.each scopes its per-key store by this fn's
-- identity, so a fresh closure each frame would be a fresh store.
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
				core.tray_activate(it.service, "activate", 0)
			end,
			on_scroll = function(sev)
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

-- widgets.layoutbox: a box that IS t.layout, read at declare. Pressing it writes
-- the next layout onto the tag, and that write is the whole verb: the tag
-- property listener dirties the screen and the next solve is the new geometry,
-- so the box reflects by re-declaring, with no update path and nothing to keep
-- in sync.
function widgets.layoutbox(s, cfg)
	cfg = cfg or {}
	local on = cfg.on or {}
	local t = s.selected_tag
	if t == nil then
		return
	end
	-- Lazily required: kiln.layout requires this module, so a top-level require
	-- here would be a cycle. By the time a bar declares, the module is loaded.
	local layout = require("kiln.layout")
	ui.box({
		id = "layoutbox:" .. s.name,
		color = state.theme.bg2, radius = 4, pad = { x = 6 }, align = "center",
		on_press = function(ev)
			-- Read at press, not at declare: the viewed tag may have changed
			-- since the frame that drew this cell, and the write belongs to
			-- whichever tag is viewed now.
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
		-- The layout glyph comes from the theme, the way the menu chevron does:
		-- an image when the theme resolved one for this layout, the name as text
		-- when it did not. Keyed by FAMILY, because layout.name returns
		-- "family.variant" and every variant of a family shares its glyph.
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

-- widgets.layoutlist: the picker, which is a menu of the layouts. A list of
-- choices that dispatches on press is what ui.menu already is, so this is that,
-- not a second popup.
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

-- The clock redraws aligned to the minute rollover rather than on a
-- fixed cadence from load time, so the displayed minute is never stale.
-- The timer arms itself the first time the clock is actually declared.
local clock_scheduled = false
local function schedule_clock()
	local ms = (60 - (os.time() % 60)) * 1000 + 50
	core.timer(ms, function()
		core.dirty()
		schedule_clock()
	end)
end

function widgets.clock()
	if not clock_scheduled then
		clock_scheduled = true
		schedule_clock()
	end
	ui.text(os.date("%a %b %d  %H:%M"))
end

return widgets
