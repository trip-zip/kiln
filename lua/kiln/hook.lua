-- The declare-hook registry: functions the runtime calls inside every screen's
-- declare, so chrome can be declared per frame by something that is not a bar.
--
-- A bar was the only per-frame slot a config owned, and a bar RESERVES an edge:
-- anything declared through one is a strut zone whether it wants to be or not.
-- Chrome that floats (a popup, a result list, an overlay) had to be smuggled
-- into a bar's declare function and pay for a reservation it never used.
--
-- Position is the other half of what this is for. Hooks run after the built-in
-- chrome that owns an element id, so a hook's float may attach to any of it on
-- the very first frame both exist. A float whose target has NEVER been declared
-- is a Clay error and aborts the compositor, which is the whole reason chrome
-- declared before this point can be attached to and chrome declared after it
-- cannot.

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

-- Called by the frame handler inside each screen's declare.
--
-- A failing hook is reported and the rest still run, because one config's
-- broken widget must not take the desktop's chrome with it. What it costs is
-- one frame of misnesting: elements the hook left open are still open when the
-- next hook declares, and C rebalances Clay's stack after the handler returns
-- rather than aborting on it. The next dirty frame declares from scratch.
function hook.run(s)
	-- Snapshot, so a hook that registers or removes one mid-declare does not
	-- skew this pass. Bus:emit guards its listeners the same way.
	local snapshot = { unpack(hooks) }
	for _, fn in ipairs(snapshot) do
		local ok, err = pcall(fn, s)
		if not ok then
			Bus.on_error("declare", err)
		end
	end
end

-- The reload pair, and the tiers it draws. mark() runs after every stdlib
-- module has been required (a module body registers its hook once) and before
-- the config runs, so the snapshot is exactly the stdlib's own hooks: those
-- survive a reload, and everything the config added is dropped. A config's
-- hooks come back by the same door they arrived through, the rc running again.
function hook.mark()
	marked = { unpack(hooks) }
end

function hook.reset()
	if marked == nil then
		return
	end
	hooks = { unpack(marked) }
end

return hook
