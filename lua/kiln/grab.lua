-- Claims own policy. Native routing only knows whether a device is claimed.
local Bus = require('kiln.bus')
local grab, claims = {}, {}
local resetting = false
local claim = {}
claim.__index = claim
local function native(kind, on)
    if kind == 'key' then core.input.grab_keyboard(on)
    else core.input.grab_pointer(on) end
end
local function report(name, err) pcall(Bus.on_error, name, err) end
function claim:stop()
    if not self.active then return end
    self.active = false
    if claims[self.kind] == self then
        claims[self.kind] = nil
        native(self.kind, false)
    end
    if self.stopped then
        local ok, err = pcall(self.stopped)
        if not ok then report(self.kind .. 'grabber stopped', err) end
    end
end
local function start(kind, spec, names)
    assert(type(spec) == 'table', 'grabber needs a table')
    local c = setmetatable({kind=kind, active=not resetting}, claim)
    for _, name in ipairs(names) do
        local fn = spec[name]
        if kind == 'key' and name == 'key' then fn = fn or spec[1] end
        assert(fn == nil or type(fn) == 'function', name .. ' must be a function')
        c[name] = fn
    end
    if resetting then return c end
    local old = claims[kind]
    -- Publish first: a claim created by stopped is newer and wins replacement.
    claims[kind] = c
    native(kind, true)
    if old then old:stop() end
    return c
end
function grab.keygrabber(spec) return start('key', spec, {'key','stopped'}) end
function grab.mousegrabber(spec) return start('mouse', spec, {'motion','button','axis','stopped'}) end
local function route(c, name, ev)
    if not c then return ev._claimed or false end
    if c[name] then
        local ok, err = pcall(c[name], ev)
        if not ok then c:stop(); report(c.kind .. 'grabber ' .. name, err) end
    end
    return true
end
function grab.route_key(ev) return route(claims.key, 'key', ev) end
function grab.route_pointer(ev) return route(claims.mouse, ev.name, ev) end
function grab.pointer_active() return claims.mouse ~= nil end
function grab.reset()
    if resetting then return end
    resetting = true
    if claims.key then claims.key:stop() end
    if claims.mouse then claims.mouse:stop() end
    native("key",false)
    native("mouse",false)
    resetting = false
end
return grab
