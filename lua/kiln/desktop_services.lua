local services = {resetting=false}
local removing = setmetatable({}, {__mode="k"})
local function loaded(name) return package.loaded["kiln."..name] end
function services.reset()
    if services.resetting then return end
    services.resetting=true
    local p=loaded("prompt")
    if p and p.active then p.active:stop() end
    local m=loaded("menu"); if m then m.close() end
    local t=loaded("tooltip"); if t then t.hide() end
    local l=loaded("launcher"); if l then l.close(); l.reset() end
    local pop=loaded("popup"); if pop then pop.reset() end
    local g=loaded("grab"); if g then g.reset() end
    services.resetting=false
end
function services.remove(s)
    removing[s]=true
    local p=loaded("prompt"); if p and p.active and p.active.screen==s then p.active:stop() end
    local m=loaded("menu"); if m and m.open and m.open.screen==s then m.close() end
    local t=loaded("tooltip"); if t and t.open and t.open.screen==s then t.hide() end
    local pop=loaded("popup"); if pop then pop.remove(s) end
    removing[s]=nil
end
function services.live(s)
    if services.resetting or removing[s] then return false end
    for _, candidate in ipairs(screen.all()) do if candidate==s then return true end end
    return false
end
return services
