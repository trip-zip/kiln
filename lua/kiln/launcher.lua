-- The application launcher: every installed .desktop app behind a
-- type-to-filter entry.
--
-- It is a prompt plus a list, and that pairing is the whole design. A menu
-- walks with the keyboard and stays put at an edge, but it is a fixed list of
-- rows, and NARROWING a list as the user types is a prompt's job. So the
-- keyboard belongs to kiln.prompt for the launcher's whole lifetime and the
-- list is declared under it.
--
-- Which is also why the list is not a ui.popup. A popup with keys would take
-- the keyboard, and taking it from the prompt would stop the prompt's claim,
-- whose stopped callback closes the prompt, which closes the launcher. One
-- claim per device with no stack is the rule, and the prompt is the one that
-- wants it here. So the list rides a plain declare hook and holds nothing.
--
-- The list attaches to the prompt's own element. That is worth a note because
-- it was not possible until the declare registry existed: a float whose target
-- has never been declared is a Clay error that takes the compositor down, and
-- the launcher's first open is exactly that case, since the prompt and the list
-- first appear on the same frame. Hooks run AFTER the runtime declares the
-- prompt, so the target is there, and the height arithmetic a config had to sum
-- out of theme parts is gone.

local ui = require("kiln.ui")
local state = require("kiln.state")
local prompt = require("kiln.prompt")
local hook = require("kiln.hook")

local launcher = {}

-- The run in flight, its match set, and which match is selected. Nothing is
-- declared while `run` is nil.
local run = nil
local matches = {}
local sel = 1

-- The scan, once per session. A reload drops it (see launcher.reset), so a
-- newly installed app costs a reload rather than a per-open rescan of every
-- data dir on the machine.
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

-- Lua's stdlib has no readdir, so the listing shells out.
local function desktops(dir)
	local out = {}
	local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
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
	-- The field codes (%U, %f, ...) are what the spec would have the launcher
	-- substitute a file into. Nothing is being opened here, so they come out.
	exec = exec:gsub("%%(.)", function(c)
		return c == "%" and "%" or ""
	end)
	return { name = name, exec = (exec:gsub("%s+$", "")) }
end

-- Every installed application, scanned once and kept. The first .desktop of a
-- given basename wins, which is the spec's own precedence: a user's copy in
-- XDG_DATA_HOME shadows the system one.
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

-- The ranking, and a public field rather than a private function: a config that
-- wants fuzzy matching, or frecency, or its own ordering, assigns one function
-- and keeps the rest of the launcher. Reload restores this default, since a
-- replacement is config state.
--
-- Three tiers: a name that STARTS with the text, then one that merely contains
-- it, then a match on the command itself. Case-insensitive, and the empty
-- string matches everything, so opening with nothing typed lists them all.
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

-- What the launcher is showing right now, so a config (or a probe) can ask
-- without reaching into the module.
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

-- Through spawn_with_token: the user asked for this window, so it arrives
-- holding an xdg-activation token and is allowed to raise itself.
local function launch(a)
	run = nil
	launcher.spawn(a.exec)
end

function launcher.open(s)
	s = s or screen.focused or state.screens[1]
	if s == nil then
		return
	end
	matches, sel = launcher.filter(""), 1
	run = prompt.run {
		screen = s,
		label = "Run: ",
		-- Its own history: walking the launcher with Up should not step through
		-- the shell lines the run prompt left in the shared list.
		history = {},
		changed = function(text)
			matches, sel = launcher.filter(text), 1
			core.dirty(s.name)
		end,
		-- Tab is the only selection key a config can reach: Return and Escape
		-- finish, Up and Down are the prompt's history walk, and Left and Right
		-- are its cursor. So Tab steps the highlight and writes the selected
		-- name back into the entry. The prompt's Tab branch assigns the text
		-- WITHOUT firing `changed`, so the match set holds still while the
		-- cycle walks it.
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
				-- Nothing matched: run what was typed as a command.
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

-- Assigned by init.lua, which owns the spawn verbs. A field rather than a
-- require, because kiln.spawn_with_token lives on the library table this module
-- cannot require without a cycle.
launcher.spawn = function() end

-- Called by the declare registry inside every screen's declare.
function launcher.declare(s)
	if run == nil then
		return
	end
	-- The prompt drops itself when something else claims the keyboard, and that
	-- path calls no config callback, so the list checks the claim it rode in on
	-- rather than trusting its own flag.
	if prompt.active ~= run then
		run = nil
		return
	end
	if run.screen ~= s then
		return
	end
	local th = state.theme
	local target = "prompt:" .. s.name
	local pb = core.box(target)
	-- How tall the column may get: what the workarea leaves under the prompt.
	-- Clamping a column TALLER than the workarea has no legal answer, it only
	-- drags the list up over its own prompt; what bounds the box is a `max` on
	-- the fit axis plus a clip, which is the pair ui.scroll is built from.
	--
	-- The prompt's own solved box is where "under the prompt" starts. It is one
	-- frame stale at worst and absent only before the first solve, where the
	-- theme's offset is the honest fallback and the next frame corrects it.
	local wa = s.workarea or { y = 0, height = s.height }
	local below = pb ~= nil and (pb.y + pb.height) or th.prompt_offset
	local room = math.max(th.menu_height, wa.y + wa.height - below)
	-- The window around the selection is a COST decision, not a layout one:
	-- declaring every match instead costs a slice of the frame budget laying out
	-- rows Clay would then clip. Clay bounds the box; this bounds the work. One
	-- row is held back so the "+N more" tail always has somewhere to sit.
	local rows = math.max(1, math.floor((room - 2 * 4) / th.menu_height) - 1)
	local first = 1
	if sel > rows then
		first = sel - rows + 1
	end
	local last = math.min(#matches, first + rows - 1)
	ui.column({
		id = "launcher-list",
		-- Attached to the prompt's element, not floated at a summed offset.
		float = {
			to = "element", parent = target, band = "overlay",
			anchor = { parent = "left_bottom", element = "left_top" },
			offset = { x = 0, y = 6 },
		},
		-- Asked of the prompt rather than read off its solved box, because on
		-- the frame the launcher first opens there is no previous solve to read
		-- and the list would come out the width of its widest row. Same input,
		-- same answer, one frame earlier.
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
			-- Keyed by ROW POSITION rather than by app, which is the tasklist's
			-- clip-slot discipline for the same reason: positions are reused and
			-- so bounded by what a screen shows, where a per-app id would spend
			-- an id per app that has ever been listed.
			ui.row({
				id = "launcher-row:" .. i,
				w = "grow", h = th.menu_height,
				pad = { x = 6 }, gap = 6, align = { y = "center" },
				radius = 3,
				color = i == sel and th.bg2 or nil,
				on_press = function()
					local r = run
					launch(a)
					if r ~= nil then
						r:stop()
					end
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

-- Registered at module load, so it is stdlib tier: the hook survives a reload
-- and the rc does not re-register it.
hook.add(function(s)
	launcher.declare(s)
end)

-- The reload pair. The scan cache and a replaced filter are both config-era
-- state: the cache so a reload picks up newly installed apps, the filter
-- because a config assigned it.
function launcher.reset()
	apps_cache = nil
	launcher.filter = launcher.default_filter
	run = nil
	matches, sel = {}, 1
end

return launcher
