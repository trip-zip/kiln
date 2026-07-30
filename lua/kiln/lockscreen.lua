-- The compositor's drop-in native lockscreen. C owns the quarantine,
-- the opaque floor, and the PAM-gated unlock; this module only
-- paints the prompt and feeds core.authenticate. A config may replace it
-- wholesale: register your own core.set_lock_handler and handle the
-- session::lock / session::unlock events, or just override the colors and
-- formats via kiln.lockscreen.configure {}.

local ui = require("kiln.ui")

local M = {}

-- True only while a NATIVE lock is engaged (an external locker paints its own
-- surface, so this stays inert). init.lua routes key events here while set.
M.active = false

local password = ""
local status = nil
local status_error = false
local tick_scheduled = false

local config = {
	bg = "#101014",
	fg = "#dcdce6",
	error = "#c05068",
	clock_size = 48,
	date_size = 16,
	dots_size = 22,
	status_size = 14,
	clock_format = "%H:%M",
	date_format = "%A, %B %d",
	prompt = "Enter password to unlock",
	fail = "Authentication failed",
}

function M.configure(cfg)
	for k, v in pairs(cfg or {}) do
		config[k] = v
	end
end

-- LuaJIT has no utf8 library: count codepoints so the dot row tracks typed
-- graphemes, not bytes, and backspace drops a whole codepoint.
local function utf8_len(s)
	local n = 0
	for i = 1, #s do
		local b = s:byte(i)
		if b < 0x80 or b >= 0xC0 then
			n = n + 1
		end
	end
	return n
end

local function utf8_backspace(s)
	local i = #s
	while i > 0 do
		local b = s:byte(i)
		if b < 0x80 or b >= 0xC0 then
			break
		end
		i = i - 1
	end
	return s:sub(1, i - 1)
end

-- Keep the clock live: re-mark dirty once a second while locked. One-shot
-- timers re-arm themselves; the guard stops the chain at unlock.
local function schedule_tick()
	if tick_scheduled then
		return
	end
	tick_scheduled = true
	core.timer(1000, function()
		tick_scheduled = false
		if M.active then
			core.dirty()
			schedule_tick()
		end
	end)
end

-- The lock frame handler, declared into the dedicated lock context
-- (core_declare_lock) above the C opaque floor. A Lua error here keeps the
-- previous lock frame; the floor still hides the desktop, so a broken lock
-- declare can never reveal a client buffer.
core.set_lock_handler(function(screen_name, width, height)
	local dots = string.rep("*", utf8_len(password))
	ui.column({
		id = "lock:" .. screen_name,
		color = config.bg,
		w = "grow",
		h = "grow",
		align = { x = "center", y = "center" },
		gap = 14,
	}, function()
		ui.text(os.date(config.clock_format), {
			size = config.clock_size, color = config.fg })
		ui.text(os.date(config.date_format), {
			size = config.date_size, color = config.fg })
		-- A space keeps the row's height stable when the field is empty.
		ui.text(dots == "" and " " or dots, {
			size = config.dots_size, color = config.fg })
		ui.text(status or config.prompt, {
			size = config.status_size,
			color = status_error and config.error or config.fg })
	end)
end)

function M.on_lock(kind)
	if kind ~= "native" then
		return
	end
	M.active = true
	password = ""
	status = config.prompt
	status_error = false
	schedule_tick()
	core.dirty()
end

function M.on_unlock()
	M.active = false
	password = ""
	status = nil
	status_error = false
end

-- Fed every key while natively locked (init.lua routes here instead of the
-- desktop bindings, so no chord fires under the lock). Enter authenticates;
-- the C unlock gate opens only on a PAM success.
function M.on_key(ev)
	if not ev.pressed then
		return
	end
	local key = ev.key
	if key == "Return" or key == "KP_Enter" then
		if core.authenticate(password) then
			core.unlock()
		else
			status = config.fail
			status_error = true
			password = ""
		end
	elseif key == "BackSpace" then
		password = utf8_backspace(password)
		status = config.prompt
		status_error = false
	elseif key == "Escape" then
		password = ""
		status = config.prompt
		status_error = false
	elseif ev.utf8 ~= nil and ev.utf8 ~= "" then
		password = password .. ev.utf8
		status = config.prompt
		status_error = false
	end
	core.dirty()
end

return M
