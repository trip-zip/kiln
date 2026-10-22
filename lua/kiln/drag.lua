local bus = require('kiln.bus').new()
local drag = {}
function drag.on(name, fn) return bus:on(name, fn) end
function drag.off(name, fn) bus:off(name, fn) end
function drag.emit(name) bus:emit(name) end
function drag.reset() bus:reset() end
return drag
