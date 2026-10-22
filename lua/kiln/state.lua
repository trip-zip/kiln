-- Shared declaration state; object membership remains in the policy layer.
local state = {
    theme = {
        notification_width=320, notification_offset=12, notification_gap=8, notification_radius=0,
        notification_timeout={low=5,normal=5,critical=0},
        bg="#181820", bg2="#101014", fg="#dcdce6", accent="#5078be", muted="#3c3c4b",
        font_size=14, font="Sans", gap=8, border_width=2, client_radius=4, titlebar_height=22,
        titlebar="#22222c", titlebar_focus="#2c2c3a", urgent="#e0a050",
        min_size=60, resize_handle=6, bar_height=32, close="#c05068",
        menu_width=200, menu_height=24, tooltip_gap=4, prompt_width="50%", prompt_offset=80,
        cursors={move="grabbing",resize={n="n-resize",s="s-resize",e="e-resize",w="w-resize",
            ne="ne-resize",nw="nw-resize",se="se-resize",sw="sw-resize"}},
    },
	screen_presses = {},
	offsets = {},
	settles = {},
	workareas = {},
    client_boxes = {},
}
local function begin(sn)
	state.each_candidate = {}
	state.screen_name = sn
	state.client_slots = nil
	state.presses = {}
	state.press_n = 0
	state.scrolls = {}
	state.fits = {}
end
local function same(a, b, size_only)
	if not a or not b then
		return a == b
	end
	return a.width == b.width and a.height == b.height and (size_only or (a.x == b.x and a.y == b.y))
end
local function publish(sn)
    require("kiln.ui")._publish_each(sn)
    state.client_boxes[sn] = {}
    if client then
        for _, c in ipairs(client.all()) do
            state.client_boxes[sn][c.handle] = core.box({'client', c.handle})
        end
    end
    state.screen_presses[sn] = state.presses
	local offsets = state.offsets[sn] or {}
	state.offsets[sn] = offsets
	local wa = core.box("workarea:" .. sn)
	local settle = not same(state.workareas[sn], wa)
	state.workareas[sn] = wa
	for key, v in pairs(state.scrolls) do
		local vp, ct = core.box(v.id), core.box(v.content)
		local off = v.offset
		if vp and ct then
			off = math.max(-math.max(0, ct.height - vp.height), math.min(0, off))
		end
		offsets[key] = off
		settle = settle or off ~= v.offset
	end
	for _, f in ipairs(state.fits) do
		local before = f.before or {}
		local b, par, wa = core.box(f.id), f.parent and core.box(f.parent), core.box("workarea:" .. sn)
		if par and wa and (not same(before.b, b, true) or not same(before.par, par) or not same(before.wa, wa)) then
			settle = true
		end
	end
	local n = settle and (state.settles[sn] or 0) + 1 or 0
	state.settles[sn] = n
	if settle and n <= 2 then
		core.dirty(sn)
	end
end
core._ui_hooks(begin, publish)
function state.remove(sn)
    require("kiln.ui")._remove(sn)
	state.screen_presses[sn] = nil
	state.offsets[sn] = nil
	state.settles[sn] = nil
	state.workareas[sn] = nil
    state.client_boxes[sn] = nil
end
function state.reset()
    state.notify_display_failed=nil
    state.each_candidate = {}
    state.screen_presses, state.offsets, state.settles, state.workareas, state.client_boxes = {}, {}, {}, {}, {}
    state.screen_name, state.current_press, state.client_slots, state.pointer = nil, nil, nil, nil
    state.presses, state.scrolls, state.fits, state.press_n = {}, {}, {}, 0
    core._ui_hooks(begin, publish)
end
return state
