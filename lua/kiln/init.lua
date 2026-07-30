-- The kiln library: the whole config API as pure Lua over the core.*
-- primitives and origin events. Nothing here talks to Wayland; nothing
-- in C knows any of these concepts exist.

-- Line-buffer stdout so print() reaches the log as it happens. Every battery
-- redirects the compositor's stdout to a file, where libc block-buffers by
-- default: a print() then sits in the buffer until it fills or the process
-- exits cleanly, so a log grep run against a LIVE compositor reads nothing
-- and an assert built on one passes vacuously.
io.stdout:setvbuf("line")

-- The FFI boundary, first: it installs the verbs C no longer registers back
-- onto the `core` table, so everything below (and every IPC snippet) sees one
-- primitive namespace and cannot tell which transport a verb is on.
require("kiln.cffi")

local Bus = require("kiln.bus")
local object = require("kiln.object")
local state = require("kiln.state")

local kiln = {}
kiln.theme = state.theme
-- The modifier that "mod" resolves to in key/button specs. Read live at
-- binding time, so a config can set kiln.modkey before its key {} calls.
kiln.modkey = state.modkey

-- ---------------------------------------------------------------------
-- The classes. Globals: client, screen, tag.

client = object.class("client")
screen = object.class("screen")
tag = object.class("tag")
-- Layer-shell surfaces: same handle space as clients, own class.
-- Facts live on the object (namespace, layer, anchors, margin, exclusive,
-- interactivity, desired size); the answered size (l.w/l.h) is set by
-- whichever handler answers with core.layer_configure.
layer = object.class("layer")
-- DnD: not an object class (no handles, no instances),
-- just the informational start/end signal bus. drag.on("start"/"end", fn).
drag = require("kiln.drag")

-- The live list of screens, in add order. A class-level accessor so config
-- can enumerate monitors (screen.focused is the other public entry point).
function screen.all()
	return state.screens
end

-- screen.workarea is the box left after chrome, read back from the solver that
-- placed everything: core.box of the grow node the frame handler names
-- "workarea:<connector>". Computed each read, so it tracks re-tiling and
-- struts with no stored copy to keep in sync. Reflects the last solve of the
-- current context, so it is authoritative inside this screen's declare (where a
-- layout reads it) and single-output; a cross-screen read from elsewhere sees
-- whatever solved last, because core.box answers for whichever context solved
-- most recently.
screen.getters.workarea = function(s)
	return core.box("workarea:" .. s.name)
end

-- screen.canvas is the box Clay is solving into: the output less whatever the
-- compositor itself has taken off it, which today is the debug view's panel.
-- Read back from the solver like workarea, with the same context caveat, and
-- nil before the first solve.
--
-- It is not s.width/s.height. Those stay the OUTPUT's size, which is the right
-- answer for anything addressing the hardware and the wrong one for anything
-- that has to line up with the tree: a full-bleed float sized from the output
-- hangs its far edge under the panel while every grow-sized sibling reflows.
-- Chrome that grows needs no number at all; chrome that must RASTER an asset
-- for the box (a wallpaper) cannot ask Clay at declare time, and this is the
-- number it asks instead.
screen.getters.canvas = function()
	return core.box("root")
end

-- screen.scale is the output's fractional scale, read back from the one
-- output enumeration. Computed each read off core.output.list()
-- so a runtime core.output.set_scale is reflected with no stored copy to sync
-- (the `output change` event is only the poke; facts come from list()). Logical
-- geometry is unchanged by scale (the compositor solves in logical px by
-- construction); this is the sole scale surface config sees. Defaults to 1 if
-- the connector is momentarily absent from the list (hotplug race).
screen.getters.scale = function(s)
	for _, o in ipairs(core.output.list()) do
		if o.name == s.name then
			return o.scale
		end
	end
	return 1
end

-- The setter twin: s.scale = 1.5 drives the output verb, so config
-- sets scale through the same s.scale surface it reads and never reaches for
-- core.* itself. The new scale flows back through the list() the getter reads.
screen.setters.scale = function(s, v)
	core.output.set_scale(s.name, v)
end

local ui = require("kiln.ui")
local layout = require("kiln.layout")
local lockscreen = require("kiln.lockscreen")
local grabber = require("kiln.grab")
local prompt = require("kiln.prompt")
local menu = require("kiln.menu")
local hotkeys = require("kiln.hotkeys")
local tooltip = require("kiln.tooltip")
local hook = require("kiln.hook")
local popup = require("kiln.popup")
local placement = require("kiln.placement")
local animation = require("kiln.animation")
-- The module, not the class: `notification` is a global (the class), and this
-- local must not shadow it.
local notif = require("kiln.notification")
kiln.ui = ui
kiln.layout = layout
kiln.animation = animation
kiln.lockscreen = lockscreen
kiln.prompt = prompt
kiln.menu = menu
kiln.hotkeys = hotkeys
kiln.tooltip = tooltip
kiln.placement = placement
kiln.icon = require("kiln.icon")
kiln.asset = require("kiln.asset")
-- kiln.notify{} raises one; the notification class (a global, like tag) is the
-- bus everything else hangs off.
kiln.notify = notif.notify
-- The public name is ui.menu: the module lives beside the
-- prompt because it owns state and a declare hook, but ui.lua cannot require it
-- without a cycle, so the binding happens here. Same for the tooltip, whose
-- public face is the on_hover handler its text makes.
ui.menu = menu.show
ui.hotkeys = hotkeys.show
ui.tooltip = tooltip.attach
-- The per-frame declare slot that is not a bar. A hook runs inside every
-- screen's declare, so it is where chrome that floats belongs: no strut, no
-- reserved edge, and a position late enough to attach a float to the chrome
-- declared before it.
kiln.on_declare = hook.add
kiln.off_declare = hook.remove
-- The popup: the open-state, claim, scrim and declare quartet every piece of
-- chrome here was hand-rolling.
ui.popup = popup.new
-- The stock widgets: compositions of the primitives that read compositor state
-- and encode an opinion. Its own public namespace, not flattened onto ui.*,
-- because the two tiers are the API's one distinction: ui.* maps cfg onto Clay
-- and adds no policy, kiln.widgets.* is policy a config could have written.
kiln.widgets = require("kiln.widgets")
-- Poll a command and hold its answer. Async plumbing like kiln.spawn, which is
-- why it is a kiln.* name and not a ui.* one: nothing about it declares.
kiln.poll = require("kiln.poll").new
-- The app launcher: a prompt plus a result list declared through the registry.
local launcher = require("kiln.launcher")
kiln.launcher = launcher
-- The two grabs: a claim on the one input queue, outranking every
-- binding for as long as it holds. Both are pure Lua over one C routing bit.
kiln.keygrabber = grabber.keygrabber
kiln.mousegrabber = grabber.mousegrabber

-- Native session lock: thin wrappers over the C verbs. lock engages
-- the compositor's own lockscreen; unlock is refused in C unless a prior
-- core.authenticate succeeded, so these cannot be a bypass.
function kiln.lock()
	-- No Lua-side claim needed: from the instant core.lock() returns, C emits
	-- keys on the session channel, so no binding is reachable even before the
	-- session::lock event drains. The quarantine is never Lua's to hold.
	return core.lock()
end

function kiln.unlock()
	return core.unlock()
end

-- Auto-lock: arm the C idle timer for ms of no input; nil disarms. The three
-- idle::* facts it drives (start, stop, inhibit) arrive through kiln.on, so a
-- config wires idle to kiln.lock in a handful of lines. A thin wrapper for the
-- same reason kiln.lock is one: a config never touches core.*.
function kiln.set_idle_timeout(ms)
	return core.set_idle_timeout(ms)
end

-- The interactive-move grab: nil when idle, else the client being dragged
-- and the pointer/float anchor captured when the drag began. Motion updates
-- the float by the pointer delta (translation-invariant, so no per-screen
-- coordinate mapping is needed); button release ends it.
--
-- It is an ordinary mousegrabber (kiln.grab), not a second grab path: the
-- runtime's own drag is a claim on the same queue a config's mousegrabber
-- claims, and the router below knows only about claims.
local grab = nil
local grab_motion, start_drag

-- The button event currently being dispatched to a config handler, so a grab
-- started from one (function(c) c:grab_move() end) can read its press anchor
-- and terminating button. Set only around that call; nil otherwise.
local current_press = nil

local function dirty_screen(s)
	if s ~= nil then
		core.dirty(s.name)
	else
		core.dirty()
	end
end

local function remove_value(list, value)
	for i, v in ipairs(list) do
		if v == value then
			table.remove(list, i)
			return
		end
	end
end

local function contains(list, value)
	for _, v in ipairs(list or {}) do
		if v == value then
			return true
		end
	end
	return false
end

-- Forward-declared: the rules resolve a `screen = "eDP-1"` prop through it, and
-- they are defined above the frame handler that owns it.
local screen_by_name

-- Every screen a client is currently on. A client can be on several tags and
-- those tags can be on different screens, so the one-screen form this replaces
-- (dirty_screen(c.tag and c.tag.screen)) would have redrawn only the first.
local function dirty_client(c)
	for _, t in ipairs(c.tags or {}) do
		dirty_screen(t.screen)
	end
end

-- What a screen is showing: the union of its selected tags' client lists,
-- DEDUPED, because a client can be on two tags that are viewed at once and must
-- be declared exactly once (twice would be the same Clay id twice). The first
-- selected tag that names a client fixes its position, so the union has one
-- deterministic order and the stack stays the list.
local function visible_clients(s)
	local out, seen = {}, {}
	for _, t in ipairs(s.selected_tags or {}) do
		for _, c in ipairs(t.clients) do
			if not seen[c] then
				seen[c] = true
				table.insert(out, c)
			end
		end
	end
	-- Sticky clients ride every selection of their own screen: sweep the
	-- screen's tags and append any not already in the selected union. Appended
	-- last, so a sticky client stacks above the tiled union by construction, and
	-- screen tag order then list order keeps the union deterministic.
	for _, t in ipairs(s.tags or {}) do
		for _, c in ipairs(t.clients) do
			if c.sticky and not seen[c] then
				seen[c] = true
				table.insert(out, c)
			end
		end
	end
	return out
end

-- The client's tag membership. c.tags is the list and c.tag is sugar for
-- tags[1], so a config can keep writing the scalar and mean "only this tag".
-- Membership is a SETTER, not a property:: listener: the reconcile needs the
-- OLD list to diff against, and a listener runs after _data is overwritten.
client.getters.tag = function(c)
	local ts = c._data.tags
	return ts ~= nil and ts[1] or nil
end

client.setters.tag = function(c, t)
	c.tags = t ~= nil and { t } or {}
end

-- Derived, never stored: a client's screen is its first tag's screen.
client.getters.screen = function(c)
	local t = c.tag
	return t ~= nil and t.screen or nil
end

-- The parent client of a dialog, else nil. transient_for is the handle C
-- reports; the object is what a rule's `dialog` field and a config actually want.
client.getters.parent = function(c)
	local h = c._data.transient_for
	return h ~= nil and object.lookup(h) or nil
end

client.setters.tags = function(c, list)
	list = list or {}
	local old = c._data.tags or {}
	c._data.tags = list
	-- Each tag's client list is that tag's stack (the stack IS the list),
	-- so joining appends to the top and leaving removes in place. A tag the
	-- client was already on keeps its position: re-tagging is not a raise.
	for _, t in ipairs(old) do
		if not contains(list, t) then
			remove_value(t.clients, c)
			c:emit("untagged", t)
			dirty_screen(t.screen)
		end
	end
	for _, t in ipairs(list) do
		if not contains(old, t) then
			table.insert(t.clients, c)
			c:emit("tagged", t)
			dirty_screen(t.screen)
		end
	end
	-- Mirror the client's screen to its foreign-toplevel handle, so a taskbar can
	-- group by output (the budgeted output mirror). Screen is derived from the
	-- first tag; an untagged client leaves every output (nil). Tag membership is
	-- the only thing a client's screen depends on, so this is the one site that
	-- has to speak. Write-only and idempotent: C no-ops when the output is
	-- unchanged and when the client has no foreign handle yet.
	local s = list[1] ~= nil and list[1].screen or nil
	core.client.set_output_mirror(c.handle, s ~= nil and s.name or nil)
	c:emit("property::tags", list)
end

-- Stacking is a list op, and the list is the ONLY authority: there is no
-- focused-last hoist in the declare to disagree with it. raise moves
-- the client to the tail of every tag it is on, which is where the declare gets
-- to last, which is the top.
function client.methods:raise()
	for _, t in ipairs(self.tags or {}) do
		remove_value(t.clients, self)
		table.insert(t.clients, self)
	end
	dirty_client(self)
end

function client.methods:lower()
	for _, t in ipairs(self.tags or {}) do
		remove_value(t.clients, self)
		table.insert(t.clients, 1, self)
	end
	dirty_client(self)
end

-- Exchange two clients' positions in every tag they share. For tiled clients
-- that is the whole of "promote to master": the layout reads the list in order.
function client.methods:swap(other)
	if other == nil or other == self then
		return
	end
	for _, t in ipairs(self.tags or {}) do
		local i, j
		for k, c in ipairs(t.clients) do
			if c == self then
				i = k
			elseif c == other then
				j = k
			end
		end
		if i ~= nil and j ~= nil then
			t.clients[i], t.clients[j] = other, self
		end
	end
	dirty_client(self)
end

function client.all()
	local out = {}
	for _, s in ipairs(state.screens) do
		for _, t in ipairs(s.tags) do
			for _, c in ipairs(t.clients) do
				if not contains(out, c) then
					table.insert(out, c)
				end
			end
		end
	end
	return out
end

function client.methods:focus()
	if client.focus == self then
		return
	end
	-- Focus clears any urgency the client raised while unfocused: urgent is
	-- set by a request and cleared on focus.
	if self.urgent then
		self.urgent = false
	end
	-- focus and activation are separate C verbs; this one canonical method
	-- composes them, so a focused client always draws activated and the two
	-- never desync. The old client draws inactive; a stale handle no-ops.
	local prev = client.focus
	client.focus = self
	if self.tag ~= nil then
		screen.focused = self.tag.screen
	end
	if prev ~= nil and prev.handle ~= nil then
		core.client.set_activated(prev.handle, false)
	end
	core.client.set_activated(self.handle, true)
	core.client.focus(self.handle)
	self:emit("focus")
	-- Focus does not stack anything itself: raise-on-focus is a policy hung off
	-- the "focus" signal below, so every path that grants focus gets it and the
	-- list stays the one authority.
	dirty_client(self)
end

function client.methods:close()
	core.client.close(self.handle)
end

-- The impolite fallback: SIGKILL for a Wayland client, xcb_kill_client for an
-- X11 one (C picks by surface kind; killing X11 by pid would take down the
-- whole XWayland server).
function client.methods:kill()
	core.client.kill(self.handle)
end

-- The three window states are PLAIN PROPERTIES (property writes are the API;
-- methods only where a write cannot express one). `c.maximized = true` is
-- the whole verb; the listeners registered further down mirror the protocol
-- hint and re-declare. These toggles are sugar over that, nothing more.
function client.methods:toggle_maximized()
	self.maximized = not self.maximized
end

-- The layout promotes a fullscreen client to the fullscreen band while it is
-- focused; C stores no fullscreen state and resizes nothing.
function client.methods:toggle_fullscreen()
	self.fullscreen = not self.fullscreen
end

-- Minimized means the runtime stops declaring the client: not drawn, not hit,
-- not focusable, with no separate hidden state to keep in sync.
function client.methods:toggle_minimized()
	self.minimized = not self.minimized
end

-- Begin an interactive move: the client floats and follows the pointer until
-- the drag button is released. A move is driven by the button that starts it,
-- so it is only meaningful from a button handler (current_press is the press).
-- Called with no press (e.g. from a key) there is nothing to anchor or end
-- the drag, so refuse rather than strand the pointer.
function client.methods:grab_move()
	local p = current_press
	if p == nil then
		return
	end
	self.floating = true
	-- The tiled->floating reflow only shows once the screen re-declares; a
	-- mod+click with no motion would otherwise stay drawn as tiled.
	dirty_client(self)
	local f = self.float or {}
	start_drag({
		c = self, button = p.button,
		px0 = p.x, py0 = p.y,
		fx0 = f.x or 0, fy0 = f.y or 0,
	}, state.theme.cursors.move)
end

-- Begin an interactive resize from an edge/corner handle. edges is a compass
-- string ("n"/"se"/...): which sides follow the pointer. Mirrors grab_move but
-- snapshots the client's geometry, so a commit_size landing mid-drag (or a
-- min/max clamp) never corrupts the drag. Only reachable from a floating
-- client's handle press, so current_press anchors it.
function client.methods:grab_resize(edges)
	local p = current_press
	if p == nil then
		return
	end
	self.floating = true
	local f = self.float or {}
	start_drag({
		c = self, button = p.button, edges = edges,
		px0 = p.x, py0 = p.y,
		x0 = f.x or 0, y0 = f.y or 0,
		w0 = f.width or self.width, h0 = f.height or self.height,
	}, state.theme.cursors.resize[edges] or "default")
end

-- Resize from the corner nearest the press: the quadrant of the press
-- relative to the client center names the corner. A method because the press
-- position lives in current_press, which only the library sees.
function client.methods:grab_resize_nearest()
	local p = current_press
	if p == nil then
		return
	end
	local f = self.float or {}
	local w = f.width or (self.width > 0 and self.width or 400)
	local h = f.height or (self.height > 0 and self.height or 300)
	local cx = (f.x or 0) + w / 2
	local cy = (f.y or 0) + h / 2
	self:grab_resize((p.y < cy and "n" or "s") .. (p.x < cx and "w" or "e"))
end

-- A screen's selection is a LIST: selected_tags is the set being viewed,
-- selected_tag is sugar for the first of them. The layout params come from that
-- first tag, which is the whole of multi-select policy: no merge algebra.
screen.getters.selected_tag = function(s)
	local st = s._data.selected_tags
	return st ~= nil and st[1] or nil
end

screen.setters.selected_tag = function(s, t)
	s.selected_tags = t ~= nil and { t } or {}
end

screen.on("property::selected_tags", function(s)
	-- The tag-switch reveal: the incoming selection eases in from a small inset
	-- to full over 150ms, so the switch runs at panel rate on this screen alone
	-- (the animator ticks only s). Always from 0, restarting a switch mid-reveal.
	animation.start(s.name, "reveal:" .. s.name, 1, 0.15, 0)
	dirty_screen(s)
end)

-- Derived from the screen's selection, never stored, so it cannot go stale.
tag.getters.selected = function(t)
	local s = t.screen
	return s ~= nil and contains(s.selected_tags, t) or false
end

-- The setter twin of that getter. Without it `t.selected = true` writes a
-- _data field the getter permanently shadows: the write emits property::selected,
-- reads still answer the old value, and nothing anywhere changes. A derived
-- property that accepts writes and silently discards them is worse than one that
-- refuses them, so this routes the write to where the fact actually lives.
-- Selection order follows the screen's tag order, not write order, for the same
-- reason toggle() does: declare order (and so the stacking of the union) stays
-- deterministic. The selected_tags write carries the dirty and the reveal
-- animation with it, so there is no dirty here.
tag.setters.selected = function(t, v)
	local s = t.screen
	local want = v and true or false
	if s == nil or want == t.selected then
		return
	end
	local next_sel = {}
	for _, o in ipairs(s.tags) do
		if o == t then
			if want then
				table.insert(next_sel, o)
			end
		elseif o.selected then
			table.insert(next_sel, o)
		end
	end
	-- Same refusal as toggle(): a screen showing nothing is a dead end a user
	-- cannot click out of.
	if #next_sel == 0 then
		return
	end
	s.selected_tags = next_sel
end

-- Exclusive select.
function tag.methods:view()
	self.screen.selected_tags = { self }
end

-- Multi-select: add or remove this tag from the screen's selection, keeping the
-- screen's tag order so the declare order (and so the stacking of the union) is
-- deterministic rather than click order. Toggling the last selected tag off is
-- refused: a screen showing nothing is a dead end a user cannot click out of.
function tag.methods:toggle()
	local s = self.screen
	if s == nil then
		return
	end
	local next_sel = {}
	local want = not self.selected
	for _, t in ipairs(s.tags) do
		if t == self then
			if want then
				table.insert(next_sel, t)
			end
		elseif t.selected then
			table.insert(next_sel, t)
		end
	end
	if #next_sel == 0 then
		return
	end
	s.selected_tags = next_sel
end

-- Deleting a tag rehomes its clients rather than orphaning them: each one joins
-- the first surviving tag on the screen, in place of the tag it lost.
function tag.methods:delete()
	local s = self.screen
	if s == nil or #s.tags < 2 then
		return
	end
	local survivor
	for _, t in ipairs(s.tags) do
		if t ~= self then
			survivor = t
			break
		end
	end
	-- Over a copy: reassigning c.tags mutates self.clients underneath us.
	local leaving = {}
	for i, c in ipairs(self.clients) do
		leaving[i] = c
	end
	for _, c in ipairs(leaving) do
		local next_tags = {}
		for _, t in ipairs(c.tags) do
			if t ~= self then
				table.insert(next_tags, t)
			end
		end
		if #next_tags == 0 then
			table.insert(next_tags, survivor)
		end
		c.tags = next_tags
	end
	remove_value(s.tags, self)
	if self.selected then
		local next_sel = {}
		for _, t in ipairs(s.selected_tags) do
			if t ~= self then
				table.insert(next_sel, t)
			end
		end
		s.selected_tags = #next_sel > 0 and next_sel or { survivor }
	end
	dirty_screen(s)
end

-- tag.new registers on its screen and defaults to tile.
local tag_new = tag.new
function tag.new(props)
	local t = tag_new(props)
	if t.layout == nil then
		t.layout = layout.tile
	end
	if t.clients == nil then
		t.clients = {}
	end
	local s = t.screen
	if s ~= nil then
		table.insert(s.tags, t)
		if s.selected_tag == nil then
			s.selected_tag = t
		end
	end
	return t
end

-- The tag properties a layout reads. Writing one is the whole verb: the
-- listener re-declares the screen, and the next solve is the new geometry. No
-- setter, no re-arrange pass, no per-property plumbing. Visible, not selected:
-- a param on any tag in a multi-select union still changes what is drawn.
for _, prop in ipairs({ "layout", "master_width_factor", "master_count",
		"column_count", "gap", "carousel_width" }) do
	tag.on("property::" .. prop, function(t)
		if t.selected then
			dirty_screen(t.screen)
		end
	end)
end

-- t.name is the other half of what a tag draws, and it does NOT take the
-- `selected` guard above: the taglist renders every tag on the screen, selected
-- or not, so a rename of an unviewed tag still changes the frame.
tag.on("property::name", function(t)
	dirty_screen(t.screen)
end)

-- Tiled-resize animation. The master split is the one tiled resize a user
-- drives; ease it on the tick clock so the tiles slide to the new ratio
-- instead of snapping. layout.params reads the eased factor. The animation
-- re-solves ONLY through the tick clock, so the commit_size branch stays
-- no-dirty (its feedback loop is never reopened by an animation); the client
-- keeps up at panel rate.
tag.on("property::master_width_factor", function(t)
	if t.selected and t.screen ~= nil then
		animation.start(t.screen.name, "mwf:" .. tostring(t),
			t.master_width_factor)
	end
end)

local function focused_screen()
	return screen.focused or state.screens[1]
end

-- Focus history: the runtime's MRU list, maintained from the focus emission
-- (the one place focus is granted). Most recent at the front; a
-- client drops out when it unmaps or destroys. The successor is policy over it.
local history = {}

local function history_promote(c)
	remove_value(history, c)
	table.insert(history, 1, c)
end

client.on("focus", history_promote)

-- Focused-on-top, a one-line policy hung off the same
-- signal the history is: an out-of-flow client raises to the tail of its list
-- when focused, and that IS the stacking change. Tiled clients are deliberately
-- NOT raised, because their list position is their cell: raising one on focus
-- would slide the master out from under the user. Because this rides the signal
-- rather than the method, every path that grants focus gets it.
client.on("focus", function(c)
	if c.floating or c.fullscreen or c.maximized then
		c:raise()
	end
end)

-- client.history() is a read-only copy of the MRU list, so a custom successor or
-- a switcher can read focus order without holding the live table. It is a
-- callable table so client.history.previous can hang off it.
client.history = setmetatable({}, {
	__call = function()
		local copy = {}
		for i, c in ipairs(history) do
			copy[i] = c
		end
		return copy
	end,
})

-- The mod+Tab jump: the most recent client that is not the focused one.
function client.history.previous()
	for _, c in ipairs(history) do
		if c ~= client.focus and c.mapped and not c.minimized then
			return c
		end
	end
	return nil
end

-- Tag history: the last selections of each screen, so a config can flip
-- back to what it was showing. A property::
-- listener sees only the NEW value (object.lua), so the outgoing selection is
-- kept as a per-screen shadow and pushed onto the stack when the next one lands.
local tag_hist = {}

screen.on("property::selected_tags", function(s)
	local h = tag_hist[s.name] or {}
	if h.prev ~= nil then
		h[#h + 1] = h.prev
		if #h > 20 then table.remove(h, 1) end
	end
	h.prev = s.selected_tags
	tag_hist[s.name] = h
end)

tag.history = {}

-- Restore the previous selection. Because every selection write pushes the
-- outgoing set, this toggles between the last two selections. A popped set is
-- filtered against the live tags (one may have been deleted since); if nothing
-- survives, pop again. Boot is clean by construction: the first selection finds
-- a nil shadow and pushes nothing.
function tag.history.restore(s)
	s = s or focused_screen()
	local h = tag_hist[s.name]
	while h ~= nil and #h > 0 do
		local live = {}
		for _, t in ipairs(table.remove(h)) do
			if contains(s.tags, t) then live[#live + 1] = t end
		end
		if #live > 0 then
			s.selected_tags = live
			return
		end
	end
end

-- Replaceable policy defaults. The runtime connects these at boot; rc.lua
-- swaps any wholesale, no permissions framework: off/on the bus for a signal
-- handler, a plain field write for the successor. Focus itself is the one C
-- mechanism (core.client.focus); everything here is choice.
kiln.defaults = {}

-- The unmap successor: focus the most-recent live client on a VISIBLE tag of the
-- same screen, else clear. Policy over the focus history, not tag order. Tag
-- visibility, not tag identity: with two tags viewed at once, a client on the
-- second one is on screen and is a legal successor.
local function visible_on(c, s)
	for _, t in ipairs(c.tags or {}) do
		if t.screen == s and (t.selected or c.sticky) then
			return true
		end
	end
	return false
end

function kiln.defaults.successor(gone)
	local s = gone.screen
	if s == nil then
		return nil
	end
	for _, c in ipairs(history) do
		if c ~= gone and c.mapped and not c.minimized and visible_on(c, s) then
			return c
		end
	end
	return nil
end

-- request::activate arbitration: honor a user-initiated raise (a seat-backed
-- token), mark urgent on a background steal. The whole focus-stealing policy in
-- two lines, replaceable wholesale.
function kiln.defaults.activate(c, ctx)
	if ctx.valid then
		c:focus()
	else
		c.urgent = true
	end
end

client.on("request::activate", kiln.defaults.activate)

-- The layer-shell answer: a mapped or changed layer
-- surface's facts in, one core.layer_configure out. The only net the surface
-- has, replaceable wholesale; broken means visibly absent plus the C watchdog
-- log, never a C-synthesized configure. Standard protocol sizing: a zero
-- desired axis anchored to both opposite edges stretches between them minus
-- margins, everything else is honored as asked.
function kiln.defaults.layer(l)
	local s = l.screen
	if s == nil then
		return
	end
	local w, h = l.desired_w, l.desired_h
	if w == 0 and l.anchors.left and l.anchors.right then
		w = (s.width or 0) - l.margin.left - l.margin.right
	end
	if h == 0 and l.anchors.top and l.anchors.bottom then
		h = (s.height or 0) - l.margin.top - l.margin.bottom
	end
	l.w, l.h = w, h
	core.layer_configure(l.handle, w, h)
	dirty_screen(s)
end

-- Return the seat to the focused client (or clear) when a layer surface
-- lets the keyboard go.
local function layer_restore_keyboard()
	if client.focus ~= nil then
		core.client.focus(client.focus.handle)
	else
		core.client.focus(nil)
	end
end

-- Keyboard-interactivity arbitration, replaceable like activate:
-- exclusive takes the seat now and returns it when the surface unmaps,
-- destroys, or steps down; on_demand stays inert (pointer input already
-- forwards via the seat, and granting focus on a click is rc.lua policy).
function kiln.defaults.layer_keyboard(l)
	if l.interactivity == "exclusive" then
		if not l.kb_granted then
			l.kb_granted = true
			core.client.focus(l.handle)
		end
	elseif l.kb_granted then
		l.kb_granted = false
		layer_restore_keyboard()
	end
end

function kiln.defaults.layer_release(l)
	if l.kb_granted then
		l.kb_granted = false
		layer_restore_keyboard()
	end
end

layer.on("map", kiln.defaults.layer)
layer.on("commit", kiln.defaults.layer)
layer.on("map", kiln.defaults.layer_keyboard)
layer.on("commit", kiln.defaults.layer_keyboard)
layer.on("unmap", kiln.defaults.layer_release)
layer.on("destroy", kiln.defaults.layer_release)

-- The notification display: a replaceable default, but a DECLARE rather
-- than a listener, because that is what drawing is here. The declare tail calls
-- whatever this holds, so a config replaces the whole presentation with one
-- assignment, and sets it nil to draw nothing at all. There is no box factory
-- and no request::display.
kiln.defaults.notify_display = notif.display

-- Refocus after the focused client leaves: hand focus to whoever the successor
-- policy names (over the focus history), or clear if none.
local function refocus(gone)
	local succ = kiln.defaults.successor(gone)
	if succ ~= nil then
		succ:focus()
	else
		client.focus = nil
		core.client.focus(nil)
	end
end

-- The window states are properties, and THIS is where a write cashes out.
-- They sit here, below refocus, because minimize hands focus away. Each is the
-- same move and none of it is C's: mirror the granted state back with the hint
-- verb so the client draws itself to match (a fullscreen client drops its
-- rounding, a maximized one its shadow), and re-declare. C stores none of it.
--
-- Mirroring on the property (not in a method) is what makes `c.fullscreen = on`
-- the whole verb wherever it is written: a binding, a rule's props, a request
-- default, or rc.lua. The mixin only emits when the value actually changes, so
-- these cannot loop.
client.on("property::fullscreen", function(c, on)
	core.client.set_fullscreen_hint(c.handle, on and true or false)
	dirty_client(c)
end)

client.on("property::maximized", function(c, on)
	core.client.set_maximized_hint(c.handle, on and true or false)
	dirty_client(c)
end)

-- Minimize means the runtime stops declaring the client (the frame handler
-- skips it), which makes it invisible and unhittable by construction.
-- set_suspended is the standing hint for an undeclared client, so it can stop
-- drawing frames that have nowhere to go; set_minimized_hint mirrors the state
-- to the foreign-toplevel handle so a taskbar shows the client minimized (and,
-- on X11, writes WM_STATE iconic). Focus cannot stay on a window nothing draws,
-- so it goes to the successor, the same policy an unmap uses.
client.on("property::minimized", function(c, on)
	core.client.set_suspended(c.handle, on and true or false)
	core.client.set_minimized_hint(c.handle, on and true or false)
	if on and client.focus == c then
		refocus(c)
	end
	dirty_client(c)
end)

-- The rest of the declared state: nothing to mirror to C, just re-declare.
-- ontop is a BAND, read by the layout at declare; floating and float
-- are the geometry the layout reads; urgent is read by the border.
--
-- title, app_id and icon are what the titlebar and the tasklist row draw. The
-- metadata event writes them and dirties by hand, so these listeners are for the
-- OTHER writer: a config or an IPC caller relabelling a client directly.
--
-- The exclusions are the point of this being a list rather than a blanket
-- property::* listener. c.width/c.height are written per commit by the
-- commit_size branch, whose no-dirty is a standing invariant: a
-- client free to answer a size other than the one it was configured with would
-- pin the screen at panel rate. screen.width/height are worse, written as the
-- FIRST statement of the frame handler, so a dirty there is a render loop that
-- can never be starved out. Both are model facts about a frame already drawn,
-- never a reason to draw another.
for _, prop in ipairs({ "floating", "float", "ontop", "urgent", "titlebar",
		"sticky", "title", "app_id", "icon" }) do
	client.on("property::" .. prop, dirty_client)
end

-- The state requests: honored by default, replaceable
-- wholesale like every other default. A config that refuses an ask swaps the
-- handler off the bus and sets nothing: the client stays exactly where it is,
-- because nothing in C acted on the request. Each default is now a single
-- property write, because the property IS the verb.
function kiln.defaults.fullscreen(c, on)
	c.fullscreen = on
end

function kiln.defaults.maximize(c, on)
	c.maximized = on
end

function kiln.defaults.minimize(c, on)
	c.minimized = on
end

-- A foreign-toplevel client (a taskbar's close button) asked to close this
-- window. Same replaceable-wholesale shape: the default is the polite close
-- verb, and a config that wants a confirm dialog swaps it off the bus.
function kiln.defaults.close(c)
	c:close()
end

client.on("request::fullscreen", kiln.defaults.fullscreen)
client.on("request::maximize", kiln.defaults.maximize)
client.on("request::minimize", kiln.defaults.minimize)
client.on("request::close", kiln.defaults.close)

-- Move a client to another screen's selected tag. Both screens re-declare:
-- the source drops the leaf, the destination adds it. The renderer's owner
-- token keeps the client's one scene tree consistent across the handoff.
-- Focus follows the window to its new screen.
function client.methods:move_to(target)
	local dst = target ~= nil and target.selected_tag or nil
	if dst == nil or self.tag == dst then
		return
	end
	-- One membership write is the whole move: the tags setter drops the client
	-- from the old lists, appends it to the new one, and dirties both screens.
	self.tags = { dst }
	-- Focus follows the window. self:focus() early-returns when this client
	-- already held focus, so the active screen is set here directly rather
	-- than left pointing at the screen the window just left.
	screen.focused = dst.screen
	self:focus()
end

-- ---------------------------------------------------------------------
-- Keys and buttons. "mod" resolves through kiln.modkey; "1-9" ranges
-- expand into one binding per number, pressing with the index.

local mod_order = { "ctrl", "alt", "shift", "super" }

-- The chord name for a set of held modifiers, canonical order. has is
-- any table truthy at the modifier names ("ctrl".."super"), so both a
-- resolved spec set and an origin event's ev.mods serialize the same.
local function mods_prefix(has)
	local s = ""
	for _, m in ipairs(mod_order) do
		if has[m] then
			s = s .. m .. "+"
		end
	end
	return s
end

-- A modifier spec ("mod" resolving to kiln.modkey) as a set keyed by
-- canonical name. Shared by key chords and button chords so both agree on
-- what a modifier means.
local function resolve_mods(mods)
	local set = {}
	for _, m in ipairs(mods or {}) do
		set[m == "mod" and kiln.modkey or m] = true
	end
	return set
end

-- Returns the chord string and the resolved modifier list (with "mod"
-- expanded to kiln.modkey), the form core.set_key_bindings wants.
local function chord_name(mods, keyname)
	local set = resolve_mods(mods)
	local list = {}
	for _, m in ipairs(mod_order) do
		if set[m] then
			table.insert(list, m)
		end
	end
	return mods_prefix(set) .. keyname, list
end

-- The whole consume set, replaced wholesale. A chord with only a release
-- handler must be in here too: C consumes on the PRESS edge and swallows the
-- matching release, so a chord C does not know about would leak its press to
-- the focused client and never reach the release handler.
local function sync_key_bindings()
	local bindings = {}
	for _, b in pairs(state.keys) do
		table.insert(bindings, { mods = b.mods, key = b.key })
	end
	core.set_key_bindings(bindings)
end

-- Returns the chord it bound, which is what lets the registry mirror dispatch.
local function bind(spec, keyname, press, release)
	local chord, mods = chord_name(spec.mods or {}, keyname)
	state.keys[chord] = {
		press = press, release = release, mods = mods, key = keyname,
	}
	return chord
end

-- A range expands into one BINDING per value, and the handler is passed the
-- value: digits as numbers (the numrow-indexing case keygroups existed for),
-- letters as letters. It stays ONE REGISTRY ENTRY, though: a hotkeys sheet
-- wants a row reading "1-9  view tag", not nine rows reading "1".."9".
local function expand(spec)
	local chords = {}
	local from, to = tostring(spec.key):match("^(%d)%-(%d)$")
	if from ~= nil then
		for n = tonumber(from), tonumber(to) do
			local i = n
			chords[#chords + 1] = bind(spec, tostring(n),
				spec.press and function() spec.press(i) end,
				spec.release and function() spec.release(i) end)
		end
		return chords
	end
	from, to = tostring(spec.key):match("^(%a)%-(%a)$")
	if from ~= nil and #from == 1 and #to == 1 then
		for b = string.byte(from), string.byte(to) do
			local l = string.char(b)
			chords[#chords + 1] = bind(spec, l,
				spec.press and function() spec.press(l) end,
				spec.release and function() spec.release(l) end)
		end
		return chords
	end
	-- A "-" that matched neither range form is not a key name either: no keysym
	-- name contains one. "1-10" is the case that looks like it should work, and
	-- widening the pattern would not save it, since the numrow's tenth key is
	-- named "0" and there is no "10" to bind. Refused HERE, before anything is
	-- written: C rejects the unknown name too, but only after state.keys and the
	-- registry have already taken a row that can never dispatch.
	if tostring(spec.key):find("%-") then
		error("kiln.key: not a key name, and not a single-digit or "
			.. "single-letter range: " .. tostring(spec.key), 3)
	end
	chords[1] = bind(spec, spec.key, spec.press, spec.release)
	return chords
end

-- The registry must MIRROR DISPATCH, or a cheat sheet built from it advertises
-- bindings that cannot fire: bind() overwrites state.keys, so a rebound chord
-- replaces the old handler, while appending here unconditionally would keep both
-- rows. A call whose chords cover an existing row's chords replaces that row in
-- place, so declaration order (which is the sheet's column order) survives a
-- rebind, and chord labels stay unique, which the sheet's element ids depend
-- on.
local function record(spec, chords)
	local set = {}
	for _, c in ipairs(chords) do
		set[c] = true
	end
	local row = {
		mods = spec.mods or {}, key = spec.key,
		desc = spec.desc, group = spec.group,
		-- The chord as a user reads it, resolved through kiln.modkey at BIND
		-- time, which is when "mod" means anything. Resolving it at read time is
		-- only possible above this layer, where kiln.modkey is visible, so every
		-- consumer had to compute it by hand.
		label = mods_prefix(resolve_mods(spec.mods)) .. tostring(spec.key),
		chords = chords,
	}
	for i, k in ipairs(state.key_specs) do
		local covered, overlap = true, false
		for _, c in ipairs(k.chords) do
			if set[c] then
				overlap = true
			else
				covered = false
			end
		end
		if covered then
			state.key_specs[i] = row
			return
		elseif overlap then
			-- A chord taken out of the MIDDLE of a range is not a registry row:
			-- the range row would go on advertising a chord that now dispatches
			-- somewhere else, and splitting the row into the parts that still
			-- hold is not something the config wrote. Reported rather than
			-- silently mis-advertised.
			Bus.on_error("kiln.key", "chord " .. chords[1]
				.. " overrides part of the range " .. tostring(k.key)
				.. "; the sheet will list both")
		end
	end
	table.insert(state.key_specs, row)
end

-- kiln.key is a callable table so the registry can hang off it.
kiln.key = setmetatable({}, {
	__call = function(_, spec)
		-- The registry: one entry per call, NOT per expanded chord, so a range
		-- reads back as the range the config wrote. This is the whole of what the
		-- hotkeys sheet consumes, and the only reason desc and group exist.
		record(spec, expand(spec))
		sync_key_bindings()
	end,
})

-- The registry, in declaration order. A copy: a sheet reads it, it does not own
-- it. `chords` stays internal, being the reconciliation's own bookkeeping.
function kiln.key.all()
	local out = {}
	for i, k in ipairs(state.key_specs) do
		out[i] = {
			mods = k.mods, key = k.key, desc = k.desc, group = k.group,
			label = k.label,
		}
	end
	return out
end

-- Reset every binding, for hot-reload. sync_key_bindings already replaces the
-- whole consume set in C, so this needs no C at all.
function kiln.key.clear()
	state.keys = {}
	state.key_specs = {}
	sync_key_bindings()
end

kiln.button = setmetatable({}, {
	__call = function(_, spec)
		table.insert(state.buttons, spec)
	end,
})

function kiln.button.clear()
	state.buttons = {}
end

function kiln.focused(fn)
	return function(...)
		if client.focus ~= nil then
			return fn(client.focus, ...)
		end
	end
end

-- ---------------------------------------------------------------------
-- Rules, applied on map before the client takes focus.

kiln.rule = setmetatable({}, {
	__call = function(_, spec)
		table.insert(state.rules, spec)
	end,
})

function kiln.rule.clear()
	state.rules = {}
end

-- Does one string field hit? Values are LUA PATTERNS, and a list means any-of,
-- so a single value and a list of one behave the same.
local function field_hit(value, pats)
	if value == nil or pats == nil then
		return false
	end
	if type(pats) ~= "table" then
		pats = { pats }
	end
	for _, pat in ipairs(pats) do
		if value:match(pat) then
			return true
		end
	end
	return false
end

-- One matcher clause against a client. Fields: app (vs app_id), class and
-- instance (X11 WM_CLASS, where there is no app id), title, role (X11
-- WM_WINDOW_ROLE), dialog (a boolean: does it have a parent), and fn, the
-- general escape into plain Lua. fn is a matcher, not a hatch: it reads the same
-- public object every other field does.
--
-- all = true requires every present field to hit (`match`); all = false requires
-- any one of them (`match_any`).
local function clause_hit(clause, c, all)
	local tested, hit = false, false
	local function test(ok)
		tested = true
		if ok then
			hit = true
		elseif all then
			hit = false
		end
		return not (all and not ok)
	end

	if clause.app ~= nil and not test(field_hit(c.app_id, clause.app)) then
		return false
	end
	if clause.class ~= nil and not test(field_hit(c.class, clause.class)) then
		return false
	end
	if clause.instance ~= nil and
			not test(field_hit(c.instance, clause.instance)) then
		return false
	end
	if clause.title ~= nil and not test(field_hit(c.title, clause.title)) then
		return false
	end
	-- role is X11's WM_WINDOW_ROLE, the identity beyond the class (a "pop-up"
	-- vs a "browser" of the same app). A Lua pattern like every match value, so
	-- a literal dash needs escaping: match = { role = "pop%-up" }.
	if clause.role ~= nil and not test(field_hit(c.role, clause.role)) then
		return false
	end
	if clause.dialog ~= nil and
			not test(clause.dialog == (c.parent ~= nil)) then
		return false
	end
	if clause.fn ~= nil and not test(clause.fn(c) and true or false) then
		return false
	end
	return tested and hit
end

-- match (all fields must hit) and match_any (any field hits) select; except and
-- except_any veto. A spec with no selector at all matches nothing, not
-- everything: a rule that fires on every client is a mistake worth making loud.
local function rule_matches(spec, c)
	if spec.except ~= nil and clause_hit(spec.except, c, true) then
		return false
	end
	if spec.except_any ~= nil and clause_hit(spec.except_any, c, false) then
		return false
	end
	if spec.match ~= nil and clause_hit(spec.match, c, true) then
		return true
	end
	if spec.match_any ~= nil and clause_hit(spec.match_any, c, false) then
		return true
	end
	return false
end

-- Rules apply in declaration order on map, before the client takes focus; a
-- later rule overrides an earlier one's props.
--
-- The specials are not property writes and are applied first: `tag` and `screen`
-- name a home (by name or by object), and `focus = false` is a decision the map
-- path consumes rather than state anyone stores. Everything else IS a plain
-- property write, and order-independent by construction: each one is read at
-- declare, so no two of them can race (a Lua table has no order to honor
-- anyway).
local function tag_named(name, s)
	for _, scr in ipairs(s ~= nil and { s } or state.screens) do
		for _, t in ipairs(scr.tags) do
			if t.name == name then
				return t
			end
		end
	end
	return nil
end

local function apply_rules(c)
	for _, spec in ipairs(state.rules) do
		if rule_matches(spec, c) then
			local props = spec.props or {}
			local s = props.screen
			if type(s) == "string" then
				s = screen_by_name(s)
			end
			local t = props.tag
			if type(t) == "string" then
				t = tag_named(t, s)
			end
			if t ~= nil then
				c.tags = { t }
			elseif s ~= nil and s.selected_tag ~= nil then
				c.tags = { s.selected_tag }
			end
			if props.focus == false then
				c.no_focus = true
			end
			for k, v in pairs(props) do
				if k ~= "tag" and k ~= "screen" and k ~= "focus" then
					c[k] = v
				end
			end
			if spec.on ~= nil then
				spec.on(c)
			end
		end
	end
end

-- ---------------------------------------------------------------------
-- Errors: config callbacks are pcall-isolated by the bus; surface them
-- to kiln.on("error") listeners as well as stderr. The same name-keyed bus
-- carries the origin events a config subscribes to by name (idle::start etc);
-- it is one Bus, not a second dispatch path.

local error_bus = Bus.new()

function kiln.on(name, fn)
	error_bus:on(name, fn)
end

Bus.on_error = function(signal, err)
	print("kiln: error in '" .. signal .. "': " .. tostring(err))
	error_bus:emit("error", signal, err)
end

-- ---------------------------------------------------------------------
-- The frame handler: one Clay tree per screen. Every exclusive zone (our
-- bars and reserving layer surfaces alike) enters one fold
-- that nests flow containers around the workarea grow node, then the
-- tag's layout inside it, floats declared focused-last.

-- A bar's body is its own cfg. Everything here is a documented default a
-- config overrides by the ordinary element key; only the id and the
-- along-edge grow are forced, because the strut fold owns both. Defaults
-- are filled per frame, not at ui.bar, so a live theme edit keeps
-- governing the bars already registered.
--
-- Defaults: dir from the edge (top/bottom row, left/right column), the
-- across-edge axis from theme bar_height, pad 8 on the along axis, gap 6,
-- cross-axis center, theme bg.
local function declare_bar(bar, i)
	local cfg = bar.cfg
	local edge = cfg.edge or "top"
	local horiz = edge == "top" or edge == "bottom"
	local dir = cfg.dir or (horiz and "row" or "column")
	local col = dir == "column" or dir == "ttb"
	local d = {}
	for k, v in pairs(cfg) do
		d[k] = v
	end
	d.edge, d.band, d.dir = nil, nil, nil
	d.id = { "bar", i }
	if horiz then
		d.w = "grow"
		d.h = cfg.h or state.theme.bar_height
	else
		d.w = cfg.w or state.theme.bar_height
		d.h = "grow"
	end
	d.pad = cfg.pad or (horiz and { x = 8 } or { y = 8 })
	d.gap = cfg.gap or 6
	d.align = cfg.align
		or (col and { x = "center" } or { y = "center" })
	d.color = cfg.color or state.theme.bg
	local open = col and ui.column or ui.row
	open(d, bar.fn)
end

function screen_by_name(name)
	for _, s in ipairs(state.screens) do
		if s.name == name then
			return s
		end
	end
	return nil
end

core.set_frame_handler(function(screen_name, width, height)
	local s = screen_by_name(screen_name)
	if s == nil then
		return
	end
	s.width, s.height = width, height
	-- Deferred from the `output change` branch: the fresh geometry is in
	-- hand now, so the screen's layer surfaces re-answer against it and the fold
	-- below picks up the new struts in THIS frame rather than the next one.
	-- Re-emitting `commit` rather than calling kiln.defaults.layer directly is
	-- what keeps this working for a config that replaced the layer answer: the
	-- surface's facts have not changed, only the screen it is being sized
	-- against, and the answer is idempotent by contract.
	if state.layer_reanswer[screen_name] then
		state.layer_reanswer[screen_name] = nil
		for _, l in ipairs(state.layers) do
			if l.mapped and l.screen == s then
				l:emit("commit")
			end
		end
	end
	state.presses = {}
	state.press_n = 0
	-- The screen currently declaring. ui.each scopes its per-key state stores by
	-- it, so the same widget on two monitors sweeps two stores and never drops
	-- the other screen's keys.
	state.screen_name = screen_name

	-- The fold's inputs: bars as chrome zones (edge from cfg, band
	-- default "above" so kiln chrome folds with the protocol's top
	-- layer, bars before layer surfaces within the band), mapped layer
	-- surfaces on this screen. Reserving surfaces become zones; the rest
	-- land in `loose`, declared after the workarea exists to attach to.
	local slots = { n = 0 }
	local chrome, slayers, loose = {}, {}, {}
	for i, bar in ipairs(s.bars) do
		table.insert(chrome, {
			edge = bar.cfg.edge or "top",
			band = bar.cfg.band or "above",
			declare = function()
				declare_bar(bar, i)
			end,
		})
	end
	for _, l in ipairs(state.layers) do
		if l.mapped and l.screen == s then
			table.insert(slayers, l)
		end
	end
	local zones = layout.strut_zones(chrome, slayers, loose, slots)

	ui.column({ id = "root", w = "grow", h = "grow" },
	function()
		-- The root's own fill, declared IN the background band rather than painted
		-- on the in-flow root. Painted on the root it is an opaque plane at z 0,
		-- and the background band is z -1000 (ui.lua), so the whole band sits
		-- behind it and nothing a config declares there can ever be seen: a
		-- wallpaper would decode its image, declare its box at full screen, and
		-- the frame would come back pixel-identical to having no wallpaper at
		-- all. The band needs a position that is under the bar and the tiles
		-- without being under the surface the runtime paints, and that means the
		-- fill joins the band.
		--
		-- Declared FIRST, so a config's own background float ties at the same z
		-- and takes the frame by declaring later (Clay's float sort is stable,
		-- the same tiebreak the band comment in ui.lua rests on).
		--
		-- passthrough is not optional: a background float defaults to CAPTURE,
		-- and a full-screen capturing float over the whole output occludes every
		-- hit under it, bar included.
		--
		-- Grown, not sized from the screen: the output's size and the Clay root's
		-- size are the same number only while nothing else has taken part of the
		-- output, and the debug view takes a strip off the right. Sized from
		-- s.width the fill keeps the old full-output width and hangs its right
		-- edge under that strip, so the band it backs stops lining up with the
		-- tree it sits behind. Growing asks the root, which is the box this fill
		-- is the fill OF.
		ui.box({
			id = "root-fill:" .. screen_name,
			float = { to = "root", band = "background", passthrough = true },
			w = "grow", h = "grow",
			color = state.theme.bg2,
		})
		local sel = s.selected_tag
		-- The gap is a tag param: the workarea's inset and the space the
		-- layout leaves between its cells, so the outer margin and the inner
		-- gaps agree without the layout knowing where the workarea starts.
		local gap = (sel ~= nil and sel.gap) or state.theme.gap
		-- The tag-switch reveal eases the workarea inward inset from gap+24 down
		-- to gap (reveal 0->1), so the incoming selection grows into place. 1 (or
		-- absent) is the settled value, identical to the old instant behavior.
		local reveal = animation.get("reveal:" .. screen_name, 1)
		local wpad = gap + (1 - reveal) * 24
		layout.fold_struts(zones, 1, function()
			ui.row({
				-- No fill. The root-fill float already paints bg2 behind the whole
				-- output, so an opaque workarea would re-occlude the background
				-- band over exactly the part of the screen a wallpaper is for.
				id = "workarea:" .. screen_name,
				w = "grow", h = "grow",
				pad = wpad, gap = gap,
			}, function()
				local t = sel
				if t == nil then
					return
				end
				local tiled, floats, maxed, full = {}, {}, {}, {}
				for _, c in ipairs(visible_clients(s)) do
					-- A minimized client is one the runtime stops
					-- declaring: not drawn, not hit, not focusable,
					-- with no separate hidden state to keep in sync.
					if c.mapped and not c.minimized
							and not c.override_redirect then
						if c.fullscreen then
							table.insert(full, c)
						elseif c.maximized then
							table.insert(maxed, c)
						else
							table.insert(c.floating and floats or tiled, c)
						end
					end
				end
				-- Band order is the declare order: tiles are
				-- in-flow (under every float), then floats, maximized,
				-- fullscreen, each taking successive within-band z slots
				-- from one counter so declaration order stays the tiebreak
				-- across the groups.
				-- (clients, area, tag): area is the box the layout's own
				-- container fills, the workarea from the last solve inset by
				-- the gap it is padded with. One frame stale by construction;
				-- the first solve has no prior box, so fall back to the
				-- screen. Only carousel and magnifier read it.
				local wa = s.workarea or
					{ x = 0, y = 0, width = width, height = height }
				t.layout(tiled, {
					x = wa.x + gap, y = wa.y + gap,
					width = wa.width - 2 * gap,
					height = wa.height - 2 * gap,
				}, t)
				layout.declare_floats(floats, slots)
				layout.declare_maximized(maxed, s, slots)
				layout.declare_fullscreen(full, s, slots)
			end)
		end)
		-- Non-reserving layer surfaces, in their protocol-named bands
		-- (background/below under the tiles' z, above/overlay on top),
		-- from the same slots counter so map order ties break like any
		-- other float.
		layout.declare_layers(loose, slots, "workarea:" .. screen_name)
		-- Override-redirect declares last at its own box:
		-- band-exempt, no chrome, no rules; the box is the client's own
		-- (map ask or a later self-move C already obeyed).
		local ors = {}
		for _, c in ipairs(visible_clients(s)) do
			if c.mapped and c.override_redirect then
				table.insert(ors, c)
			end
		end
		layout.declare_or(ors, slots)
		-- The prompt is the last chrome declared: an overlay float over
		-- everything on its screen, and nothing at all when none runs.
		prompt.declare(s)
		-- The menu declares after it, so an open menu sits over the prompt in
		-- the overlay band, and its scrim covers everything under it.
		menu.declare(s)
		-- The declare hooks: stdlib chrome that is not built into this handler
		-- (the hotkeys sheet is one), then whatever the config registered, in
		-- registration order. They run HERE, after every built-in that owns an
		-- element id, because a hook's float may attach to one of those ids and
		-- Clay aborts on a target that has never been declared at all.
		-- Everything above is declared by the time a hook runs, so an attach
		-- resolves on the first frame the two appear together, which is the
		-- frame that used to abort.
		--
		-- Stdlib hooks are registered by module bodies and so come first, which
		-- is also why the hotkeys sheet still declares over the menu and the
		-- prompt rather than under: it is modal, and taking the keyboard closed
		-- whatever held it.
		hook.run(s)
		-- The tooltip is last: it labels whatever is under the pointer, so it
		-- sits over all of it. Last is a z choice and not an attach requirement:
		-- it attaches to an element by id, and Clay resolves that against a
		-- hashmap that persists across frames, so the element it points at is one
		-- the pointer has already been over and is found whatever order this
		-- runs in.
		tooltip.declare(s)
		-- Notifications sit over even the tooltip: they arrive unbidden and must
		-- not be buried by whatever the pointer happens to rest on.
		if kiln.defaults.notify_display ~= nil then
			kiln.defaults.notify_display(s)
		end
	end)

	-- Stash this screen's handlers so a button on it dispatches to them,
	-- not to whichever screen declared last.
	state.screen_presses[screen_name] = state.presses
end)

-- ---------------------------------------------------------------------
-- The event handler: origin facts in, policy out.

local float_cascade = 0

-- Runtime default placement: the focused screen's selected tag. Applied
-- on first map and on any later map still untagged (a client that mapped
-- before any screen existed gets a home once one appears).
local function ensure_tagged(c)
	if c.tag ~= nil then
		return
	end
	local s = focused_screen()
	local t = s ~= nil and s.selected_tag or nil
	if t ~= nil then
		c.tags = { t }
	end
end

-- X11 hint fields riding client::map (nil for xdg clients); re-read on every
-- map because an unmap/remap cycle can change them (close-to-tray relaunch).
local function apply_map_hints(c, ev)
	-- wm_class/wm_instance on the wire (the event envelope owns "class").
	c.class, c.instance, c.pid = ev.wm_class, ev.wm_instance, ev.pid
	c.transient_for = ev.transient_for
	c.override_redirect = ev.override_redirect
	c.wants_focus = ev.wants_focus
	-- WM_WINDOW_ROLE (a rule field) and the icon cache key C decoded from
	-- _NET_WM_ICON. Both nil for xdg clients; a remap that dropped either
	-- clears it, since the wire carries nil.
	c.role, c.icon = ev.role, ev.icon
	-- _NET_WM_WINDOW_TYPE as a list in CLIENT order (the wire joins with
	-- commas); ranking it is the reader's business, never the runtime's.
	c.window_type = nil
	if ev.window_type ~= nil then
		c.window_type = {}
		for name in ev.window_type:gmatch("[^,]+") do
			table.insert(c.window_type, name)
		end
	end
end

local function on_map(ev)
	local c = object.lookup(ev.handle)
	if c ~= nil then
		-- unmap/remap cycle: same object, updated state.
		c.x, c.y = ev.x, ev.y
		c.width, c.height = ev.width, ev.height
		apply_map_hints(c, ev)
		c.mapped = true
		ensure_tagged(c)
	else
		c = client.new {
			handle = ev.handle,
			x = ev.x, y = ev.y,
			width = ev.width, height = ev.height,
			app_id = ev.app_id, title = ev.title,
			mapped = true,
			-- Always a list, so every reader can walk it without a nil guard.
			tags = {},
		}
		apply_map_hints(c, ev)
		object.attach(ev.handle, c)
		ensure_tagged(c)
		if not c.override_redirect then
			float_cascade = (float_cascade % 8) + 1
			-- The cascade seeds the origin only; layout.float_client fills in
			-- the size the first time the client is declared as a float.
			c.float = { x = 40 * float_cascade, y = 30 * float_cascade }
			apply_rules(c)
		end
	end
	c:emit("map")
	-- The state the client opens in: a window can
	-- arrive already fullscreen or maximized instead of asking to become one
	-- (firefox opens maximized, `foot --fullscreen` opens fullscreen). C
	-- snapshots it onto the map payload, and it is honored by the same
	-- handlers a live request goes through, so a config that refuses one
	-- refuses both. After the rules, so a rule can still swap the handler;
	-- before focus, so the first declare already has the client in its band.
	if ev.fullscreen then
		c:emit("request::fullscreen", true)
	end
	if ev.maximized then
		c:emit("request::maximize", true)
	end
	if ev.minimized then
		c:emit("request::minimize", true)
	end
	if c.tag == nil then
		return
	end
	-- Override-redirect: no rules, no chrome, no focus-on-open; it shows at
	-- its own box (declared last) and takes focus only when the
	-- ICCCM answer C forwarded says this kind of window wants it.
	if c.override_redirect then
		if c.wants_focus then
			c:focus()
		end
		dirty_client(c)
		return
	end
	-- Default: focus on open, but only once the client has a tag and so
	-- is actually visible; focusing an undeclared client would hand
	-- keyboard input to a window nothing is drawing. A rule suppresses it with
	-- focus = false, which is the one prop that is a decision rather than
	-- a property write, so it is consumed here rather than stored.
	if not c.no_focus then
		c:focus()
	end
	dirty_client(c)
end

-- Drag step: offset the float by how far the pointer has moved since the
-- grab began. Re-declaration on the client's screen paints the new spot.
function grab_motion(x, y)
	local g = grab
	local c = g.c
	-- Window geometry is integral (as in AwesomeWM): the pointer delivers
	-- fractional doubles, and a fractional box truncates differently in the
	-- scene (ints) than Clay hit-tests it (floats), leaving a sub-pixel band
	-- where the two authorities disagree; an edge drag pins the cursor to
	-- exactly that band. Rounding the DELTAS (not the results) keeps every
	-- anchor-relative edge, including the pinned opposite edge, exact.
	local dx = math.floor(x - g.px0 + 0.5)
	local dy = math.floor(y - g.py0 + 0.5)
	if g.edges ~= nil then
		-- Resize: recompute geometry from the snapshot each motion, so the
		-- drag is authoritative and commit_size syncs never fight it. West and
		-- north edges also move the origin so the opposite edge stays pinned;
		-- at the min-size clamp the origin stops so the far edge holds.
		local min = state.theme.min_size
		local w, h, fx, fy = g.w0, g.h0, g.x0, g.y0
		if g.edges:find("e") then w = g.w0 + dx end
		if g.edges:find("w") then w = g.w0 - dx; fx = g.x0 + dx end
		if g.edges:find("s") then h = g.h0 + dy end
		if g.edges:find("n") then h = g.h0 - dy; fy = g.y0 + dy end
		if w < min then
			if g.edges:find("w") then fx = g.x0 + (g.w0 - min) end
			w = min
		end
		if h < min then
			if g.edges:find("n") then fy = g.y0 + (g.h0 - min) end
			h = min
		end
		-- Resize rewrites the Lua-owned composite box; the surface grows to fill
		-- it and the renderer configures the client, closing the loop. The box
		-- is REPLACED, not mutated in place: the mixin diffs by value, so
		-- one write is one property::float, where four scalars were four.
		c.float = { x = fx, y = fy, width = w, height = h }
	else
		local f = c.float or {}
		c.float = {
			x = g.fx0 + dx, y = g.fy0 + dy,
			width = f.width, height = f.height,
		}
	end
	dirty_client(c)
end

-- The drag as a claim: motion moves the float, the release of the button that
-- started it ends the drag, and the wheel is swallowed (no axis handler) the
-- way it always was. Ending is the claim's job, so a config mousegrabber that
-- takes the pointer mid-drag ends this one through the same door.
function start_drag(g, cursor)
	grab = g
	core.input.set_cursor(cursor)
	g.claim = grabber.mousegrabber {
		motion = function(ev) grab_motion(ev.x, ev.y) end,
		button = function(ev)
			if not ev.pressed and ev.button == g.button then
				g.claim:stop()
			end
		end,
		stopped = function()
			if grab == g then
				grab = nil
			end
		end,
	}
end

local function on_client_event(ev)
	if ev.name == "map" then
		on_map(ev)
		return
	end
	local c = object.lookup(ev.handle)
	if c == nil then
		-- Stale handle: a checked no-op. A pre-map ask lands here too (the
		-- client has no object yet), and is dropped on purpose: the state it
		-- asked for is on the map payload right behind it, which is where the
		-- runtime honors it.
		return
	end
	-- A client that vanishes mid-drag would otherwise strand the grab on a
	-- dead object; end it before the client is gone.
	if grab ~= nil and grab.c == c and
			(ev.name == "unmap" or ev.name == "destroy") then
		grab.claim:stop()
	end
	if ev.name == "unmap" then
		c.mapped = false
		remove_value(history, c)
		c:emit("unmap")
		if client.focus == c then
			refocus(c)
		end
		dirty_client(c)
	elseif ev.name == "destroy" then
		remove_value(history, c)
		c:emit("destroy")
		object.detach(ev.handle)
		-- Unmap already refocused if this client held focus, so destroy only
		-- needs to act when it is still the focused one. BEFORE the tags are
		-- cleared: the successor policy reads gone.screen, which is derived from
		-- the tags, so an untagged corpse would have no screen to search.
		if client.focus == c then
			refocus(c)
		end
		-- Leaving every tag drops the client from each one's list and dirties
		-- each one's screen: one write, and the membership is gone.
		dirty_client(c)
		c.tags = {}
	elseif ev.name == "commit_size" then
		-- No dirty: the renderer configured this size to match the
		-- solved box; re-solving would be a feedback loop.
		c.width, c.height = ev.width, ev.height
	elseif ev.name == "metadata" then
		c.app_id, c.title = ev.app_id, ev.title
		-- X11 metadata carries WM_CLASS instead of an app id, plus the role and
		-- icon (a set_role/set_icon after map re-states them; nil clears).
		if ev.wm_class ~= nil then
			c.class, c.instance = ev.wm_class, ev.wm_instance
			c.role, c.icon = ev.role, ev.icon
		end
		-- The titlebar renders these; without a dirty a rename never repaints.
		dirty_client(c)
	elseif ev.name == "request::decoration_mode" then
		-- The client's preferred mode is a fact for policy; C has already forced
		-- server-side (this compositor has no client-side path). Whether the
		-- client shows a titlebar is Lua declaring one or not (c.titlebar),
		-- decided by rules/props, not by this event.
		c:emit("request::decoration_mode", ev.mode)
	elseif ev.name == "request::activate" then
		-- The client asks to be raised. The runtime carries the facts (was the
		-- token user-initiated, the app_id hint) and lets policy decide: the
		-- stock kiln.defaults.activate focuses a valid ask and marks urgent
		-- otherwise, and rc.lua can replace it wholesale. C decided nothing.
		c:emit("request::activate", { valid = ev.valid, app_id = ev.app_id })
	elseif ev.name == "request::configure" then
		-- An X11 client asked to place or size itself (no xdg analog). The
		-- tiled default ignores it: the declared tree is authoritative and the
		-- next solve re-configures the client anyway. Floating policy may
		-- honor it from this signal.
		-- For override-redirect the same event is a notification: the X
		-- server already applied the move (C sends nothing to OR surfaces),
		-- so the runtime's only job is to re-declare the box where the
		-- window already is.
		if c.override_redirect then
			c.x, c.y = ev.x, ev.y
			c.width, c.height = ev.width, ev.height
			dirty_client(c)
		end
		c:emit("request::configure",
			{ x = ev.x, y = ev.y, width = ev.width, height = ev.height })
	elseif ev.name == "request::urgent" then
		-- ICCCM urgency. Same shape as an invalid activate: flag it, render
		-- it, never steal focus; focus() clears it.
		c.urgent = ev.urgent
		c:emit("request::urgent", ev.urgent)
	elseif ev.name == "request::fullscreen" or ev.name == "request::maximize"
			or ev.name == "request::minimize" then
		-- The client asked for a state (the request family is honored by
		-- default and replaceable wholesale). C answered nothing
		-- and set nothing; the stock kiln.defaults handler below grants the
		-- ask, and rc.lua can swap it off the bus. Both shells raise all
		-- three, so nothing here knows which kind asked.
		c:emit(ev.name, ev.on)
	elseif ev.name == "request::close" then
		-- A taskbar asked to close this client (foreign-toplevel). Same request
		-- family: the stock kiln.defaults.close honors it, replaceable wholesale.
		c:emit("request::close")
	end
end

-- Both edges dispatch. The key origin event carries `pressed`, and C queues
-- the release edge to Lua before making its consume decision while swallowing
-- that release from the client, so a release handler needs no C support at
-- all: both edges are already on the queue.
local function on_key(ev)
	local chord = mods_prefix(ev.mods) .. ev.key
	local binding = state.keys[chord]
	if binding == nil then
		return
	end
	local fn = ev.pressed and binding.press or binding.release
	if fn == nil then
		return
	end
	local ok, err = pcall(fn)
	if not ok then
		Bus.on_error("key " .. chord, err)
	end
end

-- A button spec's mods (with "mod" resolved) must match the held set
-- exactly, so a plain click and a mod+click dispatch to different bindings.
-- Both sides serialize through the same canonical prefix.
local function mods_match(spec_mods, held)
	return mods_prefix(resolve_mods(spec_mods)) == mods_prefix(held or {})
end

-- Fire one button{} spec, with the press exposed so a grab it starts captures
-- its anchor and terminating button in one place. pcall like the other config
-- callbacks, so a failing handler still clears current_press and surfaces
-- through kiln.on.
local function fire_button(b, ev, c)
	local fn = ev.pressed and b.press or b.release
	if fn == nil then
		return false
	end
	current_press = ev
	local ok, err = pcall(fn, c)
	current_press = nil
	if not ok then
		Bus.on_error("button " .. tostring(ev.button), err)
	end
	return true
end

-- A button{} spec is a candidate when its button and modifiers match, and when
-- its `on` names where this press landed: "client" (the default) on a client
-- surface, "root" on empty workarea.
local function button_matches(b, ev, where)
	return b.button == ev.button and mods_match(b.mods, ev.mods)
		and (b.on or "client") == where
end

local function on_button(ev)
	if ev.screen == nil then
		return
	end
	-- The reconciled scene is the hit authority: C sets ev.client when the
	-- topmost real node at the cursor is a client surface. Trust it for the
	-- chrome-vs-client fork instead of re-deriving it from a Clay query, which
	-- is blind to client popups overhanging their solved box.
	if ev.client ~= nil then
		local c = object.lookup(ev.client)
		if c == nil then
			return
		end
		for _, b in ipairs(state.buttons) do
			if button_matches(b, ev, "client") and fire_button(b, ev, c) then
				return
			end
		end
		-- Default: click focuses. The press edge only; a release is not a click.
		if ev.pressed then
			c:focus()
		end
		return
	end
	-- Chrome: the innermost Clay element with a handler for this edge wins.
	-- on_release is dispatched here too; ui.lua has always accepted it as a cfg
	-- key and nothing ever fired it, so declaring one was silently dead.
	local key = ev.pressed and "on_press:" or "on_release:"
	local presses = state.screen_presses[ev.screen] or {}
	for _, hit in ipairs(core.hits(ev.screen, ev.x, ev.y)) do
		-- The Clay debug panel eats the press: C already handed the same
		-- edge to Clay's own solver, which is what runs the panel's rows and its
		-- close button, so anything further here would be a second dispatch of
		-- one click. The match is EXACT, never a prefix: the hover-highlight
		-- overlay the panel floats over the real scene is a separate id chain
		-- (Clay__DebugView_ElementHighlight*) lying over user chrome, and
		-- swallowing that would make the whole highlighted element unclickable.
		if hit.name == "Clay__DebugView" then
			return
		end
		local fn = presses[key .. hit.name .. "#" .. hit.index]
		if fn ~= nil then
			current_press = ev
			-- ev carries button and mods (the same facts button_matches reads),
			-- so a chrome handler can fork on which button and which modifiers
			-- the press held: a taglist mod+click or a titlebar right-drag is
			-- inexpressible without them. The scroll path passes ev the same
			-- way, and a handler that wants none of it ignores the argument.
			local ok, err = pcall(fn, ev)
			current_press = nil
			if not ok then
				Bus.on_error(key .. hit.name, err)
			end
			return
		end
	end
	-- Root: no client, and no chrome element claimed it, so the press landed on
	-- empty workarea. button { on = "root" } is what wants it.
	for _, b in ipairs(state.buttons) do
		if button_matches(b, ev, "root") and fire_button(b, ev, nil) then
			return
		end
	end
end

local function on_scroll(ev)
	-- Observer model: if the topmost node is a client surface, C
	-- already forwarded the axis to it via the seat. Lua does not double-scroll.
	if ev.client ~= nil then
		return
	end
	-- Chrome (or root): the innermost Clay element with a scroll handler wins.
	-- Same within-chrome query the press path uses; the handler adjusts its
	-- Lua-owned offset and marks dirty, and the next declare clamps it.
	local presses = state.screen_presses[ev.screen] or {}
	for _, hit in ipairs(core.hits(ev.screen, ev.x, ev.y)) do
		-- The debug panel's two panes scroll, by the same exact-name test
		-- the press path uses. C only accumulates: it is Lua that decides a
		-- wheel over the panel belongs to the panel. The delta is normalized to
		-- rows here rather than in C, because the row height is Clay's constant
		-- and the wheel step is the seat's: one notch is ~15, Clay multiplies by
		-- 10, and a row is 30px, so a fifth of the notch is exactly one row. The
		-- sign flips because a wheel down means the content moves up.
		if hit.name == "Clay__DebugView" then
			core.inspector_scroll(ev.screen, -ev.dx / 5, -ev.dy / 5)
			return
		end
		local fn = presses["on_scroll:" .. hit.name .. "#" .. hit.index]
		if fn ~= nil then
			local ok, err = pcall(fn, ev)
			if not ok then
				Bus.on_error("on_scroll " .. hit.name, err)
			end
			return
		end
	end
end

-- Hover: the innermost element with an on_hover handler gets it, as
-- fn(over, hit). Handlers are told they were LEFT, not only entered: the
-- cursor case only ever needed enter (the resize handles name their edge cursor,
-- and the no-handler fallthrough below resets it), but a tooltip has to come
-- down when the pointer goes, so the enter/leave pair is the contract.
--
-- The hit is re-derived every motion from the same authority as a click, so the
-- only state is which element is currently under the pointer. Everything that is
-- NOT an element with a handler -- bare chrome, a client surface (the cursor
-- there belongs to C and the client), no screen at all -- is the same fact: no
-- hit, so whatever was hovered was left. Only the last coalesced motion reaches
-- here, so it is one hit query per frame. This is on_hover's only dispatch.
local hovered = nil

local function fire_hover(h, over)
	local ok, err = pcall(h.fn, over, h.hit)
	if not ok then
		Bus.on_error("on_hover " .. h.hit.name, err)
	end
end

local function on_hover(ev)
	local hit, fn
	if ev.client == nil and ev.screen ~= nil then
		local presses = state.screen_presses[ev.screen] or {}
		for _, h in ipairs(core.hits(ev.screen, ev.x, ev.y)) do
			local f = presses["on_hover:" .. h.name .. "#" .. h.index]
			if f ~= nil then
				-- The screen the hit came from, carried on it: a handler that
				-- declares something off this element (the tooltip) must declare
				-- it on the screen the element is on, and hovering chrome does
				-- not focus a screen, so screen.focused is not that answer.
				h.screen = ev.screen
				hit, fn = h, f
				break
			end
		end
	end
	local key = hit ~= nil and (hit.name .. "#" .. hit.index) or nil
	if hovered ~= nil and hovered.key ~= key then
		fire_hover(hovered, false)
		hovered = nil
	end
	if fn == nil then
		if ev.client == nil then
			core.input.set_cursor("default")
		end
		return
	end
	hovered = { key = key, fn = fn, hit = hit }
	-- Fired on every motion over the element, not only on entry: a handler is
	-- "the pointer is here", and every one of them is idempotent.
	fire_hover(hovered, true)
end

-- Copy a layer event's facts onto the object. The output fact resolves to a
-- screen; nil (the client left the choice to the compositor) defaults to the
-- focused screen, a placement policy C never made.
local function layer_facts(l, ev)
	l.namespace = ev.namespace
	l.layer = ev.layer
	l.interactivity = ev.interactivity
	l.anchors = ev.anchors
	l.margin = ev.margin
	l.exclusive = ev.exclusive
	l.desired_w, l.desired_h = ev.width, ev.height
	l.screen = (ev.output ~= nil and screen_by_name(ev.output) or nil)
		or l.screen or focused_screen()
end

local function on_layer_event(ev)
	if ev.name == "map" then
		-- The surface's initial commit: it blocks until a handler answers
		-- with core.layer_configure. Remap reuses the object (the protocol
		-- re-runs the configure sequence, so the facts arrive fresh).
		local l = object.lookup(ev.handle)
		if l == nil then
			l = layer.new { handle = ev.handle }
			object.attach(ev.handle, l)
			table.insert(state.layers, l)
		end
		layer_facts(l, ev)
		l.mapped = true
		l:emit("map")
		return
	end
	local l = object.lookup(ev.handle)
	if l == nil then
		return -- stale handle: checked no-op
	end
	if ev.name == "commit" then
		layer_facts(l, ev)
		l:emit("commit")
	elseif ev.name == "unmap" then
		l.mapped = false
		l:emit("unmap")
		dirty_screen(l.screen)
	elseif ev.name == "destroy" then
		l:emit("destroy")
		object.detach(ev.handle)
		remove_value(state.layers, l)
		dirty_screen(l.screen)
	end
end

-- The DBus intake. C answered the method and
-- reported the facts; every decision about them is made here.
local function on_notify_event(ev)
	if ev.name == "close" then
		-- The client called CloseNotification. Dismissing emits NotificationClosed
		-- with reason 3, which is the protocol's own answer to its own request.
		for _, n in ipairs(notification.all()) do
			if n.id == ev.id then
				return n:dismiss("closed")
			end
		end
		return
	end

	-- expire_timeout is milliseconds, and its two magic values are the client
	-- deferring (-1, so the theme's per-urgency default decides) and refusing
	-- (0, sticky). Nothing in C read either of them.
	local timeout = nil
	if ev.expire_timeout ~= nil and ev.expire_timeout >= 0 then
		timeout = ev.expire_timeout / 1000
	end

	-- The image precedence, in Lua because it is a ranking and C ranks nothing.
	-- ev.image is the cache key of pixels the client sent inline (C put them in
	-- the cache; they were never in the event); then a path it named; then the
	-- app's own icon, which is a name a theme lookup could resolve and today is
	-- taken as a path.
	local hints = ev.hints or {}
	local icon = ev.image or hints["image-path"] or hints["image_path"]
	if icon == nil and ev.app_icon ~= nil and ev.app_icon ~= "" then
		icon = ev.app_icon
	end

	-- An id that still names a live notification updates it in place; that is
	-- what replaces_id means, and kiln.notify is where it means it.
	kiln.notify {
		id = ev.id,
		title = ev.summary,
		message = ev.body,
		app_name = ev.app_name,
		urgency = ev.urgency,
		timeout = timeout,
		icon = icon,
		actions = ev.actions,
		-- The progress hint every volume and brightness script sends, passed
		-- through as the scalar it is.
		value = hints.value,
		hints = hints,
	}
end

core.set_event_handler(function(ev)
	if ev.class == "client" then
		on_client_event(ev)
	elseif ev.class == "notify" then
		on_notify_event(ev)
	elseif ev.class == "tray" then
		-- The SNI watcher reported an item (an upsert) or its loss; the registry
		-- keeps the list kiln.widgets.systray draws. C ranked and placed nothing.
		require("kiln.systray").on_event(ev)
	elseif ev.class == "spawn" then
		-- A spawned child's raw output/exit; the line split and re-arm are Lua's.
		require("kiln.spawn").on_event(ev)
	elseif ev.class == "drag" then
		-- Informational: a drag began or ended. C owns
		-- the grab and the icon; this only forwards the fact to config. "end"
		-- fires for a drop and a cancel alike, because C tells them apart for
		-- neither.
		drag.emit(ev.name)
	elseif ev.class == "idle" then
		-- Idle facts: the timer elapsed / input returned / a
		-- visible inhibitor flipped. Delivered as kiln.on("idle::start" etc), the
		-- error bus the config already subscribes to; C locks and dims nothing.
		error_bus:emit("idle::" .. ev.name, ev.on)
	elseif ev.class == "layer" then
		on_layer_event(ev)
	elseif ev.class == "frame" and ev.name == "tick" then
		-- The animation clock: one frame::tick per output frame while a screen
		-- has a live animation. Enters through the one queue like every other
		-- origin event (no second dispatch path); the animator eases on the true
		-- dt and marks the screen dirty, which drives the next solve.
		animation.on_tick(ev)
	elseif ev.class == "session" then
		-- Informational (C cannot be vetoed): drive the native lockscreen.
		-- A native lock hands keys to it below; an external locker is inert here.
		if ev.name == "key" then
			-- The lock key channel. C emits keys here INSTEAD of input::key
			-- while natively locked, so on_key (and every binding it could
			-- dispatch) is unreachable under the lockscreen no matter what a
			-- config does. The guarantee is C's; this is only the delivery.
			lockscreen.on_key(ev)
		elseif ev.name == "lock" then
			lockscreen.on_lock(ev.kind)
		elseif ev.name == "unlock" then
			lockscreen.on_unlock()
			-- C dropped seat focus when the lock engaged, but client.focus
			-- still names the pre-lock client, so :focus() would short-circuit
			-- as already-focused and never re-issue the C verb (leaving the
			-- desktop with no keyboard focus, and sloppy focus inert). Resync
			-- the cache to reality, then re-assert on the same client. A hover
			-- landing elsewhere still wins: the pointer_enter this unlock
			-- queues drains after us.
			local c = client.focus
			client.focus = nil
			if c ~= nil and c.handle ~= nil then
				c:focus()
			end
		end
	-- The grab rank: a claim on the keyboard or the
	-- pointer takes the queued event before bindings, chrome on_press,
	-- button {}, and the focus default. It is one branch, on the one queue:
	-- there is no second dispatch path, and C knows none of this.
	elseif ev.class == "input" and ev.name == "key" then
		if not grabber.route_key(ev) then
			on_key(ev)
		end
	elseif ev.class == "input" and ev.name == "motion" then
		-- Where the pointer is, as a fact left by the one event that knows it.
		-- Stashed before the grab rank, so a helper that reads it (placement's
		-- under_mouse) is still current during a drag. Nothing polls C for this.
		state.pointer = { x = ev.x, y = ev.y, screen = ev.screen }
		if not grabber.route_pointer(ev) then
			on_hover(ev)
		end
	elseif ev.class == "input" and ev.name == "button" then
		if not grabber.route_pointer(ev) then
			on_button(ev)
		end
	elseif ev.class == "input" and ev.name == "axis" then
		if not grabber.route_pointer(ev) then
			on_scroll(ev)
		end
	elseif ev.class == "input" and ev.name == "pointer_enter" then
		local c = ev.handle ~= nil and object.lookup(ev.handle) or nil
		if c ~= nil then
			c:emit("mouse::enter")
		end
	elseif ev.class == "output" and ev.name == "add" then
		local s = screen.new { name = ev.output, tags = {}, bars = {} }
		table.insert(state.screens, s)
		if screen.focused == nil then
			screen.focused = s
		end
		s:emit("added")
	elseif ev.class == "output" and ev.name == "change" then
		-- The poke: a mode, scale, position or enable
		-- landed. No payload, and none needed; the facts are in
		-- core.output.list() and the screen's own geometry is re-seeded from C
		-- on the next declare.
		--
		-- The re-solve itself needs nothing from here: C already marked the
		-- output dirty before queuing this event, and that mark is the only
		-- gate. What no one re-answers is
		-- the LAYER SURFACES. kiln.defaults.layer sizes a stretched surface from
		-- s.width/s.height and runs on map and commit only, so after a resize
		-- every bar, panel and wallpaper keeps answering the old geometry until
		-- it happens to commit again on its own.
		--
		-- Deferred rather than done here: this branch runs on the idle flush,
		-- BEFORE the frame that re-seeds s.width/s.height, so re-answering now
		-- would recompute the same stale size and fix nothing.
		local s = screen_by_name(ev.output)
		if s == nil then
			return
		end
		state.layer_reanswer[s.name] = true
		s:emit("changed")
	elseif ev.class == "output" and ev.name == "remove" then
		local s = screen_by_name(ev.output)
		if s == nil then
			return
		end
		remove_value(state.screens, s)
		-- No frames are coming for this screen, so a pending re-answer would
		-- outlive it and sit in the table for the process lifetime.
		state.layer_reanswer[s.name] = nil
		-- Drop the dead screen's stashed press handlers; they close over its
		-- bar state and would linger for the process lifetime otherwise.
		state.screen_presses[s.name] = nil
		-- A prompt on the dead screen would hold the keyboard while nothing
		-- declared it: no frames, no way to see what you are typing.
		if prompt.active ~= nil and prompt.active.screen == s then
			prompt.active:stop()
		end
		-- Same for a menu: its chain holds the keyboard too, and a chain
		-- nothing declares is a desktop with no reachable binding.
		if menu.open ~= nil and menu.open.screen == s then
			menu.close()
		end
		local survivor = state.screens[1]
		-- Don't leave focus pointing at a screen that no longer gets frame
		-- callbacks; hand it to a surviving one.
		if screen.focused == s then
			screen.focused = survivor
		end
		-- Rehome this screen's clients onto a survivor's selected tag. The
		-- dead screen gets no more frame callbacks, so a client left on it
		-- would never be declared again and vanish; the survivor's next
		-- frame re-borrows each one's scene tree.
		local dst = survivor ~= nil and survivor.selected_tag or nil
		if dst ~= nil then
			-- Collect first: reassigning c.tags removes the client from the
			-- very list being iterated. The dead tags go away with the screen,
			-- so every client simply lands on the survivor's selected tag,
			-- whatever it was tagged with before.
			local orphans = {}
			for _, t in ipairs(s.tags) do
				for _, c in ipairs(t.clients) do
					if not contains(orphans, c) then
						table.insert(orphans, c)
					end
				end
			end
			for _, c in ipairs(orphans) do
				c.tags = { dst }
			end
			dirty_screen(survivor)
		end
		s:emit("removed")
	end
end)

-- ---------------------------------------------------------------------
-- Plumbing re-exports.

-- kiln.spawn is callable (kiln.spawn("cmd") fire-and-forget) and a table
-- (kiln.spawn.pipe / kiln.spawn.watch, the async leg). The __call keeps
-- every existing kiln.spawn("cmd") call site working.
kiln.spawn = setmetatable(require("kiln.spawn"), {
	__call = function(_, cmd) return core.spawn(cmd) end,
})
-- Like spawn, but the child gets an XDG_ACTIVATION_TOKEN so it can raise itself
-- and the request arbitrates as user-initiated (xdg-activation).
kiln.spawn_with_token = core.spawn_with_token
-- The launcher spawns through the token verb, and it cannot require this table
-- without a cycle, so the verb is handed to it here rather than fetched there.
kiln.launcher.spawn = core.spawn_with_token
kiln.timer = core.timer
kiln.quit = core.quit
kiln.dirty = core.dirty
kiln.image_reload = core.image_reload

-- The Clay debug inspector: toggle the panel on a screen, defaulting to
-- the focused one. A toggle and not a setter because that is the whole of what
-- a keybinding wants; core.inspector is still there for a specific state or for
-- the style keys. Reading before writing is deliberate: Clay owns the flag (the
-- panel can close itself from inside the solver), so a toggle has to ask.
function kiln.inspector(s)
	s = s or focused_screen()
	if s == nil then
		return false
	end
	return core.inspector(s.name, not core.inspector(s.name))
end
kiln.object = object

-- ---------------------------------------------------------------------
-- Reload: re-run the config file in the live process, no restart.
--
-- The split is the whole point. C knows nothing about a config, a path, or a
-- reload; it owns one new fact, core.replay(), which re-states the map for every
-- client it still has. Everything else is policy and lives here: what a reload
-- drops, in what order, and what it rebuilds from.

-- The config file's path, captured while its chunk is still on the stack. C
-- loaded it with luaL_loadfile, so it is the outermost Lua chunk above this
-- require and its source names the path. The whole init.lua body runs inside
-- that require, so the walk works from anywhere here, and C keeps zero notion of
-- a file to re-run. (Asking C for the path is not an option worth taking: it
-- resolves against a compile-time datadir, so the answer is not Lua's to derive
-- but is Lua's to observe.)
local rc_path
do
	local level = 2
	while true do
		local info = debug.getinfo(level, "S")
		if info == nil then
			break
		end
		rc_path = info.source:match("^@(.+)$") or rc_path
		level = level + 1
	end
end

-- What a reload DROPS: everything the config built. What it KEEPS: everything
-- the compositor owns. Screens survive (replay re-states clients, never outputs,
-- so screen identity and order are load-bearing across the call), and so do
-- layers, notifications, running children, and the input settings.
--
-- The clients survive as CLIENTS but not as placement: an unruled client re-tags
-- onto the focused screen's selected tag and a float re-cascades, because the
-- new config's rules are the only tagging truth there is. An xdg-minimized
-- client comes back unminimized: that bit was Lua's, and Lua just dropped it.
function kiln.reload()
	-- 1. The async claims first, so nothing the old config armed can fire into
	-- the teardown below.
	require("kiln.spawn").reset()
	grabber.reset()

	-- 2. The registries the config fills by calling key {} / button {} / rule {}.
	kiln.key.clear()
	kiln.button.clear()
	kiln.rule.clear()

	-- 3. The buses, back to the listener set the library booted with. Not a
	-- wipe: the defaults registered by this module ARE boot-time listeners and
	-- never re-register (a module body runs once), and a config may have removed
	-- one on purpose, which reset restores.
	object.reset()
	-- The declare hooks the config registered, by the same reasoning: a hook
	-- closes over the config being replaced, and the rc re-running is what puts
	-- the new one's hooks back.
	hook.reset()
	-- And the ids those hooks were declaring under, or the rc's second run
	-- would find its own popup's id still taken.
	popup.reset()
	-- The launcher's scan cache and any filter the config replaced. The cache
	-- goes so a newly installed app shows up after a reload, which is the same
	-- freshness the config used to get for free when this lived in the rc.
	launcher.reset()
	error_bus.listeners = {}

	-- 4. Focus state. The history rebind is visible to the closures that read it.
	history = {}
	client.focus = nil

	-- 5. The client model and the per-screen config state. Detach walks the tags
	-- because the tags are where clients live; the writes go through _data to
	-- demolish quietly, since a property:: emission here would run the OLD
	-- config's handlers against half-torn state.
	for _, s in ipairs(state.screens) do
		for _, t in ipairs(s.tags) do
			for _, c in ipairs(t.clients) do
				object.detach(c.handle)
			end
		end
		s._data.tags = {}
		s._data.selected_tags = nil
		-- ui.bar appends, so a surviving list would stack a second bar per
		-- reload.
		s._data.bars = {}
	end

	-- 6. Re-run the file. A broken config leaves a live compositor rather than a
	-- dead session: the error surfaces the way every config error does, and the
	-- next successful reload recovers from here.
	local ok, err = pcall(dofile, rc_path)
	if not ok then
		Bus.on_error("reload", err)
	end

	-- 7. The screens are still here, so the new config's screen.on("added")
	-- never fires on its own: re-state them. Synchronous, so the tags and the bar
	-- exist before the replayed clients arrive looking for a tag.
	for _, s in ipairs(state.screens) do
		s:emit("added")
	end

	-- 8. The clients, restated by C onto the one origin queue. These drain after
	-- this call returns (an idle callback on the eval path, the rest of the
	-- flush loop on the keybinding path), by which time the config above is
	-- fully in place, which is the ordering that makes this whole function safe.
	core.replay()
	core.dirty()
end

-- ---------------------------------------------------------------------
-- kiln.input: PLAIN PROPERTIES, forwarded to the input verbs. Reading
-- returns the last written value; there is no readback from C by design,
-- so the store is the only truth about what was asked for.
--
-- The pointer fields go one at a time because core.input.set_pointer takes a
-- table of OPTIONAL fields (a nil field is untouched, carried by the has_ flags
-- in core_pointer_config), so sending only what changed is exactly its contract.
local input_store = {
	-- Seeded with the compositor's own defaults, not left nil: set_repeat is
	-- a TWO-ARG verb, so writing repeat_rate alone still has to pass a delay,
	-- and a nil delay is an argument error.
	repeat_rate = 25,
	repeat_delay = 600,
}

local pointer_props = {
	tap_to_click = true, natural_scrolling = true, left_handed = true,
	accel_speed = true, accel_profile = true, scroll_method = true,
	click_method = true,
}

kiln.input = setmetatable({}, {
	__index = function(_, k)
		return input_store[k]
	end,
	__newindex = function(_, k, v)
		input_store[k] = v
		if k == "keymap" then
			core.input.set_keymap(v or {})
		elseif k == "repeat_rate" or k == "repeat_delay" then
			core.input.set_repeat(input_store.repeat_rate,
				input_store.repeat_delay)
		elseif k == "numlock" then
			core.input.set_numlock(v)
		elseif pointer_props[k] then
			core.input.set_pointer({ [k] = v })
		end
	end,
})

-- The socket's command surface. Last of the requires because it reaches back
-- into this table for the verbs it wraps, which only exists once everything
-- above has run.
require("kiln.ipc").install(kiln)

-- The boot line for reload: every default this module registered is on the
-- buses now, and the config has not run yet, so this is exactly the listener set
-- kiln.reload() restores. Last statement before the return for that reason.
object.mark()
-- Same boot line for the declare hooks: every stdlib module has been required,
-- so the hooks registered by their module bodies are on the list now and the
-- config's are not. That split IS the reload tier.
hook.mark()
popup.mark()

return kiln
