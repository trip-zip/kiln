-- DnD. The drag grab is wlroots' own and the
-- icon rides the C-owned cursor band; all C reports is that a drag began or
-- ended, informational and unvetoable. This is the whole Lua surface: a signal
-- bus config subscribes to with drag.on("start"/"end", fn). There is no drop
-- target, no action, no selection here, because C arbitrates none of it.

local Bus = require("kiln.bus")

local drag = {}
local bus = Bus.new()

function drag.on(name, fn)
	return bus:on(name, fn)
end

function drag.off(name, fn)
	bus:off(name, fn)
end

-- Called by the init.lua dispatcher; "start" / "end", zero payload.
function drag.emit(name)
	bus:emit(name)
end

return drag
