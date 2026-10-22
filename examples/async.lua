-- Run with KILN_RC=examples/async.lua from the source checkout.
dofile('kilnrc.lua')
local kiln = require('kiln')
local ui = kiln.ui
local answer = kiln.poll { {'date', '+%H:%M:%S'}, every=1 }
core.set_frame_handler(function(name, width, height)
    local s
    for _, candidate in ipairs(screen.all()) do
        if candidate.name==name then s=candidate; break end
    end
    if not s then return end
    s.width,s.height=width,height
    ui.column({w='grow',h='grow',color='#181c24'},function()
        ui.box({w='grow',h=36,pad={x=12},color='#378397'},function()
            ui.text('Polled time: '..(answer.value or 'waiting')..'   Super+h/l: animate split')
        end)
        local gap=s.selected_tag and s.selected_tag.gap or kiln.theme.gap
        ui.row({id='workarea:'..name,w='grow',h='grow',pad=gap},function()
            kiln.declare_clients(s)
        end)
    end)
end)
