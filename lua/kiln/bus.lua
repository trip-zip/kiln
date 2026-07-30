-- The signal bus: names mapped to listener lists, pcall isolation per
-- listener. Every class and every object carries its own instance.

local Bus = {}
Bus.__index = Bus

-- Overridable error sink; the library layer routes this into
-- kiln.on("error") listeners.
Bus.on_error = function(signal, err)
	print("bus error in '" .. signal .. "': " .. tostring(err))
end

function Bus.new()
	return setmetatable({ listeners = {} }, Bus)
end

function Bus:on(name, fn)
	local list = self.listeners[name]
	if list == nil then
		list = {}
		self.listeners[name] = list
	end
	list[#list + 1] = fn
	return fn
end

function Bus:off(name, fn)
	local list = self.listeners[name]
	if list == nil then
		return
	end
	for i, f in ipairs(list) do
		if f == fn then
			table.remove(list, i)
			return
		end
	end
end

-- The reload pair. mark() is called once, after the library's own default
-- handlers are registered and before the config file runs; reset() restores that
-- boot-time listener set, dropping everything the config added.
--
-- A snapshot, not a count: the config may REMOVE a default (rc.lua drops the
-- activate default), and truncating back to a boot-time length cannot put it
-- back. Copies both ways, so neither side aliases the live lists.
function Bus:mark()
	local marked = {}
	for name, list in pairs(self.listeners) do
		marked[name] = { unpack(list) }
	end
	self.marked = marked
end

function Bus:reset()
	if self.marked == nil then
		return
	end
	local listeners = {}
	for name, list in pairs(self.marked) do
		listeners[name] = { unpack(list) }
	end
	self.listeners = listeners
end

function Bus:emit(name, ...)
	local list = self.listeners[name]
	if list == nil then
		return
	end
	-- Snapshot so listeners that subscribe or unsubscribe mid-emit do not
	-- skew the iteration.
	local snapshot = { unpack(list) }
	for _, fn in ipairs(snapshot) do
		local ok, err = pcall(fn, ...)
		if not ok then
			Bus.on_error(name, err)
		end
	end
end

return Bus
