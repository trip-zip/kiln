-- Protocol facts survive config replacement; grants and sizing remain Lua policy.
local object = require('kiln.object')
local layers = { all = {} }
layer = object.class('layer')
function layers.is(obj)
    for _,l in ipairs(layers.all) do if l==obj then return true end end
    return false
end

function layers.target()
    local chosen
    for _, l in ipairs(layers.all) do
        if l.mapped and l.screen and l.kb_granted then chosen = l end
    end
    return chosen
end

return setmetatable(layers, {__call=function(_, kiln, by_name, restore)
    local function dirty(l) if l.screen then core.dirty(l.screen.name) end end
    local function keyboard()
        local target = layers.target()
        if target then core.client.focus(target.handle) else restore() end
    end
    function kiln.defaults.layer(l)
        local s = l.screen
        if not s then return end
        local w,h = l.desired_w,l.desired_h
        if w==0 and l.anchors.left and l.anchors.right then w=s.width-l.margin.left-l.margin.right end
        if h==0 and l.anchors.top and l.anchors.bottom then h=s.height-l.margin.top-l.margin.bottom end
        w,h=math.max(0,w),math.max(0,h)
        core.layer_configure(l.handle,w,h)
        l.w,l.h=w,h
        dirty(l)
    end
    function kiln.defaults.layer_keyboard(l)
        local want=l.mapped and l.interactivity=='exclusive'
        if l.kb_granted~=want then l.kb_granted=want;keyboard() end
    end
    function kiln.defaults.layer_release(l)
        if l.kb_granted then l.kb_granted=false;keyboard() end
    end
    local defaults={layer=kiln.defaults.layer,layer_keyboard=kiln.defaults.layer_keyboard,layer_release=kiln.defaults.layer_release}
    for _,name in ipairs{'map','commit'} do
        layer.on(name,function(l) kiln.defaults.layer(l) end)
        layer.on(name,function(l) kiln.defaults.layer_keyboard(l) end)
    end
    for _,name in ipairs{'unmap','destroy'} do layer.on(name,function(l) kiln.defaults.layer_release(l) end) end
    function layers.dispatch(ev)
        local l=object.lookup(ev.handle)
        if ev.name=='map' and not l then
            l=layer.new{handle=ev.handle}
            object.attach(ev.handle,l)
            layers.all[#layers.all+1]=l
        end
        if not l then return end
        if ev.name=='map' or ev.name=='commit' or ev.name=='mapped' then
            local previous=l.screen
            for _,k in ipairs{'namespace','output','layer','interactivity','anchors','margin','exclusive','buffer_mapped'} do l[k]=ev[k] end
            l.desired_w,l.desired_h=ev.width,ev.height
            if ev.output then l.screen=by_name(ev.output)
            else l.screen=l.screen or screen.focused or screen.all()[1] end
            if ev.name=='map' then l.w,l.h=nil,nil;l.mapped=true end
            if previous and previous~=l.screen then core.dirty(previous.name) end
            l:emit(ev.name)
            dirty(l)
        else
            l.mapped,l.buffer_mapped=false,false
            l.w,l.h=nil,nil
            l:emit(ev.name)
            dirty(l)
            if ev.name=='destroy' then
                object.detach(l.handle)
                for i,v in ipairs(layers.all) do if v==l then table.remove(layers.all,i);break end end
                l._data.dead=true
            end
        end
    end
    function layers.for_screen(s)
        local out={}
        for _,l in ipairs(layers.all) do
            if l.screen==s and l.mapped and l.buffer_mapped then out[#out+1]=l end
        end
        return out
    end
    function layers.refresh()
        for _,l in ipairs(layers.all) do
            if l.mapped then
                local old=l.screen
                if l.output then l.screen=by_name(l.output)
                else l.screen=(old and by_name(old.name)) or screen.focused or screen.all()[1] end
                if l.screen then l:emit('commit');dirty(l) end
            end
        end
        keyboard()
    end
    function layers.reset()
        for k,v in pairs(defaults) do kiln.defaults[k]=v end
        for _,l in ipairs(layers.all) do l._bus:reset();l.kb_granted=false end
    end
    function layers.changed(s)
        for _,l in ipairs(layers.all) do if l.screen==s and l.mapped then l:emit('commit');dirty(l) end end
    end
end})
