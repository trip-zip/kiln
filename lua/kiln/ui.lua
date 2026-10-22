local state = require("kiln.state")

local ui = {}

local function to_color(v)
	if v == nil then
		return nil
	end
	if type(v) == "table" then
		return v
	end
	local r, g, b, a = v:match("^#(%x%x)(%x%x)(%x%x)(%x?%x?)$")
	if r == nil then
		error("bad color: " .. tostring(v), 3)
	end
	return {
		r = tonumber(r, 16),
		g = tonumber(g, 16),
		b = tonumber(b, 16),
		a = a ~= "" and tonumber(a, 16) or 255,
	}
end
ui.color = to_color

local function to_axis(v)
	if v == nil or type(v) == "number" then
		return v
	end
	if type(v) == "table" then
		return {
			type = v[1] or "fit",
			min = v.min,
			max = v.max,
			percent = v.percent,
			px = v.px,
		}
	end
	local pct = v:match("^(%d+%.?%d*)%%$")
	if pct ~= nil then
		return { type = "percent", percent = tonumber(pct) / 100 }
	end
	return { type = v }
end

local DIR = { row = "ltr", ltr = "ltr", column = "ttb", ttb = "ttb" }

local function to_padding(v)
	if v == nil then
		return nil
	end
	if type(v) == "number" then
		return { left = v, right = v, top = v, bottom = v }
	end
	return {
		left = v.left or v.x or 0,
		right = v.right or v.x or 0,
		top = v.top or v.y or 0,
		bottom = v.bottom or v.y or 0,
	}
end

local function to_alignment(v)
	if v == nil then
		return nil
	end
	if v == "center" then
		return { x = "center", y = "center" }
	end
	return { x = v.x, y = v.y }
end

local anchor_names = {
	center = "center_center",
	top = "center_top",
	bottom = "center_bottom",
	left = "left_center",
	right = "right_center",
}

local band_base = {
	background = -1000,
	below = 1000,
	normal = 2000,
	above = 3000,
	fullscreen = 4000,
	overlay = 5000,
}
ui.bands = band_base

local function name_of(a, dflt)
	return anchor_names[a] or a or dflt
end

local frac = { left = 0, top = 0, center = 0.5, right = 1, bottom = 1 }
local mirror = { left = "right", right = "left", center = "center", top = "bottom", bottom = "top" }

local function span(pn, ps, p, e, size, off)
	return pn + frac[p] * ps - frac[e] * size + off
end

local function over(v, size, lo, hi)
	return math.max(lo - v, 0) + math.max(v + size - hi, 0)
end

local function fit_axis(p, e, off, pn, ps, size, lo, hi, may_mirror)
	local v = span(pn, ps, p, e, size, off)
	if may_mirror then
		local mp, me, mo = mirror[p], mirror[e], -off
		local mv = span(pn, ps, mp, me, size, mo)
		if over(mv, size, lo, hi) < over(v, size, lo, hi) then
			p, e, off, v = mp, me, mo, mv
		end
	end
	return p, e, off + math.max(lo - v, math.min(0, hi - size - v))
end

-- Correct from unadjusted attachment inputs, then settle against the new solve.
local function fit(f, id)
	assert(id ~= nil, "fit needs a stable id")
	state.fits[#state.fits + 1] = { id = id, parent = f.attachTo == "root" and "root" or f.parentId }
	local b = core.box(id)
	if b == nil then
		return
	end
	local par = (f.attachTo == "root" or f.parentId ~= nil) and core.box(f.attachTo == "root" and "root" or f.parentId)
		or nil
	local wa = core.box("workarea:" .. (state.screen_name or ""))
	state.fits[#state.fits].before = { b = b, par = par, wa = wa }
	if par == nil or wa == nil then
		return
	end
	local px, py = f.attachPoints.parent:match("^(%a+)_(%a+)$")
	local ex, ey = f.attachPoints.element:match("^(%a+)_(%a+)$")
	local off = f.offset or {}
	local m = f.attachTo == "element"
	local ox, oy
	px, ex, ox = fit_axis(px, ex, off.x or 0, par.x, par.width, b.width, wa.x, wa.x + wa.width, m)
	py, ey, oy = fit_axis(py, ey, off.y or 0, par.y, par.height, b.height, wa.y, wa.y + wa.height, m)
	f.attachPoints.parent = px .. "_" .. py
	f.attachPoints.element = ex .. "_" .. ey
	f.offset = { x = ox, y = oy }
end

local function to_floating(v, id)
	if v == nil then
		return nil
	end
	local a = v.anchor
	local parent, element
	if type(a) == "table" then
		parent, element = name_of(a.parent, "left_top"), name_of(a.element, "left_top")
	else
		parent = name_of(a, "left_top")
		element = parent
	end
	local z = v.z
	if v.band ~= nil then
		z = (band_base[v.band] or band_base.normal) + (z or 0)
	end
	local expand = v.expand
	if type(expand) == "number" then
		expand = { width = expand, height = expand }
	elseif expand ~= nil then
		expand = { width = expand.w or 0, height = expand.h or 0 }
	end
	local f = {
		attachTo = v.to or "parent",
		offset = v.offset,
		expand = expand,
		zIndex = z,
		parentId = v.parent,
		attachPoints = { parent = parent, element = element },
		pointerCaptureMode = v.passthrough and "passthrough" or "capture",
		clipTo = v.clip and "attached_parent" or nil,
	}
	if v.fit then
		fit(f, id)
	end
	return f
end

local handler_names = { "on_press", "on_release", "on_hover", "on_scroll" }

-- Registration belongs to the current candidate, including auto-assigned IDs.
local function to_declaration(cfg, direction)
	core._ui_guard()
	local id = cfg.id
	if cfg.on_press or cfg.on_release or cfg.on_hover or cfg.on_scroll then
		if id == nil then
			state.press_n = state.press_n + 1
			id = { "press", state.press_n }
		end
		local key
		if type(id) == "table" then
			key = id[1] .. "#" .. id[2]
		else
			key = id .. "#0"
		end
		for _, h in ipairs(handler_names) do
			if cfg[h] ~= nil then
				state.presses[h .. ":" .. key] = cfg[h]
			end
		end
	end

	local border = nil
	if cfg.border ~= nil then
		local w = cfg.border.width or 1
		if type(w) == "number" then
			w = { left = w, right = w, top = w, bottom = w }
		else
			w = { left = w.left, right = w.right, top = w.top, bottom = w.bottom, betweenChildren = w.between }
		end
		border = { width = w, color = to_color(cfg.border.color) }
	end

	return {
		id = id,
		layout = {
			sizing = { width = to_axis(cfg.w), height = to_axis(cfg.h) },
			padding = cfg.pad and to_padding(cfg.pad) or nil,
			childGap = cfg.gap,
			childAlignment = cfg.align and to_alignment(cfg.align) or nil,
			layoutDirection = cfg.dir and (DIR[cfg.dir] or cfg.dir) or direction,
		},
		backgroundColor = cfg.color and to_color(cfg.color) or nil,
		cornerRadius = cfg.radius ~= nil and {
			topLeft = cfg.radius,
			topRight = cfg.radius,
			bottomLeft = cfg.radius,
			bottomRight = cfg.radius,
		} or nil,
		border = border,
		floating = cfg.float and to_floating(cfg.float, id) or nil,
		aspectRatio = cfg.aspect,
		clip = cfg.clip,
		image = cfg.image,
	}
end

function ui.box(cfg, children)
	core.open(to_declaration(cfg or {}, nil))
	if children ~= nil then
		children()
	end
	core.close()
end

function ui.row(cfg, children)
	core.open(to_declaration(cfg or {}, "ltr"))
	if children ~= nil then
		children()
	end
	core.close()
end

function ui.column(cfg, children)
	core.open(to_declaration(cfg or {}, "ttb"))
	if children ~= nil then
		children()
	end
	core.close()
end

local font_ids = {}
local function to_font(desc)
	local id = font_ids[desc]
	if id == nil then
		id = core.font(desc)
		font_ids[desc] = id
	end
	return id
end

function ui.text(str, cfg)
	cfg = cfg or {}
	core.text(str, {
		textColor = to_color(cfg.color or state.theme.fg),
		fontSize = cfg.size or state.theme.font_size,
		fontId = to_font(cfg.font or state.theme.font),
		wrapMode = cfg.wrap,
		textAlignment = cfg.align,
		lineHeight = cfg.line_height,
		ellipsize = cfg.ellipsize,
	})
end

function ui.spacer()
	ui.box({ w = "grow" })
end

function ui.image(path, cfg)
	cfg = cfg or {}
	ui.box({
		id = cfg.id,
		image = { path = path },
		color = cfg.recolor,
		w = cfg.w,
		h = cfg.h,
		aspect = cfg.aspect,
		radius = cfg.radius,
		on_press = cfg.on_press,
	})
end

function ui.surface(c, cfg)
	if cfg ~= nil then
		core.surface(c.handle, to_declaration(cfg, nil))
	else
		core.surface(c.handle)
	end
end

-- Wheel input owns desired offsets; successful solves publish clamped offsets.
function ui.scroll(cfg, children)
	core._ui_guard()
	local id = cfg.id
	if id == nil then
		error("ui.scroll needs a stable id", 2)
	end
	local key, content_id
	if type(id) == "table" then
		key = id[1] .. "#" .. id[2]
		content_id = { id[1] .. ":content", id[2] }
	else
		key = id .. "#0"
		content_id = id .. ":content"
	end

	local offsets = state.offsets[state.screen_name] or {}
	local off = offsets[key] or 0
	local vp = core.box(id)
	local ct = core.box(content_id)
	if vp ~= nil and ct ~= nil then
		local max = ct.height - vp.height
		if max < 0 then
			max = 0
		end
		off = math.max(-max, math.min(0, off))
	end
	state.scrolls[key] = { id = id, content = content_id, offset = off }

	local step = cfg.step or 40
	local sn = state.screen_name
	state.offsets[sn] = offsets
	ui.box({
		id = id,
		w = cfg.w,
		h = cfg.h,
		color = cfg.color,
		pad = cfg.pad,
		clip = { vertical = true, childOffset = { x = 0, y = off } },
		on_scroll = function(ev)
			offsets[key] = (offsets[key] or 0) - (ev.dy or 0) * step
			core.dirty(sn)
		end,
	}, function()
		ui.column({ id = content_id, w = "grow", h = "fit" }, children)
	end)
end

-- State belongs to a key function and an output, never an array position.
local each_state = setmetatable({}, {__mode="k"})
function ui.each(items, key, declare)
    core._ui_guard()
    local by_screen = each_state[key] or {}
    each_state[key] = by_screen
    local name = state.screen_name
    local store, kept = by_screen[name] or {}, {}
    for _, item in ipairs(items) do
        local id = key(item)
        local st = store[id] or {}
        kept[id] = st
        declare(item, id, st)
    end
    state.each_candidate[key] = kept
    return kept
end

local watched, timers = {}, {}
local widget_generation = 0
function ui.widget(spec)
    local fn = spec.fn or spec[1]
    assert(type(fn)=="function", "ui.widget needs a declaration function")
    for _, name in ipairs(spec.watch or {}) do
        local class_name, signal = name:match("^(%w+)::(.+)$")
        local class = class_name and _G[class_name]
        assert(class and class.on, "ui.widget: bad watch name "..tostring(name))
        if not watched[name] then
            local cb = function() core.dirty() end
            watched[name] = {class=class, signal=signal, fn=cb}
            class.on(signal, cb)
        end
    end
    if spec.every ~= nil then
        assert(type(spec.every)=="number" and spec.every>0, "ui.widget needs a positive interval")
        local generation = widget_generation
        local id
        local function tick()
            if generation ~= widget_generation then return end
            id = core.timer(spec.every*1000, function()
                timers[id] = nil
                if generation ~= widget_generation then return end
                core.dirty()
                tick()
            end)
            timers[id] = true
        end
        tick()
    end
    return fn
end
function ui._publish_each(sn)
    for key, by_screen in pairs(each_state) do
        by_screen[sn] = state.each_candidate[key]
    end
end
function ui._remove(sn)
    for _, by_screen in pairs(each_state) do by_screen[sn] = nil end
end
function ui._reset()
    widget_generation = widget_generation + 1
    for _, w in pairs(watched) do w.class.off(w.signal, w.fn) end
    for id in pairs(timers) do core.timer_cancel(id) end
    each_state, watched, timers = setmetatable({}, {__mode="k"}), {}, {}
end

local bar_edges = {top=true, bottom=true, left=true, right=true}
function ui.bar(s, cfg, fn)
    cfg = cfg or {}
    assert(cfg.edge==nil or bar_edges[cfg.edge], "ui.bar: bad edge: "..tostring(cfg.edge))
    table.insert(s.bars, {cfg=cfg, fn=fn})
    core.dirty(s.name)
end

return ui
