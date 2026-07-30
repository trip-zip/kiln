-- Layouts: a layout is a function over the tiled clients of the visible
-- tag, declaring place-leaves inside the workarea the runtime already
-- opened. Stacking is declaration order plus floats declared after.

local ui = require("kiln.ui")
-- Through the module table at every call, so a config that swaps a public
-- widget symbol governs the layouts too. widgets.lua lazy-requires this module
-- back, which is why this top-level require is not a load cycle.
local widgets = require("kiln.widgets")
local state = require("kiln.state")
local animation = require("kiln.animation")

local layout = {}

-- A layout is a function (clients, area, tag) declaring place-leaves inside the
-- workarea the runtime already opened. `area` is the box the layout's own
-- container fills (the workarea from the last solve, inset by the gap), for the
-- two layouts that need arithmetic: carousel's offset and magnifier's float. The
-- rest ignore it and let Clay solve.
--
-- The tag params a layout reads. Plain tag properties with defaults, so an
-- unconfigured tag still tiles. The factor is clamped into Clay's
-- legal percent range: a mad master_width_factor is a config typo, not a solver
-- error.
local function params(t)
	t = t or {}
	-- The eased factor while a resize animates, else the tag's own (animation.get
	-- returns dflt when idle). Keyed per tag so two tags animate independently.
	local f = animation.get("mwf:" .. tostring(t), t.master_width_factor or 0.5)
	f = math.max(0.05, math.min(0.95, f))
	return f, t.master_count or 1, t.gap or state.theme.gap, t.column_count or 1
end

-- Every layout below is the same two moves: open a container, fill it with a run
-- of clients as grow cells. This is that run, and it is where nearly every layout
-- declares its clients.
--
-- An empty run declares NOTHING, and that one line is what makes every layout
-- degrade correctly: an empty grow container is not empty to Clay, it is a
-- sibling that takes its share, so a corner with no side stack would hand half
-- its band to a hole instead of growing the master into it.
local function cells(open, cs, w, h, g)
	if #cs == 0 then
		return
	end
	open({ w = w, h = h, gap = g }, function()
		for _, c in ipairs(cs) do
			widgets.client(c)
		end
	end)
end

local function slice(cs, from, to)
	local out = {}
	for i = from, to do
		out[#out + 1] = cs[i]
	end
	return out
end

-- A layout with named variants: `layout.tile` is callable AND carries
-- `.left/.top/.bottom`. Lua functions hold no fields, so the dotted names
-- need a callable table. Nothing else changes: t.layout(cs, area, t)
-- calls it either way.
local function variants(fn, named)
	return setmetatable(named, { __call = function(_, ...) return fn(...) end })
end

-- tile: a master run sized "N%" beside a grow stack, split along the axis the
-- master's side names, master_count clients in the master and the rest in the
-- stack. With no stack the master grows to the whole area. The suffix names where
-- the STACK goes (AwesomeWM's convention), so tile.left is master-on-the-right.
local function tile_of(side)
	local horiz = side == "left" or side == "right"
	local master_first = side == "left" or side == "top"
	local split = horiz and ui.row or ui.column
	local run = horiz and ui.column or ui.row
	return function(cs, area, t)
		if #cs == 0 then
			return
		end
		local f, n, g, ncol = params(t)
		n = math.min(n, #cs)
		local stacked = #cs > n
		local size = stacked and (f * 100) .. "%" or "grow"
		local function master()
			cells(run, slice(cs, 1, n), horiz and size or "grow",
				horiz and "grow" or size, g)
		end
		-- The stack, split into column_count columns beside the master. cols is
		-- clamped to the client count so no column is ever empty, and the clients
		-- spread over the columns with fair's take formula (earlier columns take
		-- the ceil). At one column this is the single run it always was.
		local function stack()
			local rest = slice(cs, n + 1, #cs)
			local cols = math.min(ncol, #rest)
			if cols <= 1 then
				cells(run, rest, "grow", "grow", g)
				return
			end
			split({ w = "grow", h = "grow", gap = g }, function()
				local i = 1
				for c = 1, cols do
					local take = math.ceil((#rest - i + 1) / (cols - c + 1))
					cells(run, slice(rest, i, i + take - 1), "grow", "grow", g)
					i = i + take
				end
			end)
		end
		split({ w = "grow", h = "grow", gap = g }, function()
			if master_first then
				master()
				stack()
			else
				stack()
				master()
			end
		end)
	end
end

layout.tile = variants(tile_of("left"), {
	left = tile_of("right"),
	top = tile_of("bottom"),
	bottom = tile_of("top"),
})

-- fair: a balanced grid. ceil(sqrt(n)) columns, the clients spread over them so
-- an uneven count fills the earlier columns first. Every cell is a grow child, so
-- Clay does the division.
local function fair_of(horiz)
	local outer = horiz and ui.column or ui.row
	local run = horiz and ui.row or ui.column
	return function(cs, area, t)
		local n = #cs
		if n == 0 then
			return
		end
		local _, _, g = params(t)
		local cols = math.ceil(math.sqrt(n))
		outer({ w = "grow", h = "grow", gap = g }, function()
			local i = 1
			for c = 1, cols do
				local take = math.ceil((n - i + 1) / (cols - c + 1))
				cells(run, slice(cs, i, i + take - 1), "grow", "grow", g)
				i = i + take
			end
		end)
	end
end

layout.fair = variants(fair_of(false), { horizontal = fair_of(true) })

-- spiral and dwindle: each client takes half of what is left, the axis
-- alternating with depth. Two grow children per level IS the halving; there is no
-- arithmetic. dwindle always leads with the client, splitting toward the
-- bottom-right forever; spiral leads with the remainder every other pair of
-- levels, which is what winds the cells inward.
local function spiral_of(rotate)
	local function half(cs, i, step, g)
		if i == #cs then
			widgets.client(cs[i])
			return
		end
		local lead = not rotate or step % 4 < 2
		local open = step % 2 == 0 and ui.row or ui.column
		open({ w = "grow", h = "grow", gap = g }, function()
			if not lead then
				half(cs, i + 1, step + 1, g)
			end
			widgets.client(cs[i])
			if lead then
				half(cs, i + 1, step + 1, g)
			end
		end)
	end
	return function(cs, area, t)
		if #cs == 0 then
			return
		end
		local _, _, g = params(t)
		half(cs, 1, 0, g)
	end
end

layout.dwindle = spiral_of(false)
layout.spiral = spiral_of(true)

-- corner: the master fills one corner at the master factor on both axes, with a
-- stack down the far vertical edge and one across the far horizontal edge; the
-- remaining clients alternate between the two. A missing stack gives its space
-- back by growing the master, so corner degrades to max at one client.
local function corner_of(vert, horiz)
	local top, left = vert == "top", horiz == "left"
	return function(cs, area, t)
		if #cs == 0 then
			return
		end
		local f, _, g = params(t)
		local pct = (f * 100) .. "%"
		local side, foot = {}, {}
		for i = 2, #cs do
			table.insert(i % 2 == 0 and side or foot, cs[i])
		end
		local function band()
			ui.row({ w = "grow", h = #foot > 0 and pct or "grow", gap = g },
			function()
				if not left then
					cells(ui.column, side, "grow", "grow", g)
				end
				widgets.client(cs[1],
					{ w = #side > 0 and pct or "grow", h = "grow" })
				if left then
					cells(ui.column, side, "grow", "grow", g)
				end
			end)
		end
		ui.column({ w = "grow", h = "grow", gap = g }, function()
			if not top then
				cells(ui.row, foot, "grow", "grow", g)
			end
			band()
			if top then
				cells(ui.row, foot, "grow", "grow", g)
			end
		end)
	end
end

layout.corner = variants(corner_of("top", "left"), {
	nw = corner_of("top", "left"),
	ne = corner_of("top", "right"),
	sw = corner_of("bottom", "left"),
	se = corner_of("bottom", "right"),
})

-- magnifier: the unfocused clients tile behind as a column, the focused one is a
-- float centered in the area at the master factor of its size. The float z is one
-- under the normal band: Clay sorts floats at z >= 0 after the whole in-flow tree
-- (the background band, z < 0, sorts under it), so it covers every tile, and it
-- still sits below the runtime's own float slots, which start at the band
-- base.
function layout.magnifier(cs, area, t)
	if #cs == 0 then
		return
	end
	local f, _, g = params(t)
	local pick, back = cs[1], {}
	for _, c in ipairs(cs) do
		if c == client.focus then
			pick = c
		end
	end
	for _, c in ipairs(cs) do
		if c ~= pick then
			table.insert(back, c)
		end
	end
	cells(ui.column, back, "grow", "grow", g)
	ui.box({
		float = { to = "parent", anchor = "center", z = ui.bands.normal - 1 },
		w = math.floor(area.width * f), h = math.floor(area.height * f),
	}, function()
		widgets.client(pick, { w = "grow", h = "grow" })
	end)
end

-- carousel (spec s7, the Clay-expressibility proof): one clip row of fixed-width
-- columns on an infinite strip, scrolled by childOffset so the focused column is
-- centered. The offset is derived from focus at declare and clamped HERE to the
-- strip's ends, because Clay applies childOffset raw and its clamping helper is
-- prohibited (spec s6). No cross-frame state to keep: focus IS the state, and
-- `area` is the viewport, so this is one pass with no readback.
--
-- The clip crops the columns' chrome, never their surfaces: place-leaves are
-- scissor-exempt (so client popups can overhang), so a peeking client's
-- pixels run past the strip. The strip IS the workarea, so they run off the
-- output, and any bar they would cross is a float in a higher band and draws over
-- them. Containment is the output edge and the band order, not the clip.
function layout.carousel(cs, area, t)
	if #cs == 0 then
		return
	end
	local _, _, g = params(t)
	local w = area.width
	local col = math.max(1, math.floor(w * (t.carousel_width or 0.5)))
	local i = 1
	for k, c in ipairs(cs) do
		if c == client.focus then
			i = k
		end
	end
	local strip = #cs * col + (#cs - 1) * g
	local off = w / 2 - (i - 1) * (col + g) - col / 2
	off = math.max(math.min(0, w - strip), math.min(0, off))
	ui.row({
		id = "carousel:" .. t.screen.name,
		w = "grow", h = "grow", gap = g,
		clip = { horizontal = true, childOffset = { x = off, y = 0 } },
	}, function()
		for _, c in ipairs(cs) do
			widgets.client(c, { w = col, h = "grow" })
		end
	end)
end

function layout.max(cs)
	-- One client fills the workarea: the focused one if it is here,
	-- else the first. The others stay alive, just not declared.
	local pick = nil
	for _, c in ipairs(cs) do
		if c == client.focus then
			pick = c
		end
	end
	pick = pick or cs[1]
	if pick ~= nil then
		widgets.client(pick)
	end
end

-- Which band a client's float declares into: an explicit c.band
-- (set by a rule or rc.lua) wins; a fullscreen client is promoted to the
-- fullscreen band only while focused; an ontop client sits in the above band;
-- everything else is normal.
--
-- A band OUTRANKS the list: raising a normal float to the tail of its tag's
-- list still leaves it under an ontop one, because the band contributes the
-- thousands and the list only the slot within it. That is the whole of
-- ontop/above/below, collapsed to one boolean.
local function client_band(c)
	if c.band ~= nil then
		return c.band
	end
	if c.fullscreen and c == client.focus then
		return "fullscreen"
	end
	if c.ontop then
		return "above"
	end
	return "normal"
end

-- Within-band z slots: each declared float takes the next slot, two z apart
-- so its resize handles ride at slot z + 1 without crossing the next client.
-- This makes declaration order global across Clay's float roots; without it
-- a constant handle z floats above every sibling body (see
-- kiln.widgets.resize_handles).
local function slot_z(c, slots)
	slots.n = slots.n + 1
	return (ui.bands[client_band(c)] or ui.bands.normal) + slots.n * 2
end

-- One floating client at its remembered position and Lua-owned size. c.float is
-- ONE table { x, y, width, height }, replaced whole rather than mutated,
-- so a drag emits one property::float instead of four. It is the composite box
-- (surface plus titlebar) and it is persistent across float/unfloat: commit_size
-- rewrites only c.width/c.height (the surface), never this box, so the client is
-- not re-shrunk by the chrome each re-declare (the bug before this) and a resize
-- just replaces the table. Seeded once from the client's size plus the chrome
-- so floating keeps the client's size.
function layout.float_client(c, z)
	local th = state.theme
	-- The composite is the surface, the titlebar, and the border ring on every
	-- side. All three have to be added back here, or floating a tiled client
	-- seeds a box the chrome then eats and the surface comes out smaller.
	local edges = th.border_width * 2
	local chrome_h = (c.titlebar ~= false and th.titlebar_height or 0) + edges
	local f = c.float or {}
	if f.width == nil or f.height == nil then
		f = {
			x = f.x or 0,
			y = f.y or 0,
			width = f.width or ((c.width > 0 and c.width or 400) + edges),
			height = f.height or ((c.height > 0 and c.height or 300) + chrome_h),
		}
		c.float = f
	end
	ui.box({
		float = { to = "root", offset = { x = f.x, y = f.y }, z = z },
		w = f.width, h = f.height,
	}, function()
		widgets.client(c, { w = "grow", h = "grow", z = z })
	end)
end

-- Maximized clients: each fills the screen workarea,
-- declared as a float over the tiles. screen.workarea is the readback of the
-- last solve's workarea row, so this is one frame stale on a bar change, an
-- accepted tolerance; the very first solve has no prior box, so fall
-- back to the whole screen. List order is the stack, as everywhere else;
-- declared after the plain floats, so their higher slots keep them above.
function layout.declare_maximized(cs, s, slots)
	slots = slots or { n = 0 }
	local wa = s.workarea or { x = 0, y = 0, width = s.width, height = s.height }
	for _, c in ipairs(cs) do
		local z = slot_z(c, slots)
		ui.box({
			float = { to = "root", offset = { x = wa.x, y = wa.y }, z = z },
			w = wa.width, h = wa.height,
		}, function()
			widgets.client(c, { w = "grow", h = "grow", z = z })
		end)
	end
end

-- Fullscreen clients fill the whole screen, over the bars. The band choice is
-- the whole policy: focused means the fullscreen band, unfocused
-- means the client's normal band, where later-declared floats cover it.
-- c.fullscreen is maintained by the request::fullscreen default handler and by
-- c:toggle_fullscreen(); both are Lua, and C never sets it.
function layout.declare_fullscreen(cs, s, slots)
	slots = slots or { n = 0 }
	for _, c in ipairs(cs) do
		local z = slot_z(c, slots)
		ui.box({
			id = { "fullscreen", c.handle },
			float = { to = "root", offset = { x = 0, y = 0 }, z = z },
			w = s.width, h = s.height,
		}, function()
			-- ui.surface, not widgets.client: fullscreen means the client's own
			-- pixels edge to edge. A titlebar or border here would shrink the
			-- surface below the output box, which is not fullscreen.
			ui.surface(c, { w = "grow", h = "grow", z = z })
		end)
	end
end

-- Override-redirect windows, declared last at their own box:
-- the client owns the geometry (C never configures an OR surface), so the
-- declaration mirrors c.x/c.y/c.width/c.height verbatim, bare surface, no
-- chrome. Overlay-band z plus the shared slot counter puts a menu above
-- everything declared before it, focused-last games included. Coordinates
-- are X root coords, which equal screen coords on the single output at the
-- layout origin; multi-output X11 waits for a forcing fixture.
function layout.declare_or(cs, slots)
	slots = slots or { n = 0 }
	for _, c in ipairs(cs) do
		if c.width > 0 and c.height > 0 then
			slots.n = slots.n + 1
			local z = ui.bands.overlay + slots.n * 2
			-- ui.surface, not widgets.client: no border, no titlebar, no
			-- handles; a menu is exactly its pixels.
			ui.box({
				id = { "or", c.handle },
				float = { to = "root", offset = { x = c.x, y = c.y }, z = z },
				w = c.width, h = c.height,
			}, function()
				ui.surface(c, { w = "grow", h = "grow" })
			end)
		end
	end
end

-- Protocol layer -> band: a layer surface declares into the band
-- its protocol layer names. The mapping is the whole policy; C reports the
-- protocol name verbatim and knows no bands.
local layer_band = {
	background = "background",
	bottom = "below",
	top = "above",
	overlay = "overlay",
}

-- Protocol anchors and margins as a Clay attach point plus offset within
-- whatever box the float attaches to (strut strip, workarea, or screen):
-- anchored edges pin, margins offset inward, unanchored axes center with
-- margin imbalance shifting the midpoint. Replaces per-screen numeric
-- arithmetic, so the same positioning works against any target box.
local function attach_of(a, m)
	local h, x, v, y
	if a.left and a.right then
		h, x = "center", (m.left - m.right) / 2
	elseif a.left then
		h, x = "left", m.left
	elseif a.right then
		h, x = "right", -m.right
	else
		h, x = "center", 0
	end
	if a.top and a.bottom then
		v, y = "center", (m.top - m.bottom) / 2
	elseif a.top then
		v, y = "top", m.top
	elseif a.bottom then
		v, y = "bottom", -m.bottom
	else
		v, y = "center", 0
	end
	return h .. "_" .. v, math.floor(x + 0.5), math.floor(y + 0.5)
end

-- One layer surface as a bare place-leaf (it draws its own pixels, no
-- chrome) floated at its protocol position within the attach target. Sized
-- by the answered configure (l.w/l.h); a client that
-- commits a different buffer size shows it at this box until its next
-- state-changing commit, the accepted tolerance. Shares the slots counter
-- so declaration order is the within-band tiebreak like every other float.
local function declare_layer(l, slots, to, parent)
	local anchor, x, y = attach_of(l.anchors, l.margin)
	slots.n = slots.n + 1
	ui.box({
		id = { "layer", l.handle },
		float = {
			to = to, parent = parent, anchor = anchor,
			offset = { x = x, y = y },
			z = (ui.bands[layer_band[l.layer]] or ui.bands.above)
				+ slots.n * 2,
		},
		w = l.w, h = l.h,
	}, function()
		ui.surface(l, { w = "grow", h = "grow" })
	end)
end

-- The edge a layer surface's exclusive zone reserves (the protocol rule,
-- mirrored from wlr_layer_surface_v1_get_exclusive_edge): a positive zone
-- anchored to exactly one edge, or to one edge plus both perpendicular
-- ones, reserves that edge; any other anchor set reserves nothing. A
-- surface with no answered size yet reserves nothing either (the broken
-- handler degradation: absent, not a stale hole).
function layout.strut_edge(l)
	if (l.exclusive or 0) <= 0 or (l.w or 0) <= 0 or (l.h or 0) <= 0 then
		return nil
	end
	local a = l.anchors
	local x = (a.left and 1 or 0) + (a.right and 1 or 0)
	local y = (a.top and 1 or 0) + (a.bottom and 1 or 0)
	if y == 1 and x ~= 1 then
		return a.top and "top" or "bottom"
	end
	if x == 1 and y ~= 1 then
		return a.left and "left" or "right"
	end
	return nil
end

-- A reserving layer surface's zone in the fold: an in-flow strip of the
-- reserved thickness (exclusive px plus the anchored-edge margin, the
-- protocol's usable-area arithmetic) with the surface floated inside at
-- its protocol position. A surface taller than its zone legally overhangs
-- the strip; only the strip subtracts.
function layout.declare_layer_strut(l, edge, slots)
	local px = l.exclusive + l.margin[edge]
	local horiz = edge == "left" or edge == "right"
	ui.box({
		w = horiz and px or "grow",
		h = horiz and "grow" or px,
	}, function()
		declare_layer(l, slots, "parent")
	end)
end

-- The fold's zone list: every exclusive zone in deterministic
-- order, band top-down then declaration order within a band, chrome zones
-- (bars, pre-shaped by the runtime as {edge, band, declare}) before layer
-- surfaces. Layer surfaces that reserve nothing collect in `loose` for
-- declare_layers after the fold.
local band_order =
	{ "overlay", "fullscreen", "above", "normal", "below", "background" }

function layout.strut_zones(chrome, layers, loose, slots)
	local by_band = {}
	for _, b in ipairs(band_order) do
		by_band[b] = {}
	end
	for _, z in ipairs(chrome) do
		table.insert(by_band[z.band] or by_band.above, z)
	end
	for _, l in ipairs(layers) do
		local edge = layout.strut_edge(l)
		if edge == nil then
			table.insert(loose, l)
		else
			table.insert(by_band[layer_band[l.layer]] or by_band.above, {
				edge = edge,
				declare = function()
					layout.declare_layer_strut(l, edge, slots)
				end,
			})
		end
	end
	local zones = {}
	for _, b in ipairs(band_order) do
		for _, z in ipairs(by_band[b]) do
			table.insert(zones, z)
		end
	end
	return zones
end

-- The fold itself: each zone wraps the remainder as a nested
-- flow container that peels its anchored edge, so subtraction is
-- sequential by construction (two top zones nest and the second starts
-- where the first ended, never per-edge MAX) and the solver computes what
-- remains. inner() declares the workarea grow node at the innermost
-- level; nothing stores its box.
function layout.fold_struts(zones, i, inner)
	local z = zones[i]
	if z == nil then
		inner()
		return
	end
	local open = (z.edge == "left" or z.edge == "right") and ui.row
		or ui.column
	open({ w = "grow", h = "grow" }, function()
		local leading = z.edge == "top" or z.edge == "left"
		if leading then
			z.declare()
		end
		layout.fold_struts(zones, i + 1, inner)
		if not leading then
			z.declare()
		end
	end)
end

-- Non-reserving layer surfaces: exclusive -1 positions against the full
-- screen (the protocol's "ignore exclusive zones"), everything else
-- against the workarea, so a centered launcher respects reserved bars.
-- Must run after the workarea node is declared, though not because within-frame
-- order is what attachment reads: Clay's parentId hashmap persists across
-- frames, so what a float cannot survive is a target that has NEVER been
-- declared, which is a Clay error and aborts. The frame handler declares the
-- workarea ahead of this on every frame including the first, so the constraint
-- is met by construction.
function layout.declare_layers(ls, slots, workarea_id)
	slots = slots or { n = 0 }
	for _, l in ipairs(ls) do
		if (l.w or 0) > 0 and (l.h or 0) > 0 then
			if (l.exclusive or 0) < 0 then
				declare_layer(l, slots, "root")
			else
				declare_layer(l, slots, "element", workarea_id)
			end
		end
	end
end

-- Declare a set of floating clients in LIST ORDER, which is the stack.
-- There is no focused-last hoist here: focus raises through the list (a
-- client.on("focus") policy in init.lua), so the list already has the focused
-- client at the tail and a second authority here could only disagree with it.
-- The runtime uses this for the floats mixed into any layout, and
-- layout.floating is just this over every client on the tag.
function layout.declare_floats(cs, slots)
	slots = slots or { n = 0 }
	for _, c in ipairs(cs) do
		layout.float_client(c, slot_z(c, slots))
	end
end

function layout.floating(cs)
	layout.declare_floats(cs)
end

-- Layout names: a layoutbox displays what t.layout
-- IS, and a layout is a bare function, so the name has to come from somewhere.
-- An explicit ordered list, never a pairs() walk of this module, which would
-- sweep up declare_floats, strut_zones, and every other helper above.
--
-- layout.list is the default CYCLE (one entry per family). Every named variant
-- still resolves through layout.name, so a tag left on tile.left displays as
-- "tile.left"; cycling from there just starts the list over, because a variant
-- is a destination a config picks, not a step in the rotation.
layout.list = {}
local names = {}
for _, name in ipairs({ "tile", "fair", "dwindle", "spiral", "corner",
		"magnifier", "carousel", "max", "floating" }) do
	local fn = layout[name]
	names[fn] = name
	table.insert(layout.list, fn)
	-- A callable table is a family (see variants): its keys are the variants.
	if type(fn) == "table" then
		for suffix, variant in pairs(fn) do
			names[variant] = name .. "." .. suffix
		end
	end
end

function layout.name(fn)
	return names[fn]
end

function layout.next(fn)
	for i, f in ipairs(layout.list) do
		if f == fn then
			return layout.list[i % #layout.list + 1]
		end
	end
	return layout.list[1]
end

return layout
