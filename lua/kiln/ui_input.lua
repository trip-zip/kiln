local state = require("kiln.state")
local Bus = require("kiln.bus")
local hovered
local function fire(fn, name, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		pcall(Bus.on_error, name, err)
	end
end
local function find(ev, kind)
	if ev.client or ev.surface or not ev.screen then
		return
	end
	local registry = state.screen_presses[ev.screen]
	if not registry or next(registry) == nil then
		return
	end
	for _, hit in ipairs(core.hits(ev.screen, ev.x, ev.y)) do
		local fn = registry[kind .. ":" .. hit.name .. "#" .. hit.index]
		if fn then
			hit.screen = ev.screen
			return fn, hit
		end
	end
end
local function dispatch(ev)
	if ev.name == "motion" then
		local fn, hit = find(ev, "on_hover")
		local key = hit and (ev.screen .. ":" .. hit.name .. "#" .. hit.index)
		if hovered and hovered.key ~= key then
			fire(hovered.fn, "on_hover", false, hovered.hit)
			hovered = nil
		end
		if fn then
			hovered = { key = key, fn = fn, hit = hit }
			fire(fn, "on_hover", true, hit)
		end
	elseif ev.name == "button" or ev.name == "axis" then
		local kind = ev.name == "axis" and "on_scroll" or (ev.pressed and "on_press" or "on_release")
		local fn = find(ev, kind)
		if fn then
			fire(fn, kind, ev)
			return true
		end
	end
	return false
end
return setmetatable({reset=function() hovered=nil end,
    remove=function(sn)
        if hovered and hovered.hit.screen==sn then hovered=nil end
    end}, {__call=function(_, ev) return dispatch(ev) end})
