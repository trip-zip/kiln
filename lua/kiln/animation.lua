local animation = {}
local anims, live, last, owners = {}, {}, {}, {}
local function value(a)
    local p = a.dur > 0 and math.min(a.elapsed/a.dur, 1) or 1
    return a.from + (a.to-a.from) * (1-(1-p)^3)
end
local function release(screen)
    live[screen] = live[screen]-1
    if live[screen]==0 then live[screen]=nil; core.tick(screen, false) end
end
function animation.get(key, default)
    if anims[key] then return value(anims[key]) end
    last[key] = default
    return default
end
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
function animation.start(screen, key, target, duration, from)
    duration = duration or .15
    assert(type(screen)=='string' and key~=nil, 'animation needs screen and key')
    assert(finite(target) and finite(duration) and duration>=0 and (from==nil or finite(from)),
        'animation values must be finite and duration nonnegative')
    local old = anims[key]
    from = from or (old and value(old)) or last[key] or target
    if old and old.screen~=screen then release(old.screen) end
    if not old or old.screen~=screen then
        live[screen]=(live[screen] or 0)+1
        if live[screen]==1 then core.tick(screen,true) end
    end
    owners[key]=screen
    anims[key]={screen=screen,from=from,to=target,elapsed=0,dur=duration}
    core.dirty(screen)
end
function animation.on_tick(ev)
    if not live[ev.screen] then return end
    local dt = math.min(ev.dt,.05)
    for key,a in pairs(anims) do
        if a.screen==ev.screen then
            a.elapsed=a.elapsed+dt
            if a.elapsed>=a.dur then
                last[key]=a.to
                anims[key]=nil
                release(ev.screen)
            end
        end
    end
    core.dirty(ev.screen)
end
function animation.remove(screen)
    for key,a in pairs(anims) do
        if a.screen==screen then anims[key]=nil; last[key]=nil end
    end
    for key,owner in pairs(owners) do
        if owner==screen then last[key]=nil; owners[key]=nil end
    end
    if live[screen] then core.tick(screen,false) end
    live[screen]=nil
end
function animation.reset()
    for screen in pairs(live) do core.tick(screen,false) end
    anims,live,last,owners={},{},{},{}
end
return animation
