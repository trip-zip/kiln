-- Hooks run in registration order after the built-in desktop elements.
local Bus = require("kiln.bus")

local hook = {}

local hooks = {}
local marked = nil

-- add/remove rather than a handle object, and add returns the function it was
-- given: that is Bus:on/off's shape, and a declare hook is the same kind of
-- thing as a listener.
function hook.add(fn)
	hooks[#hooks + 1] = fn
	return fn
end

function hook.remove(fn)
	for i, f in ipairs(hooks) do
		if f == fn then
			table.remove(hooks, i)
			return
		end
	end
end

-- A failed hook must reject the whole candidate, including staged handlers.
function hook.run(s)
    local snapshot = { unpack(hooks) }
    for _, fn in ipairs(snapshot) do
        local ok, err = xpcall(function() fn(s) end, debug.traceback)
        if not ok then
            pcall(Bus.on_error, "declare", err)
            error(err, 0)
        end
    end
end

-- The reload pair, and the tiers it draws. mark() runs after every stdlib
-- module has been required (a module body registers its hook once) and before
-- the config runs, so the snapshot is exactly the stdlib's own hooks: those
-- survive a reload, and everything the config added is dropped. A config's
-- hooks come back by the same door they arrived through, the rc running again.
function hook.mark()
	if marked then return end
	marked = { unpack(hooks) }
end

function hook.reset()
	if marked == nil then
		return
	end
	hooks = { unpack(marked) }
end

return hook
