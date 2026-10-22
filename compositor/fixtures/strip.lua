local kiln = require('kiln')
kiln.modkey = 'super'
screen.on('added', function(s)
    if #s.tags == 0 then
        tag.new {name = '1', screen = s}
        tag.new {name = '2', screen = s}
    end
end)
local ui = kiln.ui
core.set_frame_handler(function(name, width, height)
    local s
    for _, candidate in ipairs(screen.all()) do if candidate.name == name then s = candidate; break end end
    if not s then return end
    s.width, s.height = width, height
    ui.box({id='background', w='grow',h='grow',color='#181c24',
        float={to='root',band='background',passthrough=true}})
    ui.column({id='screen',w='grow',h='grow'},function()
        ui.box({w='grow',h=36},function()
            ui.row({id='strip',w='grow',h=36,pad={left=12},align={y='center'},
                color='#378397',float={to='parent',band='above'}},function()
                ui.box({id='label',pad={x=8,y=3},color='#1f4f5b',radius=6,
                    border={width=1,color='#7cbfcb'}},function()
                    ui.text('Kiln', {font='Sans Bold',size=16,color='#f5f9fa'})
                end)
                ui.text('  '..(s.selected_tag and s.selected_tag.name or '')..'  '..
                    (s.selected_tag and kiln.layout.name(s.selected_tag.layout) or '?'))
            end)
        end)
        local gap = s.selected_tag and s.selected_tag.gap or kiln.theme.gap
        ui.row({id='workarea:'..name,w='grow',h='grow',pad=gap,gap=gap},function()
            kiln.declare_clients(s)
        end)
    end)
end)

kiln.key {mods={'mod'}, key='Return', desc='terminal', press=function() kiln.spawn('foot') end}
kiln.key {mods={'mod','ctrl'}, key='r', desc='reload', press=kiln.reload}
kiln.key {mods={'mod','shift'}, key='q', desc='quit', press=kiln.quit}
kiln.key {mods={'alt'}, key='Escape', desc='quit', press=kiln.quit}
kiln.key {mods={'mod'}, key='q', desc='close', press=kiln.focused(function(c) c:close() end)}
kiln.key {mods={'mod'}, key='Tab', desc='previous client', press=function()
    local c = client.history.previous()
    if c then
        if c.tag then c.tag:view() end
        c:focus()
    end
end}
kiln.key {mods={'mod'}, key='1-2', desc='view tag', press=function(i)
    local s = screen.focused
    if s and s.tags[i] then s.tags[i]:view() end
end}
kiln.key {mods={'mod','shift'}, key='1-2', desc='move to tag', press=kiln.focused(function(c, i)
    if c.screen and c.screen.tags[i] then c.tag = c.screen.tags[i] end
end)}

kiln.key {mods={'mod'}, key='space', desc='next layout', press=function()
    local t = screen.focused and screen.focused.selected_tag
    if t then t.layout=kiln.layout.next(t.layout) end
end}
kiln.key {mods={'mod','shift'}, key='space', desc='toggle floating', press=kiln.focused(function(c) c.floating=not c.floating end)}
kiln.key {mods={'mod'}, key='f', desc='fullscreen', press=kiln.focused(function(c) c:toggle_fullscreen() end)}
kiln.key {mods={'mod'}, key='m', desc='maximize', press=kiln.focused(function(c) c:toggle_maximized() end)}
kiln.key {mods={'mod'}, key='n', desc='minimize', press=kiln.focused(function(c) c.minimized=true end)}
kiln.key {mods={'mod','shift'}, key='n', desc='restore', press=function()
    for _,c in ipairs(client.history()) do
        if c.mapped and c.minimized and c.screen==screen.focused then
            c.minimized=false
            if c.tag then c.tag:view() end
            c:focus()
            return
        end
    end
end}

kiln.button {mods={'mod'}, button=1, press=function(c) c:grab_move() end}
kiln.button {mods={'mod'}, button=3, press=function(c) c:grab_resize_nearest() end}

kiln.key {mods={'mod'}, key='h', desc='shrink master', press=function()
    local t=screen.focused and screen.focused.selected_tag
    if t then t.master_width_factor=math.max(.05,t.master_width_factor-.05) end
end}
kiln.key {mods={'mod'}, key='l', desc='grow master', press=function()
    local t=screen.focused and screen.focused.selected_tag
    if t then t.master_width_factor=math.min(.95,t.master_width_factor+.05) end
end}
