-- Policy and object state live here; the native boundary carries only facts.
local Bus = require('kiln.bus')
local object = require('kiln.object')
local kiln = { modkey = "alt", defaults = {}, spawn = require("kiln.spawn"), spawn_with_token = core.spawn_with_token, timer = core.timer, quit = core.quit, dirty = core.dirty }
kiln.object=object
kiln.poll=require('kiln.poll')
local animation=require('kiln.animation')
kiln.animation=animation
kiln.input=require('kiln.input')
kiln.ui=require('kiln.ui')
local ui_input=require('kiln.ui_input')
local state=require('kiln.state')
local hook=require("kiln.hook")
kiln.on_declare,kiln.off_declare=hook.add,hook.remove
local grab=require('kiln.grab')
drag=require('kiln.drag')
kiln.keygrabber,kiln.mousegrabber=grab.keygrabber,grab.mousegrabber
kiln.theme=require('kiln.state').theme
kiln.layout=require('kiln.layout')
kiln.placement=require('kiln.placement')
kiln.widgets=require('kiln.widgets')
kiln.icon=require("kiln.icon")
kiln.asset=require("kiln.asset")
kiln.image_reload=core.image_reload
local notif=require("kiln.notification")
kiln.notify=notif.notify
kiln.systray=require("kiln.systray")
kiln.defaults.notify_display=notif.display
local lockscreen=require("kiln.lockscreen")
kiln.lockscreen=lockscreen
kiln.lock,kiln.unlock=core.lock,core.unlock
local bus = Bus.new()
function kiln.set_idle_timeout(ms)
    return core.set_idle_timeout(ms)
end

function kiln.on(name, fn) return bus:on(name, fn) end
function kiln.off(name, fn) bus:off(name, fn) end
local reporting = false
local function report_error(name, err)
    local ok, message = pcall(tostring, err)
    io.stderr:write("kiln: error in '" .. name .. "': " .. (ok and message or '?') .. '\n')
    if reporting then return end
    reporting = true
    bus:emit('error', name, err)
    reporting = false
end

Bus.on_error = report_error

client = object.class('client')
screen = object.class('screen')
tag = object.class('tag')
local screens, live, announced, histories = {}, {}, {}, {}
local history, mapping = {}, 0
local layers=require('kiln.layers')
local function contains(list, value)
    for _, v in ipairs(list or {}) do if v == value then return true end end
    return false
end
local function remove(list, value)
    for i, v in ipairs(list) do if v == value then table.remove(list, i); return end end
end
local function same(a, b)
    if #a ~= #b then return false end
    for i, v in ipairs(a) do if v ~= b[i] then return false end end
    return true
end
local function dirty(s) if s and contains(screens, s) then core.dirty(s.name) end end
local function dirty_client(c)
    for _, t in ipairs(c.tags) do dirty(t.screen) end
end
local function by_name(name)
    for _, s in ipairs(screens) do if s.name == name then return s end end
end
local policy = require('kiln.policy')(kiln, by_name)
local function valid_tag(t)
    return t and contains(screens, t.screen) and contains(t.screen.tags, t)
end
function screen.all() return screens end
screen.getters.canvas = function() return core.box('root') end
screen.getters.scale = function(s)
    if contains(screens,s) then
        for _,o in ipairs(core.output.list()) do if o.name==s.name then return o.scale end end
    end
    return 1
end
screen.setters.scale = function(s,value)
    if contains(screens,s) then core.output.set_scale(s.name,value) end
end
function client.all()
    local out = {}
    for _, s in ipairs(screens) do
        for _, t in ipairs(s.tags) do
            for _, c in ipairs(t.clients) do
                if not contains(out, c) then out[#out + 1] = c end
            end
        end
    end
    return out
end
client.getters.tag = function(c) return c.tags[1] end
client.setters.tag = function(c, t) c.tags = t and {t} or {} end
client.getters.screen = function(c) return c.tag and c.tag.screen end
client.getters.parent = function(c) return object.lookup(c.transient_for) end
-- Workareas are output-local solved boxes, independent of core.box's current context.
screen.getters.workarea = function(s)
    local b = require('kiln.state').workareas[s.name]
    if b then return {x=b.x,y=b.y,width=b.width,height=b.height} end
end
screen.getters.selected_tag = function(s) return s.selected_tags[1] end
screen.setters.selected_tag = function(s, t) s.selected_tags = t and {t} or {} end
tag.getters.selected = function(t) return t.screen and contains(t.screen.selected_tags, t) or false end

-- A surface has one scene tree. Prefer its first tag's screen when selected,
-- then the first visible membership in screen discovery order.
local function owner(c)
    if not c.mapped or c.minimized or object.lookup(c.handle) ~= c then return end
    if c.sticky and contains(screens, c.screen) then return c.screen end
    local function selected(s)
        for _, t in ipairs(c.tags) do if valid_tag(t) and t.screen == s and t.selected then return true end end
    end
    if contains(screens, c.screen) and selected(c.screen) then return c.screen end
    for _, s in ipairs(screens) do if selected(s) then return s end end
end
local function visible(s)
    local out = {}
    for _, t in ipairs(s.selected_tags) do
        for _, c in ipairs(t.clients) do
            if owner(c) == s and not contains(out, c) then out[#out + 1] = c end
        end
    end
    for _, t in ipairs(s.tags) do
        for _, c in ipairs(t.clients) do
            if c.sticky and owner(c) == s and not contains(out, c) then out[#out+1] = c end
        end
    end
    return out
end
-- The union has one owner and one declaration for every eligible client.
kiln.visible_clients = visible
require('kiln.interactive')(owner)
local function clear_focus()
    if client.focus then core.client.set_activated(client.focus.handle, false); dirty_client(client.focus) end
    client.focus = nil
    core.client.focus(nil)
end
function client.methods:focus()
    local s = owner(self)
    if not s or mapping > 0 or layers.target() then return end
    if client.focus == self then
        screen.focused = s
        return
    end
    if client.focus then core.client.set_activated(client.focus.handle, false); dirty_client(client.focus) end
    client.focus, screen.focused = self, s
    if self.urgent then self.urgent = false end
    core.client.set_activated(self.handle, true)
    core.client.focus(self.handle)
    self:emit('focus')
end
client.on('focus', function(c)
    if client.focus ~= c then return end
    remove(history, c)
    table.insert(history, 1, c)
    if c.floating or c.fullscreen or c.maximized then c:raise() end
    dirty_client(c)
end)
client.history = setmetatable({}, {__call=function() return {unpack(history)} end})
function client.history.previous()
    for _, c in ipairs(history) do
        if c ~= client.focus and c.mapped and not c.minimized then return c end
    end
end
function kiln.defaults.successor(gone)
    local s = gone.screen
    if not s then return end
    for _, c in ipairs(history) do
        if c ~= gone and c.mapped and not c.minimized and owner(c) == s then return c end
    end
end
function kiln.defaults.activate(c, ctx)
    if ctx.valid then c:focus() else c.urgent = true end
end
function kiln.defaults.close(c) c:close() end
client.on('request::activate', kiln.defaults.activate)
client.on('request::close', kiln.defaults.close)
local function repair_focus(s)
    if mapping > 0 then return end
    if layers.target() then
        if client.focus and not owner(client.focus) then client.focus=nil end
        return
    end
    if client.focus and owner(client.focus) then
        screen.focused = owner(client.focus)
        return
    end
    local gone = client.focus
    clear_focus()
    s = contains(screens, s) and s or screen.focused or screens[1]
    local next_client
    if gone then
        local ok
        ok, next_client = pcall(kiln.defaults.successor, gone)
        if not ok then pcall(Bus.on_error, 'successor', next_client); return end
    else
        for _, c in ipairs(history) do
            if owner(c) == s and not c.minimized then next_client = c; break end
        end
    end
    if next_client and owner(next_client) then next_client:focus() end
end
layers(kiln,by_name,function()
    if client.focus and owner(client.focus) then core.client.focus(client.focus.handle)
    else
        repair_focus()
        if not client.focus then
            local s=screen.focused or screens[1]
            local c=s and visible(s)[1]
            if c then c:focus() end
        end
    end
end)
function client.methods:close()
    if object.lookup(self.handle) == self then core.client.close(self.handle) end
end
function client.methods:kill()
    if object.lookup(self.handle) == self then core.client.kill(self.handle) end
end
local function reorder(c, last)
    if object.lookup(c.handle) ~= c then return end
    for _, t in ipairs(c.tags) do
        local at = last and #t.clients or 1
        if t.clients[at] ~= c then
            remove(t.clients, c)
            table.insert(t.clients, at, c)
            dirty(t.screen)
        end
    end
end
function client.methods:raise() reorder(self, true) end
function client.methods:lower() reorder(self, false) end
function client.methods:swap(other)
    if not other or other == self or object.lookup(self.handle) ~= self
        or object.lookup(other.handle) ~= other then return end
    for _, t in ipairs(self.tags) do
        local a, b
        for i, c in ipairs(t.clients) do if c == self then a=i elseif c == other then b=i end end
        if a and b then t.clients[a], t.clients[b] = other, self; dirty(t.screen) end
    end
end
function client.methods:move_to(target)
    if object.lookup(self.handle) ~= self or not contains(screens, target) then return end
    local dst = target.selected_tag
    if not dst or self.tag == dst then return end
    self.tags = {dst}
    self:focus()
end
client.setters.tags = function(c, list)
    if c._data.dead then return end
    local next_tags = {}
    for _, t in ipairs(list or {}) do
        assert(valid_tag(t), 'client tags must be live tags')
        if not contains(next_tags, t) then next_tags[#next_tags + 1] = t end
    end
    local old = c._data.tags or {}
    if same(old, next_tags) then return end
    local previous_screen = c.screen
    c._data.tags = next_tags
    for _, t in ipairs(old) do
        if not contains(next_tags, t) then remove(t.clients, c); c:emit('untagged', t) end
        dirty(t.screen)
    end
    for _, t in ipairs(next_tags) do
        if not contains(old, t) then t.clients[#t.clients + 1] = c; c:emit('tagged', t) end
        dirty(t.screen)
    end
    c:emit('property::tags', next_tags)
    repair_focus(previous_screen)
end
screen.setters.selected_tags = function(s, list)
    if not contains(screens, s) then return end
    local next_sel = {}
    for _, t in ipairs(list or {}) do
        assert(valid_tag(t) and t.screen == s, 'selection must belong to this screen')
        if not contains(next_sel, t) then next_sel[#next_sel + 1] = t end
    end
    if #next_sel == 0 and #s.tags > 0 then return end
    local old = s._data.selected_tags or {}
    if same(old, next_sel) then return end
    local h = histories[s] or {}
    histories[s] = h
    if #old > 0 then h[#h + 1] = old; if #h > 20 then table.remove(h, 1) end end
    s._data.selected_tags = next_sel
    s:emit('property::selected_tags', next_sel)
    animation.start(s.name, 'reveal:'..s.name, 1, .15, 0)
    dirty(s)
    -- Membership spanning screens may change which screen owns the surface.
    for _, t in ipairs(s.tags) do for _, c in ipairs(t.clients) do dirty_client(c) end end
    repair_focus(s)
end
tag.setters.selected = function(t, want)
    if not valid_tag(t) or (not not want) == t.selected then return end
    local selection = {}
    for _, other in ipairs(t.screen.tags) do
        if (other == t and want) or (other ~= t and other.selected) then selection[#selection + 1] = other end
    end
    t.screen.selected_tags = selection
end
function tag.methods:view() if valid_tag(self) then self.screen.selected_tags = {self} end end
function tag.methods:toggle() self.selected = not self.selected end
function tag.methods:delete()
    local s = self.screen
    if not valid_tag(self) or #s.tags < 2 then return end
    local survivor = s.tags[1] == self and s.tags[2] or s.tags[1]
    local leaving = {unpack(self.clients)}
    for _, c in ipairs(leaving) do
        local tags = {}
        for _, t in ipairs(c.tags) do if t ~= self then tags[#tags + 1] = t end end
        c.tags = #tags > 0 and tags or {survivor}
    end
    local selection = {}
    for _, t in ipairs(s.selected_tags) do if t ~= self then selection[#selection + 1] = t end end
    remove(s.tags, self)
    s.selected_tags = #selection > 0 and selection or {survivor}
    dirty(s)
end
local new_tag = tag.new
function tag.new(props)
    assert(props and contains(screens, props.screen), 'tag.new needs a live screen')
    local defaults = {layout=kiln.layout.tile, master_width_factor=.5, master_count=1,
        column_count=1, carousel_width=.5}
    for k,v in pairs(props) do defaults[k]=v end
    local t = new_tag(defaults)
    t._data.clients = {}
    local s = t.screen
    s.tags[#s.tags + 1] = t
    if not s.selected_tag then s.selected_tag = t end
    dirty(s)
    return t
end
tag.on('property::name', function(t) dirty(t.screen) end)
for _, prop in ipairs({'layout','master_width_factor','master_count','column_count','gap','carousel_width'}) do
    tag.on('property::' .. prop, function(t) if t.selected then dirty(t.screen) end end)
end
tag.on('property::master_width_factor', function(t)
    if t.selected then animation.start(t.screen.name, 'mwf:'..tostring(t), t.master_width_factor) end
end)
tag.history = {}
function tag.history.restore(s)
    s = s or screen.focused or screens[1]
    local h = histories[s]
    while h and #h > 0 do
        local selection = {}
        for _, t in ipairs(table.remove(h)) do if valid_tag(t) then selection[#selection + 1] = t end end
        if #selection > 0 then s.selected_tags = selection; return end
    end
end
for _, prop in ipairs({'title','app_id','icon','urgent','floating','float','ontop','titlebar','band'}) do
    client.on('property::' .. prop, dirty_client)
end
client.on('property::sticky', function(c) dirty_client(c); repair_focus(c.screen) end)
for prop, verb in pairs({fullscreen='set_fullscreen_hint', maximized='set_maximized_hint'}) do
    client.on('property::' .. prop, function(c, on)
        core.client[verb](c.handle, not not on)
        dirty_client(c)
    end)
end
client.on('property::minimized', function(c, on)
    core.client.set_suspended(c.handle, not not on)
    core.client.set_minimized_hint(c.handle, not not on)
    repair_focus(c.screen)
    dirty_client(c)
end)
for _, prop in ipairs({'fullscreen','maximized','minimized'}) do
    client.methods['toggle_' .. prop] = function(c) c[prop] = not c[prop] end
end
for request, prop in pairs({fullscreen='fullscreen', maximize='maximized', minimize='minimized'}) do
    kiln.defaults[request] = function(c, on) c[prop] = on end
    client.on('request::' .. request, kiln.defaults[request])
end

-- The config opens the workarea; this policy only partitions its eligible union.
function kiln.declare_clients(s, slots)
    local t = s.selected_tag
    if not t then return end
    local tiled, floats, maxed, full, ors = {}, {}, {}, {}, {}
    for _, c in ipairs(visible(s)) do
        local group = c.override_redirect and ors or c.fullscreen and full or c.maximized and maxed or c.floating and floats or tiled
        group[#group+1] = c
    end
    local gap = t.gap or kiln.theme.gap
    local wa = s.workarea or {x=0,y=0,width=s.width,height=s.height}
    slots = slots or {n=0}
    local state = require('kiln.state')
    state.client_slots = slots
    local inset = (1-animation.get('reveal:'..s.name, 1))*24
    kiln.ui.box({w='grow',h='grow',pad=inset}, function()
        t.layout(tiled, {x=wa.x+gap+inset,y=wa.y+gap+inset,
            width=math.max(0,wa.width-2*(gap+inset)),height=math.max(0,wa.height-2*(gap+inset))}, t)
    end)
    state.client_slots = nil
    kiln.layout.declare_floats(floats, slots)
    kiln.layout.declare_maximized(maxed, s, slots)
    kiln.layout.declare_fullscreen(full, s, slots)
    kiln.layout.declare_or(ors, s, slots)
end
local function seed_output(o)
    local s = by_name(o.name)
    local fresh = s == nil
    if not s then
        s = screen.new {name=o.name, tags={}, selected_tags={}, bars={}}
        screens[#screens + 1] = s
        screen.focused = screen.focused or s
    end
    if core.output._geometry then
        local w,h=core.output._geometry(o.name)
        if w and h then o.width,o.height=w,h end
    end
    for _, key in ipairs({'width','height','x','y','refresh','enabled'}) do
        if fresh then s._data[key] = o[key] else s[key] = o[key] end
    end
    return s
end
local function ensure_tagged(c)
    if c.tag then return end
    local s = screen.focused or screens[1]
    if s and s.selected_tag then c.tags = {s.selected_tag} end
end
local function x11_metadata(c,ev)
    c.role,c.icon=ev.role,ev.icon
    local types
    if ev.window_type then
        types={}
        for name in ev.window_type:gmatch("[^,]+") do types[#types+1]=name end
    end
    c.window_type=types
end
local function dispatch(ev)
    if ev.class=="session" then
        if ev.name=='key' then lockscreen.on_key(ev);return
        elseif ev.name=='authenticated' then lockscreen.on_authenticated(ev)
        elseif ev.name=='lock' then grab.reset();ui_input.reset();lockscreen.on_lock(ev.kind)
        elseif ev.name=='unlock' then
            lockscreen.on_unlock()
            local c=client.focus;client.focus=nil
            if c and c.handle then c:focus() end
        end
        bus:emit('session::'..ev.name,ev);return
    end
    if ev.class=="idle" then bus:emit("idle::"..ev.name,ev.on);return end
    if ev.class=="notify" then return notif.on_event(ev) end
    if ev.class=="tray" then return kiln.systray.on_event(ev) end
    if ev.class=='drag' then drag.emit(ev.name);bus:emit('drag::'..ev.name,ev);return end
    if ev.class=='spawn' then kiln.spawn.on_event(ev); bus:emit('spawn::'..ev.name,ev); return
    elseif ev.class=='frame' and ev.name=='tick' then animation.on_tick(ev); bus:emit('frame::tick',ev); return end
    if ev.class == 'layer' then layers.dispatch(ev);return end
    if ev.class == 'client' then
        local c = object.lookup(ev.handle)
        if ev.name == 'map' then
            if c and c.mapped then return end
            local fresh = c == nil
            if not c then
                c = client.new {handle=ev.handle, tags={}, mapped=true, x=ev.x, y=ev.y,
                    width=ev.width, height=ev.height, title=ev.title, app_id=ev.app_id, transient_for=ev.transient_for}
                object.attach(ev.handle, c)
                live[#live + 1] = c
            else
                c.x, c.y, c.width, c.height = ev.x, ev.y, ev.width, ev.height
                c.app_id, c.title, c.mapped = ev.app_id, ev.title, true
            end
            c.class,c.instance,c.pid=ev.wm_class,ev.wm_instance,ev.pid
            c.transient_for=ev.transient_for
            x11_metadata(c,ev)
            c.override_redirect,c.wants_focus=ev.override_redirect,ev.wants_focus
            core.client.set_suspended(c.handle, false)
            mapping = mapping + 1
            local ok, err = pcall(function()
                ensure_tagged(c)
                if fresh and not c.override_redirect then policy.rules(c) end
            end)
            mapping = mapping - 1
            if not ok then pcall(Bus.on_error, 'map rules', err) end
            c:emit('map')
            if ev.fullscreen then c:emit('request::fullscreen', true) end
            if ev.maximized then c:emit('request::maximize', true) end
            if ev.minimized then c:emit('request::minimize', true) end
            if (c.override_redirect and c.wants_focus) or (not c.override_redirect and not c.no_focus) then c:focus() end
            dirty_client(c)
        elseif c then
            if ev.name == 'unmap' then
                c.mapped = false
                remove(history, c)
                c:emit('unmap')
                repair_focus(c.screen)
                dirty_client(c)
            elseif ev.name == 'destroy' then
                c.mapped = false
                remove(history, c)
                c:emit('destroy')
                repair_focus(c.screen)
                object.detach(ev.handle)
                remove(live, c)
                c.tags = {}
                c._data.dead = true
            elseif ev.name == 'request::close' then c:emit(ev.name)
            elseif ev.name == 'request::activate' then c:emit(ev.name, ev)
            elseif ev.name == 'request::decoration_mode' then c:emit(ev.name,ev.mode)
            elseif ev.name == 'request::urgent' then
                c.urgent=ev.urgent;c:emit(ev.name,ev.urgent)
            elseif ev.name == 'metadata' then
                c.app_id,c.title=ev.app_id,ev.title
                c.class,c.instance,c.pid=ev.wm_class,ev.wm_instance,ev.pid
                c.transient_for=ev.transient_for
                x11_metadata(c,ev)
                dirty_client(c)
            elseif ev.name == 'request::configure' then
                if c.override_redirect then
                    c.x,c.y,c.width,c.height=ev.x,ev.y,ev.width,ev.height
                    dirty_client(c)
                end
                c:emit(ev.name,{x=ev.x,y=ev.y,width=ev.width,height=ev.height})
            elseif ev.name == 'commit_size' then c.width, c.height = ev.width, ev.height
            elseif ev.name == 'request::fullscreen' or ev.name == 'request::maximize' or ev.name == 'request::minimize' then
                c:emit(ev.name, ev.on)
            end
        end
    elseif ev.class == 'output' then
        local s = by_name(ev.output)
        if ev.name == 'add' or ev.name == 'change' then
            for _, o in ipairs(core.output.list()) do if o.name == ev.output then s = seed_output(o) end end
            if not s then return end
            if not announced[s] then
                announced[s] = true
                s:emit('added')
                for _, c in ipairs(live) do ensure_tagged(c) end
            elseif ev.name == 'change' then s:emit('changed');layers.changed(s) end
            dirty(s)
        elseif ev.name == 'remove' and s then
            require('kiln.desktop_services').remove(s)
            animation.remove(ev.output)
            ui_input.remove(ev.output)
            require('kiln.state').remove(ev.output)
            remove(screens, s)
            local survivor = screens[1]
            if screen.focused == s then screen.focused = survivor end
            local dst = survivor and survivor.selected_tag
            local orphans = {}
            for _, t in ipairs(s.tags) do
                for _, c in ipairs(t.clients) do if not contains(orphans, c) then orphans[#orphans + 1] = c end end
            end
            for _, c in ipairs(orphans) do c.tags = dst and {dst} or {} end
            histories[s], announced[s] = nil, nil
            repair_focus(survivor)
            s:emit('removed')
            s._data.dead=true
            layers.refresh()
        end
    elseif ev.class == 'input' then
        if ev.name == 'focus' then
            -- Read the current target, including a first map awaiting its
            -- declaration. An older fact must not undo a newer focus verb.
            local c = object.lookup(core.client._focus_target())
            if layers.is(c) then return end
            if layers.target() then core.client.focus(layers.target().handle);return end
            if c and not owner(c) then
                if client.focus and owner(client.focus) then core.client.focus(client.focus.handle)
                else repair_focus(c.screen) end
                return
            end
            if c and owner(c) then screen.focused = owner(c) end
            if client.focus ~= c then
                if client.focus then core.client.set_activated(client.focus.handle, false); dirty_client(client.focus) end
                client.focus = c
                if c then core.client.set_activated(c.handle, true); c:emit('focus') end
            end
        elseif ev.name == 'key' then
            if not grab.route_key(ev) then policy.key(ev) end
        elseif ev.name == 'motion' or ev.name == 'button' or ev.name == 'axis' then
            state.pointer={x=ev.x,y=ev.y,screen=ev.screen}
            if ev.name=='motion' then screen.focused=by_name(ev.screen) or screen.focused end
            if not grab.route_pointer(ev) then
                local previous=state.current_press
                state.current_press=ev.name=='button' and ev.pressed and ev or nil
                local ok,err=pcall(function()
                    if not ui_input(ev) and ev.name=='button' then policy.button(ev) end
                end)
                state.current_press=previous
                if not ok then pcall(Bus.on_error,'input::'..ev.name,err) end
            end
        elseif ev.name == 'pointer_enter' then
            local c = object.lookup(ev.handle)
            if c and not grab.pointer_active() then c:emit('mouse::enter') end
        end
        bus:emit('input::' .. ev.name, ev)
    end
end
core.set_event_handler(dispatch)
-- Enumeration is available immediately; announcements are queued so config
-- subscribers run before the first added signal, including a late require.
local outputs = core.output.list()
for i = #outputs, 1, -1 do seed_output(outputs[i]) end
core._discover()
core.replay()
local services=require("kiln.desktop_services")
kiln.prompt=require("kiln.prompt")
kiln.menu=require("kiln.menu")
kiln.tooltip=require("kiln.tooltip")
kiln.hotkeys=require("kiln.hotkeys")
kiln.launcher=require("kiln.launcher")
local popup=require("kiln.popup")
kiln.ui.menu=kiln.menu.show
kiln.ui.popup=popup.new
kiln.ui.tooltip=kiln.tooltip.attach
kiln.ui.hotkeys=kiln.hotkeys.show

local desktop=require("kiln.desktop")(kiln)
core.set_frame_handler(desktop)
-- Assigning a request default replaces its registered callback; off still takes
-- the public function value, as it does for ordinary subscriptions.
local request_defaults, boot_defaults = {}, {}
for _, name in ipairs{'activate','close','fullscreen','maximize','minimize'} do
    request_defaults[name], boot_defaults[name] = kiln.defaults[name], kiln.defaults[name]
    kiln.defaults[name] = nil
end
setmetatable(kiln.defaults, {
    __index = request_defaults,
    __newindex = function(t, name, fn)
        if not boot_defaults[name] then rawset(t,name,fn);return end
        assert(type(fn)=='function','request default must be a function')
        client.off('request::'..name, request_defaults[name])
        request_defaults[name] = fn
        client.on('request::'..name, fn)
    end,
})
-- This boundary is reached only after the requesting callback has returned.
local function reload()
    Bus.on_error = report_error
    -- Stopped callbacks may arm work or fail. Retire everything they created
    -- after stopping claims and before accepting replacement registrations.
    lockscreen.reset()
    services.reset()
    Bus.on_error = report_error
    kiln.widgets.reset()
    kiln.ui._reset()
    hook.reset()
    kiln.spawn.reset()
    drag.reset()
    core._timers_reset()
    animation.reset()
    core._clocks_reset()
    kiln.key.clear()
    kiln.button.clear()
    kiln.rule.clear()
    for name, fn in pairs(boot_defaults) do kiln.defaults[name] = fn end
    object.reset()
    notif.reload()
    kiln.defaults.notify_display=notif.display
    bus:reset()
    ui_input.reset()
    core._frame_reset()
    state.reset()
    core.set_frame_handler(desktop)
    core.set_event_handler(dispatch)
    clear_focus()
    history, histories, live, mapping = {}, {}, {}, 0
    object.retire(layers.is)
    layers.reset()
    for _, s in ipairs(screens) do
        for _, t in ipairs(s.tags) do
            t._data.clients, t._data.dead = {}, true
            t._bus:reset()
        end
        local facts = {tags={}, selected_tags={}, bars={}}
        for _, k in ipairs{'name','width','height','x','y','scale','refresh','enabled'} do facts[k]=s._data[k] end
        s._data = facts
        s._bus:reset()
    end
    local ok, err = xpcall(function() dofile(core._config_path()) end, debug.traceback)
    if not ok then report_error('reload', err) end
    for _, s in ipairs(screens) do announced[s]=true; s:emit('added') end
    layers.refresh()
    core.replay()
    core.dirty()
end
function kiln.reload() return core._reload(reload) end
-- Mark after every library default, before require returns to the config.
popup.mark()
hook.mark()
object.mark()
bus:mark()
for _, s in ipairs(screens) do s._bus:mark() end
require("kiln.ipc").install(kiln)
function kiln.inspector(s)
    s = s or screen.focused or screen.all()[1]
    if not s then return false end
    return core.inspector(s.name, not core.inspector(s.name))
end

return kiln
