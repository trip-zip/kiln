local spawn = require('kiln.spawn')
local poll = {}
local Poll = {}
Poll.__index = Poll
function Poll:stop()
    self.stopped = true
    if self.watch then self.watch:stop(); self.watch=nil end
end
function poll.new(spec)
    local cmd = spec.cmd or spec[1]
    assert(cmd ~= nil, 'kiln.poll needs a command')
    assert(spec.parse==nil or type(spec.parse)=='function', 'poll parse must be a function')
    local self = setmetatable({lines={}}, Poll)
    local buf = {}
    self.watch = spawn.watch(cmd, spec.every or 5, {
        line=function(line) if not self.stopped then buf[#buf+1]=line end end,
        done=function()
            local lines = buf
            buf = {}
            if self.stopped then return end
            local generation = spawn.generation
            local value = lines[1]
            if spec.parse then value=spec.parse(lines) end
            if self.stopped or generation~=spawn.generation then return end
            -- Publish a complete answer only after parsing succeeds.
            self.lines = lines
            if value ~= self.value then
                self.value = value
                if spec.screen then core.dirty(spec.screen) else core.dirty() end
            end
        end,
    })
    return self
end
return setmetatable(poll, {__call=function(_, ...) return poll.new(...) end})
