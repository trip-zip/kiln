-- The stock frame is a replaceable Lua declaration over Clay flow containers.
local ui = require("kiln.ui")
local state = require("kiln.state")
local layout = require("kiln.layout")
local hook = require("kiln.hook")
local function declare_bar(bar, i)
	local cfg = bar.cfg
	local edge = cfg.edge or "top"
	local horiz = edge == "top" or edge == "bottom"
	local dir = cfg.dir or (horiz and "row" or "column")
	local col = dir == "column" or dir == "ttb"
	local d = {}
	for k, v in pairs(cfg) do
		d[k] = v
	end
	d.edge, d.band, d.dir = nil, nil, nil
	d.id = { "bar", i }
	if horiz then
		d.w = "grow"
		d.h = cfg.h or state.theme.bar_height
	else
		d.w = cfg.w or state.theme.bar_height
		d.h = "grow"
	end
	d.pad = cfg.pad or (horiz and { x = 8 } or { y = 8 })
	d.gap = cfg.gap or 6
	d.align = cfg.align
		or (col and { x = "center" } or { y = "center" })
	d.color = cfg.color or state.theme.bg
	local open = col and ui.column or ui.row
	open(d, bar.fn)
end

return function(kiln)
    return function(name, width, height)
        local s
        for _, candidate in ipairs(screen.all()) do
            if candidate.name==name then s=candidate; break end
        end
        if not s then return end
        s.width, s.height = width, height
        local chrome = {}
        local loose,slots={}, {n=0}
        local slayers=require("kiln.layers").for_screen(s)
        for i, bar in ipairs(s.bars) do
            chrome[#chrome+1] = {edge=bar.cfg.edge or "top", band=bar.cfg.band or "above",
                declare=function() declare_bar(bar, i) end}
        end
        ui.column({id="root",w="grow",h="grow"}, function()
            ui.box({id="root-fill:"..name, w="grow",h="grow",color=state.theme.bg2,
                float={to="root",band="background",passthrough=true}})
            local gap = s.selected_tag and s.selected_tag.gap or state.theme.gap
            layout.fold_struts(layout.strut_zones(chrome,slayers,loose,slots), 1, function()
                ui.row({id="workarea:"..name,w="grow",h="grow",pad=gap,gap=gap}, function()
                    kiln.declare_clients(s,slots)
                end)
            end)
            layout.declare_layers(loose,slots,"workarea:"..name)
            kiln.prompt.declare(s)
            kiln.menu.declare(s)
            local display=kiln.defaults.notify_display
            if display and display~=state.notify_display_failed then
                local ok,err=pcall(display,s)
                if not ok then
                    state.notify_display_failed=display
                    pcall(require("kiln.bus").on_error,"notification display",err)
                    error(err)
                end
            end
            hook.run(s)
            kiln.tooltip.declare(s)
        end)
    end
end
