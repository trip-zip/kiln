-- Bounded XDG lookup keeps icon probing out of steady declarations.
-- A missing path remains nil so widgets can draw their placeholder.

local M = {}

-- The XDG icon/data search path: $XDG_DATA_HOME first, then each
-- $XDG_DATA_DIRS entry, defaults per the XDG base-dir convention.
local function data_dirs()
	local home = os.getenv("HOME") or ""
	local data_home = os.getenv("XDG_DATA_HOME")
	if data_home == nil or data_home == "" then
		data_home = home .. "/.local/share"
	end
	local data_dirs_env = os.getenv("XDG_DATA_DIRS")
	if data_dirs_env == nil or data_dirs_env == "" then
		data_dirs_env = "/usr/local/share:/usr/share"
	end
	local dirs = { data_home }
	for d in (data_dirs_env .. ":"):gmatch("([^:]*):") do
		if d ~= "" then
			dirs[#dirs + 1] = d
		end
	end
	return dirs
end

-- Existence, the only filesystem question this module asks: open for read and
-- close. Lua's stdlib has no stat, and a decode-time failure would blank the
-- leaf anyway, so a readable path is as far as the probe goes.
local function probe(path)
	local f = io.open(path, "r")
	if f ~= nil then
		f:close()
		return true
	end
	return false
end

-- The .desktop Icon= line for an app, direct filename match only (no directory
-- scan, no NoDisplay logic: this lookup answers one name and nothing more).
-- First Icon= wins.
local function desktop_icon(name)
	for _, dir in ipairs(data_dirs()) do
		local f = io.open(dir .. "/applications/" .. name .. ".desktop", "r")
		if f ~= nil then
			for line in f:lines() do
				local icon = line:match("^Icon%s*=%s*(.+)$")
				if icon ~= nil then
					f:close()
					return icon
				end
			end
			f:close()
		end
	end
	return nil
end

-- The fixed icon-theme probe list: hicolor at a few common sizes then pixmaps.
-- No theme name, no inherits chain. An absolute path (or one an Icon= line gave
-- verbatim) is taken as-is; a bare name is resolved against the list.
--
-- Prefer sized PNGs before scalable SVGs. Readability cannot promise that
-- the renderer has a decoder for the format; decoding stays with the renderer.
local sizes = { "128x128", "64x64", "48x48", "32x32", "24x24", "16x16",
	"scalable" }

local function icon_file(name)
	if name:sub(1, 1) == "/" then
		return probe(name) and name or nil
	end
	if probe(name) then
		return name
	end
	for _, dir in ipairs(data_dirs()) do
		for _, sz in ipairs(sizes) do
			local ext = sz == "scalable" and "svg" or "png"
			local p = dir .. "/icons/hicolor/" .. sz .. "/apps/" .. name ..
				"." .. ext
			if probe(p) then
				return p
			end
		end
		for _, ext in ipairs({ "png", "svg" }) do
			local p = dir .. "/pixmaps/" .. name .. "." .. ext
			if probe(p) then
				return p
			end
		end
	end
	return nil
end

-- The lookup, memoized. A miss is cached as false so a name nothing ships is
-- probed once, not every frame the tasklist declares. Returns the path or nil.
local cache = {}

function M.path(name)
	if name == nil or name == "" then
		return nil
	end
	local hit = cache[name]
	if hit ~= nil then
		return hit or nil
	end
	-- The .desktop Icon= line is the app's own answer; fall through to the
	-- theme probe (which also resolves the bare name the Icon= line often is).
	local from_desktop = desktop_icon(name)
	local path = icon_file(from_desktop or name)
	cache[name] = path or false
	return path
end

-- A supplied image key wins; app ID and class names provide file fallbacks.
function M.client(c)
	if c.icon ~= nil then
		return c.icon
	end
	local by_app = M.path(c.app_id)
	if by_app ~= nil then
		return by_app
	end
	if c.class ~= nil then
		return M.path(c.class) or M.path(c.class:lower())
	end
	return nil
end

return M
