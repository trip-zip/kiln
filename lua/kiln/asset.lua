-- Generated images, content-addressed. The declaration layer can NAME an image
-- and cannot make one, so anything the renderer has no vocabulary for (a
-- gradient, a line-art glyph, a blurred tile) has to arrive as a file. This is
-- the machinery for that: hand it an SVG document, get back a readable PNG path
-- the image leaf accepts.
--
-- THIS FORKS A SUBPROCESS AND WRITES A FILE. It is for static and low-rate
-- content: chrome that changes on a theme switch or a mode change, never
-- anything that varies per frame. A caller that needs a new document every
-- frame is asking for a fork every frame.
--
-- The cache is CONTENT-ADDRESSED: the digest of the document is in the
-- filename, so every input that changes the pixels is in the name and there is
-- nothing to invalidate. The compositor's own decode cache keys on the path, so
-- the two caches agree for free.
--
-- Three steps rather than one, because the fork is the expensive part: request
-- many, flush once, then resolve each. A set of twenty glyphs is one process.
-- M.svg is the one-shot for a caller with a single document.

local ui = require("kiln.ui")

local M = {}

local cache_home = os.getenv("XDG_CACHE_HOME")
if cache_home == nil or cache_home == "" then
	cache_home = (os.getenv("HOME") or ".") .. "/.cache"
end
local asset_dir = cache_home .. "/kiln/assets"
local function quote(s) return "'" .. s:gsub("'", "'\"'\"'") .. "'" end

-- Existence, the only filesystem question this asks, and also the RENDER CHECK.
-- rsvg-convert may be missing or may fail, and a path that decodes to nothing
-- renders BLANK rather than erroring (the decode is lazy, so nothing reports
-- it). An asset is therefore only usable once it is readable, and every call
-- site draws its non-image fallback when the answer is nil. That is the whole
-- guard against a silently empty desktop.
local function readable(path)
	local f = io.open(path, "r")
	if f == nil then
		return false
	end
	f:close()
	return true
end

local pending = {}
local queued, resolved = {}, {}
local dir_made = false

local function asset_png(key)
	return asset_dir .. "/" .. key .. ".png"
end

-- A cheap content digest, so "content-addressed" means addressed by the CONTENT
-- and not by a name that happens to correlate with it. Every input a caller has
-- is already in the document: the colour, the size, and the SHAPE. A key built
-- from the name and the colour alone misses the last one, and editing a shape
-- then keeps serving the stale PNG forever. djb2 over the document, in double
-- arithmetic that stays well inside 2^53.
local function digest(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 4294967296
	end
	return string.format("%08x", h)
end

-- Queue a render if the PNG is not already cached, and answer the key it will
-- be found under. Writing the SVG is io.open; the mkdir is deferred to the
-- first write, so a warm cache forks NOTHING.
--
-- The name is the caller's half of the filename and exists only so the cache
-- dir reads at a glance; the digest is what makes the name correct.
function M.request(name, w, h, svg)
	local key = name .. "-" .. digest(svg)
	if queued[key] or readable(asset_png(key)) then
		return key
	end
	if not dir_made then
		os.execute("mkdir -p " .. quote(asset_dir))
		dir_made = true
	end
	local f = io.open(asset_dir .. "/" .. key .. ".svg", "w")
	if f == nil then
		return key
	end
	f:write(svg)
	f:close()
	queued[key] = true
	pending[#pending + 1] = string.format(
		"rsvg-convert -w %d -h %d -o %s %s",
		w, h, quote(asset_png(key)), quote(asset_dir .. "/" .. key .. ".svg"))
	return key
end

-- One process for the whole batch. rsvg-convert takes a file per call, so the
-- calls are joined rather than batched by the tool; the single fork is the point.
function M.flush()
	if #pending == 0 then
		return
	end
	os.execute("{ " .. table.concat(pending, "; ") .. " ; } >/dev/null 2>&1")
	pending = {}
end

-- Memoized both ways: a hit is one io.open per key per session, and a miss is
-- remembered so a failed render is never retried per frame.
function M.path(key)
	local hit = resolved[key]
	if hit ~= nil then
		return hit or nil
	end
	local png = asset_png(key)
	local ok = readable(png)
	resolved[key] = ok and png or false
	return ok and png or nil
end

-- The one-shot: one document, rendered now. A caller with several should
-- request them all before flushing, or pay a fork each.
function M.svg(name, w, h, svg)
	local key = M.request(name, w, h, svg)
	M.flush()
	return M.path(key)
end

-- ---------------------------------------------------------------------
-- Gradients.
--
-- The renderer's rectangle carries one flat colour and a corner radius, so a
-- ramp is not something a declaration can ask for. It can ask for an image, and
-- this is the image.
--
-- Two spec forms, both accepted, because a config carried over from a project
-- whose colour type understood ramps directly is written in one of them:
--
--   "linear:x0,y0:x1,y1:0,#ff0000:1,#0000ff"
--   { type = "linear", from = {x0,y0}, to = {x1,y1},
--     stops = { {0,"#ff0000"}, {1,"#0000ff"} } }
--
-- What does NOT carry over is the return value. There is no painting in Lua
-- here and no live pattern object to hand back, so this returns a path, or nil.

-- Every number written into the document is an integer, because string.format
-- goes through sprintf for the float conversions and one locale that formats a
-- decimal comma would silently produce a blank picture. Coordinates are pixels
-- in user space, offsets are whole percent, and the one unavoidable fraction
-- (opacity) is assembled from two integers around a literal dot.
local function px(v)
	return math.floor(tonumber(v) + 0.5)
end

-- The colour goes through the same parser every declaration uses, so a config
-- writes one colour vocabulary and not two. Alpha cannot ride the hex in a
-- stop, which is why it comes back out as its own attribute.
local function stop_tag(offset, color)
	local c = ui.color(color)
	local tag = string.format(
		'<stop offset="%d%%" stop-color="#%02x%02x%02x"',
		math.floor(offset * 100 + 0.5), c.r, c.g, c.b)
	if c.a ~= 255 then
		local q = math.floor(c.a * 1000 / 255 + 0.5)
		tag = tag .. string.format(' stop-opacity="%d.%03d"',
			math.floor(q / 1000), q % 1000)
	end
	return tag .. "/>"
end

-- The string form, into the table form. Split on colons: the type, the two
-- points, then a stop per remaining field.
local function parse_spec(s)
	local parts = {}
	for f in (s .. ":"):gmatch("([^:]*):") do
		parts[#parts + 1] = f
	end
	local spec = { type = parts[1], stops = {} }
	local function point(f)
		local a, b = (f or ""):match("^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*$")
		if a == nil then
			error("bad gradient point: " .. tostring(f), 4)
		end
		return { tonumber(a), tonumber(b) }
	end
	spec.from, spec.to = point(parts[2]), point(parts[3])
	for i = 4, #parts do
		local off, col = parts[i]:match("^%s*([%d%.]+)%s*,%s*(.+)$")
		if off == nil then
			error("bad gradient stop: " .. tostring(parts[i]), 4)
		end
		spec.stops[#spec.stops + 1] = { tonumber(off), col }
	end
	return spec
end

-- A ramp `w` by `h` device pixels, as a readable PNG path or nil.
--
-- The SIZE IS THE CALLER'S: it comes from a box the solver already answered
-- (a canvas reading times the output scale), never from arithmetic that
-- re-derives where the thing will land. This function is handed a pixel count
-- and does not know what it is for.
--
-- Coordinates in the spec are in that same pixel space, so 0,0 to w,h is corner
-- to corner. Linear only.
function M.gradient(spec, w, h)
	if type(spec) == "string" then
		spec = parse_spec(spec)
	end
	if type(spec) ~= "table" then
		error("bad gradient spec: " .. tostring(spec), 2)
	end
	if spec.type ~= "linear" then
		error("unsupported gradient type: " .. tostring(spec.type) ..
			" (linear only)", 2)
	end
	if type(spec.from) ~= "table" or type(spec.to) ~= "table" or
		spec.from[2] == nil or spec.to[2] == nil then
		error("gradient needs from and to, each {x,y}", 2)
	end
	if spec.stops == nil or #spec.stops == 0 then
		error("gradient needs at least one stop", 2)
	end
	w, h = px(w), px(h)
	if w < 1 or h < 1 then
		return nil
	end
	local stops = {}
	for i, s in ipairs(spec.stops) do
		stops[i] = stop_tag(s[1], s[2])
	end
	local svg = string.format(
		'<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">' ..
		'<defs><linearGradient id="g" gradientUnits="userSpaceOnUse" ' ..
		'x1="%d" y1="%d" x2="%d" y2="%d">%s</linearGradient></defs>' ..
		'<rect width="%d" height="%d" fill="url(#g)"/></svg>',
		w, h,
		px(spec.from[1]), px(spec.from[2]), px(spec.to[1]), px(spec.to[2]),
		table.concat(stops), w, h)
	return M.svg(string.format("gradient-%dx%d", w, h), w, h, svg)
end

return M
