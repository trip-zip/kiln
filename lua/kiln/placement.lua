local state = require("kiln.state")

local placement = {}

-- The box to place against: what is left after chrome, or the whole output before
-- the first solve, which is the fallback every other workarea consumer writes.
local function area(c, s)
	s = s or c.screen
	return s.workarea or { x = 0, y = 0, width = s.width, height = s.height }
end

-- The box being placed: c.float, or the defaults float_client would materialize.
-- c.x/c.y are C's committed facts about the surface and are not this box.
local function box(c)
	local f = c.float or {}
	return {
		x = f.x or 0, y = f.y or 0,
		width = f.width or (c.width > 0 and c.width or 400),
		height = f.height or (c.height > 0 and c.height or 300),
	}
end

-- One whole-table write, so one property::float and one re-declare.
local function put(c, f)
	c.float = f
	return c
end

-- A box wider than the area has nowhere legal to sit: pin it to the origin rather
-- than clamp it past the far edge, which would push its top-left off screen.
local function clamp(v, lo, hi)
	return math.max(lo, math.min(v, math.max(lo, hi)))
end

-- Eleven named combinators are one table: where on each axis the box
-- sits, 0 at the near edge, 1 at the far one, 0.5 centered, nil meaning "this axis
-- is not this helper's business" (center_horizontal must not move y). That is the
-- whole of the D claim -- the names were never behavior, they were coordinates.
for name, at in pairs({
	centered = { 0.5, 0.5 },
	center_horizontal = { 0.5, nil }, center_vertical = { nil, 0.5 },
	left = { 0, 0.5 }, right = { 1, 0.5 },
	top = { 0.5, 0 }, bottom = { 0.5, 1 },
	top_left = { 0, 0 }, top_right = { 1, 0 },
	bottom_left = { 0, 1 }, bottom_right = { 1, 1 },
}) do
	placement[name] = function(c, s)
		local a, f = area(c, s), box(c)
		if at[1] ~= nil then
			f.x = a.x + math.floor(at[1] * (a.width - f.width))
		end
		if at[2] ~= nil then
			f.y = a.y + math.floor(at[2] * (a.height - f.height))
		end
		return put(c, f)
	end
end

function placement.no_offscreen(c, s)
	local a, f = area(c, s), box(c)
	f.x = clamp(f.x, a.x, a.x + a.width - f.width)
	f.y = clamp(f.y, a.y, a.y + a.height - f.height)
	return put(c, f)
end

-- Two boxes overlap when they share area; touching edges do not count, so a box
-- placed exactly at another's edge is a clear slot.
local function overlaps(f, b)
	return f.x < b.x + b.width and b.x < f.x + f.width
		and f.y < b.y + b.height and b.y < f.y + f.height
end

-- Place c's float to clear every other declared float on the screen: try the
-- workarea origin, then the right and bottom edge of each occupied box, and take
-- the first candidate that sits inside the workarea and overlaps nothing. The
-- occupied set is the selected-plus-sticky union the layout actually draws;
-- duplicate boxes from a multi-tag client are harmless to the hit test. With no
-- free slot it degrades to no_offscreen, the "nowhere legal" posture clamp() has.
function placement.no_overlap(c, s)
	s = s or c.screen
	local a, f = area(c, s), box(c)
	local occ, eligible, seen = {}, {}, {}
    for _, o in ipairs(require('kiln').visible_clients(s)) do eligible[o]=true end
	for _, t in ipairs(s.tags or {}) do
		for _, o in ipairs(t.clients) do
			if (t.selected or o.sticky) and o ~= c and o.mapped
					and not o.minimized and o.floating and o.float ~= nil and eligible[o] and not seen[o] then
                seen[o]=true
				occ[#occ + 1] = box(o)
			end
		end
	end
	local cand = { { a.x, a.y } }
	for _, b in ipairs(occ) do
		cand[#cand + 1] = { b.x + b.width, b.y }
		cand[#cand + 1] = { b.x, b.y + b.height }
	end
	for _, p in ipairs(cand) do
		f.x, f.y = p[1], p[2]
		local ok = f.x >= a.x and f.y >= a.y
			and f.x + f.width <= a.x + a.width
			and f.y + f.height <= a.y + a.height
		for _, b in ipairs(occ) do ok = ok and not overlaps(f, b) end
		if ok then return put(c, f) end
	end
	return placement.no_offscreen(c, s)
end

-- The pointer is a fact the motion event leaves in state (init.lua); nothing is
-- polled and nothing is asked of C. Before the first motion there is no pointer,
-- and a launcher summoned by a key has none anyway, so fall back to centered.
function placement.under_mouse(c, s)
	local p = state.pointer
	if p == nil then
		return placement.centered(c, s)
	end
	local f = box(c)
	s = s or c.screen
    local a = area(c,s)
    f.x = clamp(p.x-(s.x or 0)-math.floor(f.width/2),a.x,a.x+a.width-f.width)
    f.y = clamp(p.y-(s.y or 0)-math.floor(f.height/2),a.y,a.y+a.height-f.height)
    return put(c,f)
end

return placement
