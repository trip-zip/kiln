-- The element layer: closure children over core.open/close, with one
-- friendly cfg table mapped onto Clay_ElementDeclaration. No layout
-- logic lives here; Clay solves everything.

local state = require("kiln.state")

local ui = {}

-- "#rrggbb" or "#rrggbbaa" to the {r,g,b,a} tables core.* expects.
local function to_color(v)
	if v == nil then
		return nil
	end
	if type(v) == "table" then
		return v
	end
	local r, g, b, a = v:match("^#(%x%x)(%x%x)(%x%x)(%x?%x?)$")
	if r == nil then
		error("bad color: " .. tostring(v), 3)
	end
	return {
		r = tonumber(r, 16),
		g = tonumber(g, 16),
		b = tonumber(b, 16),
		a = a ~= "" and tonumber(a, 16) or 255,
	}
end
ui.color = to_color

-- w/h: "fit" | "grow" | px | "N%" | { type, min =, max =, percent =, px = }
-- An omitted axis stays nil the whole way down: the declaration scratch is
-- zeroed before fill and sizing type zero is fit, so absence means fit
-- without any layer having to say so.
local function to_axis(v)
	if v == nil or type(v) == "number" then
		return v
	end
	if type(v) == "table" then
		return {
			type = v[1] or "fit",
			min = v.min, max = v.max,
			percent = v.percent, px = v.px,
		}
	end
	-- The string form reads as a human percentage; Clay's percent is a
	-- fraction of the parent, so the division lives here at the boundary.
	local pct = v:match("^(%d+%.?%d*)%%$")
	if pct ~= nil then
		return { type = "percent", percent = tonumber(pct) / 100 }
	end
	return { type = v }
end

-- dir: both the constructor vocabulary (row/column) and Clay's own
-- (ltr/ttb), so a cfg table can say what a constructor name would have
-- said. Anything else passes through and falls to the C default, the way
-- every other enum-shaped field already behaves.
local DIR = { row = "ltr", ltr = "ltr", column = "ttb", ttb = "ttb" }

local function to_padding(v)
	if v == nil then
		return nil
	end
	if type(v) == "number" then
		return { left = v, right = v, top = v, bottom = v }
	end
	return {
		left = v.left or v.x or 0,
		right = v.right or v.x or 0,
		top = v.top or v.y or 0,
		bottom = v.bottom or v.y or 0,
	}
end

local function to_alignment(v)
	if v == nil then
		return nil
	end
	if v == "center" then
		return { x = "center", y = "center" }
	end
	return { x = v.x, y = v.y }
end

-- A few friendly anchor names on top of Clay's own.
local anchor_names = {
	center = "center_center",
	top = "center_top",
	bottom = "center_bottom",
	left = "left_center",
	right = "right_center",
}

-- Stacking bands: a band is nothing but a z range convention for
-- floats (band index times 1000) plus a position in the declare sequence.
-- Pure Lua; C keeps no band enum. A float names its band
-- (`float = { band = "overlay" }`) and may add a small within-band z; equal
-- z resolves by declaration order (Clay's float sort is stable), which is
-- how focused-last works inside a band. background is negative because the
-- in-flow tree is z 0 and the sort is stable: a background float tying at 0
-- but declared later would draw OVER every tile and the bar.
local band_base = {
	background = -1000,
	below = 1000,
	normal = 2000,
	above = 3000,
	fullscreen = 4000,
	overlay = 5000,
}
ui.bands = band_base

local function name_of(a, dflt)
	return anchor_names[a] or a or dflt
end

-- Edge-aware floats. Clay puts a float exactly where its attach points say
-- and never asks whether that landed on screen; the whole of its placement is
-- one line of arithmetic, `parent.near + frac_parent * parent.size -
-- frac_element * own.size + offset`. `fit = true` answers the question the
-- solver does not, in two steps: MIRROR the attach pair on an axis that
-- overflows, which keeps the box beside its target, then OFFSET whatever
-- still overflows back inside the workarea, which does not. Mirror first
-- because it preserves the relationship.
--
-- Arithmetic over the last solve: the target's box, and this box's own SIZE.
-- Its own POSITION is never read back, because Clay's answer already contains
-- the previous frame's correction and correcting a corrected position
-- oscillates. So a float that changed size is one frame late, and one never
-- declared has no size at all: it declares uncorrected and marks its screen
-- for the frame that fixes it, the same honest cost ui.scroll's overscroll
-- pays. That mark fires at most once per id ever, because Clay's element
-- hashmap persists across frames, so it cannot spin.
local frac = { left = 0, top = 0, center = 0.5, right = 1, bottom = 1 }
local mirror = { left = "right", right = "left", center = "center",
	top = "bottom", bottom = "top" }

-- Where Clay will put this box on one axis: the solver's own attach
-- arithmetic, restated so the fit can be computed before the solve. It must
-- stay in step with the solver: a change here that Clay does not make puts
-- the box somewhere Clay will not.
local function span(pn, ps, p, e, size, off)
	return pn + frac[p] * ps - frac[e] * size + off
end

local function over(v, size, lo, hi)
	return math.max(lo - v, 0) + math.max(v + size - hi, 0)
end

-- One axis of the two steps. p/e are the attach point halves on this axis, pn/ps
-- the target's near edge and size, lo/hi the workarea's edges. Returns the two
-- halves and the offset to declare.
local function fit_axis(p, e, off, pn, ps, size, lo, hi, may_mirror)
	local v = span(pn, ps, p, e, size, off)
	if may_mirror then
		local mp, me, mo = mirror[p], mirror[e], -off
		local mv = span(pn, ps, mp, me, size, mo)
		-- Strictly better only, so a screen too narrow for either side does not
		-- flap between them frame to frame.
		if over(mv, size, lo, hi) < over(v, size, lo, hi) then
			p, e, off, v = mp, me, mo, mv
		end
	end
	-- A box larger than the workarea has nowhere legal to sit: pin its near edge
	-- rather than push its far one past, which is placement.lua's posture too.
	return p, e, off + math.max(lo - v, math.min(0, hi - size - v))
end

-- Rewrites a floating config in place. The box Clay attaches to is the named
-- element, or for a root attach the root container, which is what kiln's own
-- "root" column fills.
local function fit(f, id)
	local b = id ~= nil and core.box(id) or nil
	if b == nil then
		core.dirty(state.screen_name)
		return
	end
	local par = core.box(f.attachTo == "root" and "root" or f.parentId)
	local wa = core.box("workarea:" .. (state.screen_name or ""))
	if par == nil or wa == nil then
		return
	end
	local px, py = f.attachPoints.parent:match("^(%a+)_(%a+)$")
	local ex, ey = f.attachPoints.element:match("^(%a+)_(%a+)$")
	local off = f.offset or {}
	-- Mirroring a ROOT attach would throw the box to the far side of the screen,
	-- which is not a flip of anything: only an element attach has a target to
	-- stay beside. Root floats clamp only.
	local m = f.attachTo == "element"
	local ox, oy
	px, ex, ox = fit_axis(px, ex, off.x or 0, par.x, par.width, b.width,
		wa.x, wa.x + wa.width, m)
	py, ey, oy = fit_axis(py, ey, off.y or 0, par.y, par.height, b.height,
		wa.y, wa.y + wa.height, m)
	f.attachPoints.parent = px .. "_" .. py
	f.attachPoints.element = ex .. "_" .. ey
	f.offset = { x = ox, y = oy }
end

-- Clay's floating attach is TWO points: the point on the element, and the
-- point on the parent it lands on. A single `anchor` names both, which covers
-- every float declared so far and reads well: anchor = "top" centers this box
-- on the parent's top. But the two points are independent in the solver, and
-- a submenu is the case that needs them to differ: its LEFT edge attaches to
-- its parent row's RIGHT edge, so it opens beside the menu rather than back
-- over it. So anchor also takes a pair. This exposes a field C already
-- forwards; it is not a new cfg key, it is an existing one finally saying
-- everything the attach field can say.
local function to_floating(v, id)
	if v == nil then
		return nil
	end
	local a = v.anchor
	local parent, element
	if type(a) == "table" then
		parent, element = name_of(a.parent, "left_top"), name_of(a.element, "left_top")
	else
		parent = name_of(a, "left_top")
		element = parent
	end
	local z = v.z
	if v.band ~= nil then
		z = (band_base[v.band] or band_base.normal) + (z or 0)
	end
	-- expand grows the float's own box WITHOUT moving or resizing its children,
	-- which makes it the way to give a popup a margin that hits and paints
	-- without every child inheriting the inset a padding would have added. One
	-- number means both axes, the way pad does.
	local expand = v.expand
	if type(expand) == "number" then
		expand = { width = expand, height = expand }
	elseif expand ~= nil then
		expand = { width = expand.w or 0, height = expand.h or 0 }
	end
	local f = {
		-- An omitted `to` attaches to the parent: a float declared inside an
		-- element most often means "over the thing declaring me", so that is
		-- the default and "root" or "element" is the stated exception.
		attachTo = v.to or "parent",
		offset = v.offset,
		expand = expand,
		zIndex = z,
		parentId = v.parent,
		attachPoints = { parent = parent, element = element },
		pointerCaptureMode = v.passthrough and "passthrough" or "capture",
		clipTo = v.clip and "attached_parent" or nil,
	}
	if v.fit then
		fit(f, id)
	end
	return f
end

local handler_names = { "on_press", "on_release", "on_hover", "on_scroll" }

-- Maps the public cfg to a core.open declaration, registering any
-- handlers under the element's id (auto-assigned when absent). This runs
-- once per element per frame, so the common no-handler / few-fields case
-- avoids the handler scan and the helper calls for absent fields.
local function to_declaration(cfg, direction)
	local id = cfg.id
	if cfg.on_press or cfg.on_release or cfg.on_hover or cfg.on_scroll then
		if id == nil then
			state.press_n = state.press_n + 1
			id = { "press", state.press_n }
		end
		local key
		if type(id) == "table" then
			key = id[1] .. "#" .. id[2]
		else
			key = id .. "#0"
		end
		for _, h in ipairs(handler_names) do
			if cfg[h] ~= nil then
				state.presses[h .. ":" .. key] = cfg[h]
			end
		end
	end

	-- `between` is Clay's betweenChildren: a rule drawn between this element's
	-- children rather than around the outside, as its own rect per gap. It lives
	-- inside the width table because that is where Clay keeps it, and the plain
	-- number shorthand leaves it at zero on purpose: Clay draws the same
	-- distinction with two macros, and a bare width means BORDER_OUTSIDE, not
	-- BORDER_ALL. A number that quietly ruled every gap would be a surprise.
	local border = nil
	if cfg.border ~= nil then
		local w = cfg.border.width or 1
		if type(w) == "number" then
			w = { left = w, right = w, top = w, bottom = w }
		else
			w = { left = w.left, right = w.right, top = w.top, bottom = w.bottom,
				betweenChildren = w.between }
		end
		border = { width = w, color = to_color(cfg.border.color) }
	end

	return {
		id = id,
		layout = {
			sizing = { width = to_axis(cfg.w), height = to_axis(cfg.h) },
			padding = cfg.pad and to_padding(cfg.pad) or nil,
			childGap = cfg.gap,
			childAlignment = cfg.align and to_alignment(cfg.align) or nil,
			layoutDirection = cfg.dir and (DIR[cfg.dir] or cfg.dir)
				or direction,
		},
		backgroundColor = cfg.color and to_color(cfg.color) or nil,
		cornerRadius = cfg.radius ~= nil and {
			topLeft = cfg.radius, topRight = cfg.radius,
			bottomLeft = cfg.radius, bottomRight = cfg.radius,
		} or nil,
		border = border,
		floating = cfg.float and to_floating(cfg.float, id) or nil,
		aspectRatio = cfg.aspect,
		clip = cfg.clip,
		image = cfg.image,
	}
end

function ui.box(cfg, children)
	core.open(to_declaration(cfg or {}, nil))
	if children ~= nil then
		children()
	end
	core.close()
end

function ui.row(cfg, children)
	core.open(to_declaration(cfg or {}, "ltr"))
	if children ~= nil then
		children()
	end
	core.close()
end

function ui.column(cfg, children)
	core.open(to_declaration(cfg or {}, "ttb"))
	if children ~= nil then
		children()
	end
	core.close()
end

-- A face by Pango description ("Sans Bold", "Monospace", "Iosevka Bold
-- Italic"), memoized to the id the declaration carries. Every text leaf resolves
-- one of these per frame, and the memo is what keeps that a table lookup rather
-- than a boundary crossing. It never needs clearing: an id is write-once on the
-- other side, so a cached answer cannot go stale.
local font_ids = {}
local function to_font(desc)
	local id = font_ids[desc]
	if id == nil then
		id = core.font(desc)
		font_ids[desc] = id
	end
	return id
end

-- cfg: color, size, font (a Pango description, size excluded: that is `size`),
-- wrap ("words"|"newlines"|"none"), align ("left"|"center"|"right", wrapped
-- lines within the text box), line_height (px per line, 0 = font height).
-- letterSpacing stays out: the Pango measure/raster path ignores it, so
-- exposing it would document a no-op.
--
-- ellipsize: end an overflowing run with an ellipsis instead of cutting it
-- mid-glyph. It needs an ancestor that clips horizontally, because a run's own
-- box is the width of its glyphs and carries no notion of the space it was meant
-- to fit; the clip is the only bound there is. With no such ancestor the flag
-- does nothing, which is why it is a leaf property and not a theme one.
--
-- The clip is taken at the clipping box's OUTER edge, so an ellipsis in a padded
-- box sits against the box edge rather than inside the padding. A caller who
-- wants the padding respected puts the clip on an inner box.
function ui.text(str, cfg)
	cfg = cfg or {}
	core.text(str, {
		textColor = to_color(cfg.color or state.theme.fg),
		fontSize = cfg.size or state.theme.font_size,
		fontId = to_font(cfg.font or state.theme.font),
		wrapMode = cfg.wrap,
		textAlignment = cfg.align,
		lineHeight = cfg.line_height,
		ellipsize = cfg.ellipsize,
	})
end

function ui.spacer()
	ui.box({ w = "grow" })
end

-- An image leaf. Images have no intrinsic measure (core decodes but does not
-- size), so the caller must size both axes, or one axis plus aspect. radius
-- rounds the corners at raster; the file is decoded once and cached by path.
--
-- recolor replaces the file's own colours with one ink and keeps only its
-- transparency, so a glyph drawn in any colour can be inked in any other. That
-- makes it a tool for shapes and glyphs, not for photographs: a multi-colour
-- image comes out flat. A zero-alpha ink means NO ink rather than an invisible
-- one, because the solver drops a fully transparent colour before the renderer
-- can see it. The same ink is reachable as plain `color` on a box that also
-- carries an image, because an image and a fill are one channel there, not two.
function ui.image(path, cfg)
	cfg = cfg or {}
	ui.box({
		id = cfg.id,
		image = { path = path },
		color = cfg.recolor,
		w = cfg.w, h = cfg.h,
		aspect = cfg.aspect,
		radius = cfg.radius,
		on_press = cfg.on_press,
	})
end

-- The place-leaf: the client's own scene tree, borrowed by the renderer at
-- the solved box. A childless custom leaf keyed by the handle; nothing can be
-- its child (core.surface opens and closes it atomically), so the titlebar is
-- a sibling inside the composite column, never a child of the surface.
function ui.surface(c, cfg)
	if cfg ~= nil then
		core.surface(c.handle, to_declaration(cfg, nil))
	else
		core.surface(c.handle)
	end
end

-- Cross-frame scroll offsets, keyed by the container's stable id: widget
-- state lives in Lua tables, nowhere else. The wrapper owns this; C persists
-- nothing about scroll.
local scroll_offsets = {}

-- A scrollable viewport: a `.clip` container whose inner content column scrolls
-- via childOffset. The offset is Lua-owned, nudged by the wheel handler, and
-- clamped HERE at declare time against the last solve's viewport and content
-- boxes (core.box). Clay applies childOffset raw, so this is the only clamp;
-- content shrink costs at most one frame of overscroll, which the shrink's own
-- solve corrects next frame. The caller sizes the viewport (w/h) and declares
-- the content in `children`; a stable id is required (it keys the offset).
function ui.scroll(cfg, children)
	local id = cfg.id
	if id == nil then
		error("ui.scroll needs a stable id", 2)
	end
	local key, content_id
	if type(id) == "table" then
		key = id[1] .. "#" .. id[2]
		content_id = { id[1] .. ":content", id[2] }
	else
		key = id .. "#0"
		content_id = id .. ":content"
	end

	local off = scroll_offsets[key] or 0
	local vp = core.box(id)
	local ct = core.box(content_id)
	if vp ~= nil and ct ~= nil then
		local max = ct.height - vp.height
		if max < 0 then
			max = 0
		end
		off = math.max(-max, math.min(0, off))
	end
	scroll_offsets[key] = off

	local step = cfg.step or 40
	ui.box({
		id = id,
		w = cfg.w,
		h = cfg.h,
		color = cfg.color,
		pad = cfg.pad,
		clip = { vertical = true, childOffset = { x = 0, y = off } },
		on_scroll = function(ev)
			scroll_offsets[key] = (scroll_offsets[key] or 0)
				- (ev.dy or 0) * step
			core.dirty(ev.screen)
		end,
	}, function()
		ui.column({ id = content_id, w = "grow", h = "fit" }, children)
	end)
end

-- The blessed keyed-list helper: the ONE way to declare a dynamic
-- collection. key(item) returns the element id, so ids derive from a
-- caller-chosen key (a client handle, a tag name) and never from array
-- position: an index-keyed list migrates a row's id, and with it that row's
-- press handler and its Clay box, onto a different item the moment one is
-- removed. declare(item, id, st) gets a per-key state table this helper owns.
--
-- The sweep is the rebuild: `kept` is the state of exactly the keys declared
-- this pass, so a key that stops being declared drops its state with no
-- bookkeeping. Stores are scoped per call site (the key function's identity,
-- which is why a widget defines it at module level) AND per screen, because the
-- same widget on two monitors declares two different item sets, and a shared
-- store would let one screen's sweep drop the other's state. Weak keys, so a
-- caller that does build its key fn per frame leaks nothing.
local each_state = setmetatable({}, { __mode = "k" })

function ui.each(items, key, declare)
	local by_screen = each_state[key]
	if by_screen == nil then
		by_screen = {}
		each_state[key] = by_screen
	end
	local name = state.screen_name or ""
	local store, kept = by_screen[name] or {}, {}
	for _, item in ipairs(items) do
		local id = key(item)
		local st = store[id] or {}
		kept[id] = st
		declare(item, id, st)
	end
	by_screen[name] = kept
	return kept
end

-- One shared dirty listener per watched class signal, so rebuilding a
-- widget (or many widgets watching the same signal) does not stack
-- listeners on the class bus.
local watched = {}

-- A widget is a function that declares cells. watch wires class signals
-- to dirty marks; every wires a recurring timer. Custom and built-in
-- widgets are the same kind of thing.
function ui.widget(spec)
	local fn = spec.fn or spec[1]

	for _, name in ipairs(spec.watch or {}) do
		local class_name, signal = name:match("^(%w+)::(.+)$")
		local class = class_name ~= nil and _G[class_name] or nil
		if class == nil then
			error("ui.widget: bad watch name " .. tostring(name), 2)
		end
		if not watched[name] then
			watched[name] = true
			class.on(signal, function()
				core.dirty()
			end)
		end
	end

	if spec.every ~= nil then
		local function tick()
			core.timer(spec.every * 1000, function()
				core.dirty()
				tick()
			end)
		end
		tick()
	end

	return fn
end

-- A bar is cells in the screen's one Clay context, not a surface. It
-- reserves workarea by construction on whichever edge it names: the frame
-- handler nests each bar and the workarea in one flow container per edge.
-- cfg is ordinary element cfg plus `edge`; the frame handler fills the
-- documented defaults and forces only the along-edge axis to grow.
local bar_edges = { top = true, bottom = true, left = true, right = true }

function ui.bar(s, cfg, fn)
	cfg = cfg or {}
	-- Rejected here rather than in the frame handler: a typo'd edge caught
	-- per frame would error once per solve forever instead of once at the
	-- call that made it.
	if cfg.edge ~= nil and not bar_edges[cfg.edge] then
		error("ui.bar: bad edge: " .. tostring(cfg.edge), 2)
	end
	table.insert(s.bars, { cfg = cfg, fn = fn })
	core.dirty(s.name)
end

return ui
