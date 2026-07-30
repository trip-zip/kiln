-- keygrabber and mousegrabber: Lua-side claims on the one input queue.
-- A grab is not a mode C runs. C flips
-- one routing bit per device (nothing forwards to clients) and keeps queueing
-- key, motion, button, and axis exactly as it always did; everything else is
-- here. The runtime hands a queued event to the holder of the claim BEFORE
-- bindings, chrome on_press, button {}, and the focus default,
-- and a release restores that order with no residue.
--
-- One claim per device, no stack: starting a grab while another holds stops
-- the old one first, so a claim never outlives its owner's intent and nothing
-- accumulates behind it. A grabber whose callback errors is released before
-- the error surfaces, because a broken grabber that kept the keyboard would
-- leave the desktop with no reachable binding.

local Bus = require("kiln.bus")

local grab = {}

local key_claim = nil
local pointer_claim = nil

local claim = {}
claim.__index = claim

function claim:stop()
	if not self.active then
		return
	end
	self.active = false
	if self.kind == "key" then
		key_claim = nil
		core.input.grab_keyboard(false)
	else
		pointer_claim = nil
		core.input.grab_pointer(false)
	end
	if self.stopped ~= nil then
		local ok, err = pcall(self.stopped)
		if not ok then
			Bus.on_error(self.kind .. "grabber stopped", err)
		end
	end
end

-- Dispatch one queued event to the claim. Returns true when a claim holds,
-- which is the whole of "the grabber outranks everything": the caller stops.
-- The claim consumes the event even with no handler for it (a mousegrabber
-- with no axis handler swallows the wheel), because a grab is a claim on the
-- device, not a filter on some of its events.
local function route(c, name, ev)
	if c == nil then
		return false
	end
	local fn = c[name]
	if fn ~= nil then
		local ok, err = pcall(fn, ev)
		if not ok then
			c:stop()
			Bus.on_error(c.kind .. "grabber " .. name, err)
		end
	end
	return true
end

-- kiln.keygrabber { key = function(ev) end, stopped = function() end }
--
-- Holds the keyboard until :stop(). ev is the ordinary input::key origin
-- event, utf8 field included, so composed text arrives here for free: the
-- resolution happens once, C-side, for every key on the queue, grabbed or not.
function grab.keygrabber(spec)
	local c = setmetatable({
		kind = "key",
		key = spec.key or spec[1],
		stopped = spec.stopped,
		active = true,
	}, claim)
	if key_claim ~= nil then
		key_claim:stop()
	end
	key_claim = c
	core.input.grab_keyboard(true)
	return c
end

-- kiln.mousegrabber { motion = fn, button = fn, axis = fn, stopped = fn }
--
-- Holds the pointer until :stop(). The handlers take the matching input origin
-- event; C withholds all three from clients for the duration.
function grab.mousegrabber(spec)
	local c = setmetatable({
		kind = "mouse",
		motion = spec.motion,
		button = spec.button,
		axis = spec.axis,
		stopped = spec.stopped,
		active = true,
	}, claim)
	if pointer_claim ~= nil then
		pointer_claim:stop()
	end
	pointer_claim = c
	core.input.grab_pointer(true)
	return c
end

-- Drop every claim on reload. A config's grabber closes over the config
-- that is being replaced, and the runtime's own drag holds a client the reload
-- is about to detach; either one left holding would outrank every binding the
-- new config registers. stop() is the same door a release uses, so each claim's
-- stopped callback runs and its owner unwinds itself (the drag clears its own
-- state that way).
function grab.reset()
	if key_claim ~= nil then
		key_claim:stop()
	end
	if pointer_claim ~= nil then
		pointer_claim:stop()
	end
end

function grab.route_key(ev)
	return route(key_claim, "key", ev)
end

-- One entry for the three pointer events; ev.name is the handler name.
function grab.route_pointer(ev)
	return route(pointer_claim, ev.name, ev)
end

return grab
