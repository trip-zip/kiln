-- The popup: open state, a keyboard claim, a scrim, and a per-frame declare,
-- offered once instead of hand-rolled per piece of chrome.
--
-- Every popup in this stdlib was writing the same four things. The menu, the
-- hotkeys sheet and the launcher each kept a module-level open field, each
-- released its own claim before taking a new one, each floated a screen-sized
-- capture rect to catch the press that landed outside, and each had a declare
-- the frame handler called by name. The parts are small; keeping four copies of
-- them in step was not.
--
-- What a popup is NOT is a surface. It is chrome in the screen's one Clay
-- context, declared while it is open and simply not declared when it is not, so
-- there is no window to create, no geometry to compute, and nothing to hide.
--
-- It lives beside menu.lua for menu.lua's reason: it owns cross-frame state and
-- rides the declare registry, and ui.lua is the element layer. The public name
-- is ui.popup, bound in init.lua, because ui.lua cannot require this without a
-- cycle.

local ui = require("kiln.ui")
local state = require("kiln.state")
local grab = require("kiln.grab")
local hook = require("kiln.hook")

local popup = {}

-- Every live popup by id. Two jobs: it refuses a second popup on an id already
-- taken, and it is what reload restores. A popup is built ONCE and lives for the
-- session, because construction registers a declare hook; building one inside a
-- key handler would add a hook per press and leak with no symptom but a slowly
-- heavier frame.
local live = {}
local marked = nil

local Popup = {}
Popup.__index = Popup

-- Give the keyboard back. The field is cleared BEFORE the stop, so the
-- grabber's own stopped callback finds no claim of ours and does not come back
-- around through close.
function Popup:release()
	local c = self.claim
	if c == nil then
		return
	end
	self.claim = nil
	c:stop()
end

-- One queued key, routed here ahead of every binding. An entry names a verb
-- ("close") or a function; `any` catches what nothing else named. A key the map
-- does not know is CONSUMED and does nothing, because a grab is a claim on the
-- device and not a filter on some of its events: letting it fall through to a
-- binding would run that binding with a popup still up over it.
function Popup:on_key(ev)
	if not ev.pressed then
		return
	end
	local keys = self.spec.keys
	if type(keys) == "function" then
		keys(ev, self)
		return
	end
	local act = keys[ev.key] or keys.any
	if act == "close" then
		self:close()
	elseif type(act) == "function" then
		act(ev, self)
	end
end

-- Open on a screen. The claim IS the popup's lifetime when it asks for keys;
-- a popup with no `keys` takes nothing, which is what lets it coexist with
-- something else that owns the keyboard (the launcher's list over the prompt).
function Popup:show(s)
	s = s or self.spec.screen or screen.focused or state.screens[1]
	if s == nil then
		return
	end
	self.open = s
	if self.spec.keys ~= nil then
		-- Our own previous claim goes first and by hand, because letting the
		-- grabber stop it would run its stopped callback against the popup that
		-- just replaced it.
		self:release()
		local c
		c = grab.keygrabber {
			key = function(ev)
				self:on_key(ev)
			end,
			stopped = function()
				-- Something else took the keyboard (another popup, a prompt, the
				-- reload reset). A popup that cannot be dismissed is not the one
				-- that was opened, so it goes with its claim.
				if self.claim == c then
					self.claim = nil
					self:close()
				end
			end,
		}
		self.claim = c
	end
	core.dirty(s.name)
	return self
end

function Popup:close()
	if self.open == nil then
		return
	end
	core.dirty(self.open.name)
	self.open = nil
	self:release()
	if self.spec.on_close ~= nil then
		self.spec.on_close(self)
	end
end

function Popup:toggle(s)
	if self.open ~= nil then
		self:close()
	else
		self:show(s)
	end
end

-- Take the popup back: close it, drop its declare hook, and free its id. The
-- supported way to unbuild one, since construction is not repeatable.
function Popup:destroy()
	self:close()
	hook.remove(self.hook)
	live[self.id] = nil
end

-- Where Clay attaches the box. Three shapes, because there are three things to
-- attach to: another element, a point, or the screen. No arithmetic in any of
-- them; the attach pair says it all and Clay does the placing.
function Popup:float(spec)
	local f = {
		band = spec.band or "overlay",
		fit = spec.fit ~= false,
		-- Over its own scrim. The two tie in the band otherwise and resolve by
		-- declare order, which would also work, but a scrim is the one thing
		-- that must never come out on top and saying so costs one field.
		z = 1,
	}
	if spec.under ~= nil then
		f.to, f.parent = "element", spec.under
		-- Dropped from the target's bottom edge rather than centered on it: a
		-- popup opened from a bar cell should clear the cell, not cover it.
		f.anchor = spec.anchor
			or { parent = "left_bottom", element = "left_top" }
	elseif spec.at ~= nil then
		f.to = "root"
		f.offset = { x = spec.at.x or spec.at[1], y = spec.at.y or spec.at[2] }
		f.anchor = spec.anchor
	else
		f.to = "root"
		f.anchor = spec.anchor or "center"
	end
	return f
end

-- Called by the declare registry inside every screen's declare. Nothing is
-- declared when the popup is closed, or when it belongs to another screen.
function Popup:declare(s)
	if self.open ~= s then
		return
	end
	local spec = self.spec
	-- Styling read at DECLARE, not at construction. A popup is built once and
	-- lives for the session, so a colour captured in the spec is the palette
	-- that was loaded the first time this module ran, and a theme switch would
	-- leave the popup painted in the old one. `style` is a function returning
	-- the fields that follow the theme; it shadows the static spec and anything
	-- it leaves out falls through, so a popup with no live styling writes none.
	if spec.style ~= nil then
		spec = setmetatable(spec.style(self) or {}, { __index = self.spec })
	end
	if spec.scrim then
		-- The scrim: a screen-sized float UNDER the popup that catches the press
		-- landing outside it. Dispatch is innermost-first with no bubbling, so a
		-- press on the popup hits the popup and never reaches this. `true` means
		-- invisible but hittable: Clay emits a rect only above zero alpha, and a
		-- rect is what makes it a scene node at all, so the alpha is 1/255.
		ui.box({
			id = self.id .. ":scrim",
			float = { to = "root", band = spec.band or "overlay" },
			w = s.width, h = s.height,
			color = spec.scrim == true and "#00000001" or spec.scrim,
			on_press = function()
				self:close()
			end,
		})
	end
	-- A column, because a popup is a stack of rows often enough that it is the
	-- useful default; a caller wanting anything else declares it inside fn.
	ui.column({
		id = self.id,
		float = self:float(spec),
		w = spec.w, h = spec.h,
		color = spec.color, radius = spec.radius,
		pad = spec.pad, gap = spec.gap, align = spec.align,
		border = spec.border,
		clip = spec.clip,
	}, spec.fn and function()
		spec.fn(self, s)
	end or nil)
end

-- ui.popup(spec) -> handle. See the header for the shape; the guards below are
-- the two ways to get it wrong that would otherwise be silent.
function popup.new(spec)
	local id = spec.id
	-- A plain string, because a table id's second element must be NUMERIC: a
	-- string there collides at index 0 and aborts the compositor on
	-- DUPLICATE_ID. The scrim's id is derived from this one, so it inherits the
	-- same rule.
	if type(id) ~= "string" then
		error("ui.popup needs a plain string id", 2)
	end
	if live[id] ~= nil then
		error("ui.popup: id already in use: " .. id, 2)
	end
	local self = setmetatable({
		id = id,
		spec = spec,
		open = nil,
		claim = nil,
	}, Popup)
	live[id] = self
	self.hook = hook.add(function(s)
		self:declare(s)
	end)
	return self
end

-- The reload pair, and it is not optional: a config's popups are dropped from
-- the declare registry on reload, and the rc re-runs and builds them again. With
-- no reset here the second construction would find its own id still taken and
-- the reload would fail on the config's first popup. The stdlib's popups are
-- built by module bodies before mark(), so they survive, exactly as their hooks
-- do.
function popup.mark()
	local m = {}
	for id, p in pairs(live) do
		m[id] = p
	end
	marked = m
end

function popup.reset()
	if marked == nil then
		return
	end
	local l = {}
	for id, p in pairs(marked) do
		l[id] = p
	end
	live = l
end

return popup
