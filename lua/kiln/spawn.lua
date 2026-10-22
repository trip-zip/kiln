-- Bytes and process facts arrive on the shared queue; framing belongs here.
local Bus = require('kiln.bus')
local spawn = {}
local pipes, watches = {}, {}
local function call(name, fn, ...)
    if fn == nil then return true end
    local ok, err = pcall(fn, ...)
    if not ok then pcall(Bus.on_error, name, err) end
    return ok
end
function spawn.pipe(cmd, cbs)
    cbs = cbs or {}
    for _, name in ipairs{'on_line', 'on_err', 'on_exit'} do
        assert(cbs[name] == nil or type(cbs[name]) == 'function', name .. ' must be a function')
    end
    local id = core.spawn_pipe(cmd)
    pipes[id] = {buf='', cbs=cbs}
    return id
end
function spawn.on_event(ev)
    local p = pipes[ev.id]
    if not p then return end
    if ev.name == 'out' then
        if ev.fd == 2 then call('spawn stderr', p.cbs.on_err, ev.data); return end
        p.buf = p.buf .. ev.data
        local start = 1
        while pipes[ev.id] == p do
            local at = p.buf:find('\n', start, true)
            if not at then break end
            local line = p.buf:sub(start, at-1)
            start = at+1
            call('spawn line', p.cbs.on_line, line)
        end
        p.buf = p.buf:sub(start)
    elseif ev.name == 'exit' then
        -- Cleanup does not depend on user callbacks returning successfully.
        pipes[ev.id] = nil
        local generation = spawn.generation
        if p.buf ~= '' then call('spawn line', p.cbs.on_line, p.buf) end
        if generation == spawn.generation then call('spawn exit', p.cbs.on_exit, ev.code) end
    end
end
function spawn.watch(cmd, interval, cb)
    assert(type(interval)=='number' and interval==interval and interval>=0 and interval<=2147483.647,
        'watch interval must be finite nonnegative seconds')
    local line, done
    if type(cb)=='table' then line,done=cb.line,cb.done else line=cb end
    assert(line==nil or type(line)=='function', 'watch line must be a function')
    assert(done==nil or type(done)=='function', 'watch done must be a function')
    local h = {dead=false}
    watches[h] = true
    function h.stop()
        if h.dead then return end
        h.dead = true
        watches[h] = nil
        if h.timer then core.timer_cancel(h.timer); h.timer=nil end
    end
    local function run()
        h.timer = nil
        if h.dead then return end
        local ok, err = pcall(spawn.pipe, cmd, {
            on_line=line,
            on_exit=function(code)
                if h.dead then return end
                -- Callback failures are reported but do not silently stop a watch.
                call('watch done', done, code)
                if not h.dead then
                    local armed, result = pcall(core.timer, interval*1000, run)
                    if armed then h.timer=result
                    else h.stop(); pcall(Bus.on_error, 'watch timer', result) end
                end
            end,
        })
        if not ok then h.stop(); pcall(Bus.on_error, 'watch launch', err) end
    end
    run()
    return h
end
spawn.generation = 0
function spawn.reset()
    spawn.generation = spawn.generation+1
    for h in pairs(watches) do h.stop() end
    pipes, watches = {}, {}
end
return setmetatable(spawn, {__call=function(_, ...) return core.spawn(...) end})
