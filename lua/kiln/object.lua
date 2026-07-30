-- The object mixin and the handle registry. One class() serves client,
-- screen, and tag alike: plain tables where every property write emits
-- property::<name> on the object and on the class. Zero per-property C.

local Bus = require("kiln.bus")

local object = {}

-- handle -> live object. C hands out handles from a monotonic counter
-- (never reused), so a stale handle simply misses here: the checked no-op.
local registry = {}

-- Every class bus ever made. A class bus is a closure upvalue with no accessor
-- (that is the point: nothing outside class.on/off can reach the listener list),
-- so the reload pair needs this list to find them all. One entry per
-- class, which is five: client, screen, tag, layer, notification.
local class_buses = {}

function object.class(class_name)
	local class = { classname = class_name }
	local class_bus = Bus.new()
	class_buses[#class_buses + 1] = class_bus

	-- Class-level signals catch every instance.
	function class.on(name, fn)
		return class_bus:on(name, fn)
	end

	function class.off(name, fn)
		class_bus:off(name, fn)
	end

	-- Exposed so the library layer can add methods (c:focus(), t:view());
	-- the mixin itself stays generic.
	local methods = {}
	class.methods = methods

	-- Computed read-only properties (screen.workarea = core.box readback):
	-- a getter is consulted on read when no method matches, before _data, so
	-- the value is recomputed each access and never goes stale. Additive to
	-- the property semantics: writes and property:: emission are untouched.
	local getters = {}
	class.getters = getters

	-- Computed writes, the twin of getters (c.tag = t is sugar for c.tags =
	-- { t }): a setter is consulted on write before _data, so one property can
	-- be the honest face of another instead of a second field that can disagree
	-- with it. A setter owns its own _data write and its own emit, because the
	-- interesting ones (tags, selected_tags) need the OLD value to diff against,
	-- which a property:: listener runs too late to see.
	local setters = {}
	class.setters = setters

	function methods:on(name, fn)
		return self._bus:on(name, fn)
	end

	function methods:off(name, fn)
		self._bus:off(name, fn)
	end

	function methods:emit(name, ...)
		self._bus:emit(name, self, ...)
		class_bus:emit(name, self, ...)
	end

	local meta = {
		__index = function(obj, key)
			local m = methods[key]
			if m ~= nil then
				return m
			end
			local g = getters[key]
			if g ~= nil then
				return g(obj)
			end
			return obj._data[key]
		end,
		__newindex = function(obj, key, value)
			local s = setters[key]
			if s ~= nil then
				return s(obj, value)
			end
			local old = obj._data[key]
			obj._data[key] = value
			if old ~= value then
				obj:emit("property::" .. key, value)
			end
		end,
	}

	function class.new(props)
		local obj = setmetatable({ _data = {}, _bus = Bus.new() }, meta)
		-- Seed without emitting: initial state is read at construction,
		-- not observed. Class-level listeners see only later writes.
		for k, v in pairs(props or {}) do
			obj._data[k] = v
		end
		return obj
	end

	return class
end

-- The reload pair, one call each for every class bus: mark the boot-time
-- listeners once, restore them on reload so the re-run config re-registers onto
-- the library's defaults instead of on top of its own last pass.
function object.mark()
	for _, bus in ipairs(class_buses) do
		bus:mark()
	end
end

function object.reset()
	for _, bus in ipairs(class_buses) do
		bus:reset()
	end
end

function object.attach(handle, obj)
	registry[handle] = obj
end

function object.detach(handle)
	registry[handle] = nil
end

function object.lookup(handle)
	return registry[handle]
end

return object
