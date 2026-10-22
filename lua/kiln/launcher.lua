
local ui = require("kiln.ui")
local state = require("kiln.state")
local prompt = require("kiln.prompt")
local hook = require("kiln.hook")

local launcher = {}
local services=require("kiln.desktop_services")

local run = nil
local matches = {}
local sel = 1

local apps_cache = nil

local function app_dirs()
	local home = os.getenv("HOME") or ""
	local data_home = os.getenv("XDG_DATA_HOME")
	if data_home == nil or data_home == "" then
		data_home = home .. "/.local/share"
	end
	local dirs_env = os.getenv("XDG_DATA_DIRS")
	if dirs_env == nil or dirs_env == "" then
		dirs_env = "/usr/local/share:/usr/share"
	end
	local dirs = { data_home }
	for d in (dirs_env .. ":"):gmatch("([^:]*):") do
		if d ~= "" then
			dirs[#dirs + 1] = d
		end
	end
	for i, d in ipairs(dirs) do
		dirs[i] = d .. "/applications"
	end
	return dirs
end

local function desktops(dir)
	local out = {}
	local p = io.popen("ls -1 -- '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
	if p == nil then
		return out
	end
	for line in p:lines() do
		if line:match("%.desktop$") then
			out[#out + 1] = dir .. "/" .. line
		end
	end
	p:close()
	return out
end

local function parse_desktop(path)
	local f = io.open(path, "r")
	if f == nil then
		return nil
	end
	local entry, name, exec, show = false, nil, nil, true
	for line in f:lines() do
		local head = line:match("^%[(.-)%]$")
		if head ~= nil then
			entry = head == "Desktop Entry"
		elseif entry then
			local k, v = line:match("^([%w-]+)%s*=%s*(.*)$")
			if k == "Name" and name == nil then
				name = v
			elseif k == "Exec" then
				exec = v
			elseif k == "Type" and v ~= "Application" then
				show = false
			elseif (k == "NoDisplay" or k == "Hidden") and v == "true" then
				show = false
			end
		end
	end
	f:close()
	if not show or name == nil or exec == nil then
		return nil
	end
	exec = exec:gsub("%%(.)", function(c)
		return c == "%" and "%" or ""
	end)
	return { name = name, exec = (exec:gsub("%s+$", "")) }
end

function launcher.apps()
	if apps_cache ~= nil then
		return apps_cache
	end
	local seen, apps = {}, {}
	for _, dir in ipairs(app_dirs()) do
		for _, path in ipairs(desktops(dir)) do
			local base = path:match("([^/]+)$")
			if not seen[base] then
				seen[base] = true
				local a = parse_desktop(path)
				if a ~= nil then
					apps[#apps + 1] = a
				end
			end
		end
	end
	table.sort(apps, function(x, y)
		return x.name:lower() < y.name:lower()
	end)
	apps_cache = apps
	return apps
end

function launcher.default_filter(text)
	local q = text:lower()
	local pre, sub, cmd = {}, {}, {}
	for _, a in ipairs(launcher.apps()) do
		local name = a.name:lower()
		if q == "" or name:sub(1, #q) == q then
			pre[#pre + 1] = a
		elseif name:find(q, 1, true) ~= nil then
			sub[#sub + 1] = a
		elseif a.exec:lower():find(q, 1, true) ~= nil then
			cmd[#cmd + 1] = a
		end
	end
	for _, tier in ipairs({ sub, cmd }) do
		for _, a in ipairs(tier) do
			pre[#pre + 1] = a
		end
	end
	return pre
end

launcher.filter = launcher.default_filter

function launcher.matches()
	return matches
end

function launcher.close()
	local r = run
	run = nil
	if r ~= nil then
		r:stop()
	end
end

local function launch(a)
	run = nil
	launcher.spawn(a.exec)
end

function launcher.open(s)
	s = s or screen.focused or screen.all()[1]
	if not services.live(s) then
		return
	end
	matches, sel = launcher.filter(""), 1
	run = prompt.run {
		screen = s,
		label = "Run: ",
		history = {},
		changed = function(text)
			matches, sel = launcher.filter(text), 1
			core.dirty(s.name)
		end,
		completion = function()
			if #matches == 0 then
				return nil
			end
			sel = sel % #matches + 1
			core.dirty(s.name)
			local name = matches[sel].name
			return name, #name
		end,
		done = function(text)
			local a = matches[sel]
			run = nil
			if a ~= nil then
				launcher.spawn(a.exec)
			elseif text ~= "" then
				launcher.spawn(text)
			end
			core.dirty(s.name)
		end,
		cancelled = function()
			run = nil
			core.dirty(s.name)
		end,
	}
	core.dirty(s.name)
	return run
end

launcher.spawn = core.spawn_with_token

function launcher.declare(s)
	if run == nil then
		return
	end
	if prompt.active ~= run then
		run = nil
		return
	end
	if run.screen ~= s then
		return
	end
	local owner = run
	local th = state.theme
	local target = "prompt:" .. s.name
    if not core._declared(target) then return end
	local pb = core.box(target)
	local wa = s.workarea or { y = 0, height = s.height }
	local below = pb ~= nil and (pb.y + pb.height) or th.prompt_offset
	local room = math.max(th.menu_height, wa.y + wa.height - below)
	local rows = math.max(1, math.floor((room - 2 * 4) / th.menu_height) - 1)
	local first = 1
	if sel > rows then
		first = sel - rows + 1
	end
	local last = math.min(#matches, first + rows - 1)
	ui.column({
		id = "launcher-list",
		float = {
			to = "element", parent = target, band = "overlay", fit = true,
			anchor = { parent = "left_bottom", element = "left_top" },
			offset = { x = 0, y = 6 },
		},
		w = prompt.width(s),
		h = { "fit", max = room },
		clip = { vertical = true },
		color = th.bg, radius = 6, pad = 4,
		border = { width = 1, color = th.accent },
	}, function()
		if #matches == 0 then
			ui.box({ h = th.menu_height, pad = { x = 6 },
				align = { y = "center" } }, function()
				ui.text("no match", { size = 12, color = th.muted })
			end)
			return
		end
		for i = first, last do
			local a = matches[i]
			ui.row({
				id = "launcher-row:" .. i,
				w = "grow", h = th.menu_height,
				pad = { x = 6 }, gap = 6, align = { y = "center" },
				radius = 3,
				color = i == sel and th.bg2 or nil,
				on_press = function()
					if run ~= owner or prompt.active ~= owner then return end
					local r = run
                    if r then r:stop() end
                    launch(a)
					core.dirty(s.name)
				end,
			}, function()
				ui.text(a.name, { size = 12,
					color = i == sel and th.fg or th.muted })
			end)
		end
		if last < #matches then
			ui.box({ h = th.menu_height, pad = { x = 6 },
				align = { y = "center" } }, function()
				ui.text("+" .. (#matches - last) .. " more",
					{ size = 12, color = th.muted })
			end)
		end
	end)
end

hook.add(function(s)
	launcher.declare(s)
end)

function launcher.reset()
	apps_cache = nil
	launcher.filter = launcher.default_filter
	launcher.spawn = core.spawn_with_token
	run = nil
	matches, sel = {}, 1
end

return launcher
