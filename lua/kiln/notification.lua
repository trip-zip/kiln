-- Notifications: the object, the timeouts, the suspension
-- queue, the actions, and the default display. All of it, here, in Lua.
--
-- C answered a DBus method and reported the facts (an id it minted because the
-- Notify reply is synchronous, and the fields the client sent). Everything that
-- is a DECISION is below: how long a notification lives, what "critical" means,
-- what replacing an id does, where the popups sit, what a press dismisses, and
-- which of the three image facts wins. A C leg that expired, placed, ranked, or
-- queued any of this would be C deciding what was left to policy.
--
-- The class is a pure mixin like tag: no handle, no registry, no C. The DBus id
-- is a plain property, nil for a notification raised inside the compositor, and
-- the two verbs are only reached when one is present: an in-compositor
-- notification never touches the bus.
--
-- It lives beside menu.lua and tooltip.lua for the same reason they do: it owns
-- cross-frame state and a declare hook the runtime calls, and ui.lua is the
-- element layer. The public names are kiln.notify and the notification class
-- (init.lua binds both), because ui.lua cannot require this module without a
-- cycle.

local ui = require("kiln.ui")
local widgets = require("kiln.widgets")
local object = require("kiln.object")
local state = require("kiln.state")

-- Global, like client/screen/tag/layer: ui.widget{ watch = "notification::..." }
-- resolves a class through _G, and a config says notification.on(...).
notification = object.class("notification")

local M = {}

-- Visible now, in post order. Suspended arrivals go to pending instead and are
-- shown, in arrival order, when suspension lifts.
local active = {}
local pending = {}
local suspended = false
local seq = 0

-- The protocol's close reasons (org.freedesktop.Notifications). The map lives
-- here because naming a reason is Lua's; C takes the integer and emits.
local REASON = {
	expired = 1,
	user = 2,
	action = 2, -- an invoked action closes as dismissed, per the spec
	closed = 3, -- the client called CloseNotification
}

local function index_of(list, n)
	for i, item in ipairs(list) do
		if item == n then
			return i
		end
	end
end

local function dirty(n)
	local s = n.screen
	if s ~= nil then
		core.dirty(s.name)
	else
		core.dirty()
	end
end

-- Expiry is owned by the retained notification, with a monotonic deadline.
local function cancel(n)
    if n._timer then core.timer_cancel(n._timer); n._timer = nil end
    n._deadline = nil
end
local function arm(n, remaining)
    cancel(n)
    if not n.alive or n.urgency == "critical" or not index_of(active, n) then return end
    local t = remaining or n.timeout
    if type(t) ~= "number" or t <= 0 or t ~= t then return end
    n._deadline = core._monotonic() + t
    n._timer = core.timer(math.min(2147483647, math.max(1, math.floor(t * 1000))), function()
        n._timer = nil
        if n.alive then n:dismiss("expired") end
    end)
end

-- n:dismiss(reason): the one way a notification ends. It leaves the visible
-- list, tells the bus why if it came from the bus, and says so on its own bus
-- and the class's.
function notification.methods:dismiss(reason)
	if not self.alive then
		return
	end
	reason = reason or "user"
	self.alive = false
    cancel(self)

	local i = index_of(active, self)
	if i ~= nil then
		table.remove(active, i)
	else
		i = index_of(pending, self)
		if i ~= nil then
			table.remove(pending, i)
		end
	end

	if self.id ~= nil then
		core.notify_closed(self.id, REASON[reason] or 4)
	end
	self:emit("dismissed", reason)
	dirty(self)
end

-- An action button was pressed. ActionInvoked goes out and the notification
-- closes, which is what every notification daemon does and no protocol demands:
-- policy, and replaceable by writing your own display.
function notification.methods:invoke(key)
    if not self.alive then return end
	if self.id ~= nil then
		core.notify_action(self.id, key)
	end
	self:emit("invoked", key)
	self:dismiss("action")
end

function notification.all()
	return active
end

-- suspended is RW and pending is RO, and both are class-level, so they need a
-- metatable: object.class hands back a plain table. Unsuspending shows the
-- queue in arrival order; nothing is dropped and nothing is re-ordered.
setmetatable(notification, {
	__index = function(_, k)
		if k == "suspended" then
			return suspended
		elseif k == "pending" then
			return pending
		end
	end,
	__newindex = function(t, k, v)
		if k ~= "suspended" then
			return rawset(t, k, v)
		end
		v = v and true or false
		if v == suspended then
			return
		end
		suspended = v
		if suspended then
			return
		end
		for _, n in ipairs(pending) do
			table.insert(active, n)
			arm(n)
			core.dirty()
		end
		pending = {}
	end,
})

-- age is read, never stored: a stored one would need something to update it.
notification.getters.age = function(n)
	return os.time() - n.born
end

-- kiln.notify{}: the constructor, and the only way one is made. The DBus intake
-- calls it with the event's fields, and so does a config; there is no second
-- path and no privileged one.
function M.notify(props)
	props = props or {}

	-- Replacement is an identity question, and the answer is Lua's: an id that
	-- still names a live notification updates it in place (a volume popup is
	-- exactly this), and one that names nothing raises a new one. The properties
	-- are live, so writing them IS the update; there is nothing else to do.
	if props.id ~= nil then
		for _, n in ipairs(M.retained()) do
			if n.id == props.id then
				for k, v in pairs(props) do
					if k ~= "id" then
						n[k] = v
					end
				end
                if props._wire then
                    n.icon, n.value = props.icon, props.value
                    n.urgency = props.urgency or "normal"
                    n.timeout = props.timeout or state.theme.notification_timeout[n.urgency]
                end
                arm(n)
                dirty(n)
				return n
			end
		end
	end

	-- Everything passed in is kept, not just what this file happens to name: the
	-- DBus intake hands over the passthrough hints too (a volume popup's `value`
	-- is one), and a config's own field on a notification is nobody's business
	-- but the display's that reads it.
	seq = seq + 1
	local data = {}
	for k, v in pairs(props) do
		data[k] = v
	end
	data.seq = seq
	data.born = os.time()
	data.alive = true
	data.urgency = props.urgency or "normal"
	data.actions = props.actions or {}
	data.screen = props.screen or screen.focused
	if data.timeout == nil then
		data.timeout = state.theme.notification_timeout[data.urgency]
	end
	local n = notification.new(data)

	-- added fires before the notification is shown, which is what makes a rule a
	-- three-line listener: mutate it here and the first frame that draws it
	-- draws what you wrote.
	n:emit("added")

	if not n.alive then return n end
	table.insert(suspended and pending or active, n)
	if not suspended then
		arm(n)
	end
	dirty(n)
	return n
end

-- Any live property redraws the screen it is on. The whole update path.
for _, prop in ipairs({ "title", "message", "urgency", "icon", "actions", "value", "screen" }) do
	notification.on("property::" .. prop, dirty)
end
-- Re-arming on a timeout write is what lets a rule say n.timeout = 1.
notification.on("property::timeout", function(n) arm(n) end)
notification.on("property::urgency", function(n) arm(n) end)

function M.retained()
    local out = {}
    for _, n in ipairs(active) do out[#out+1] = n end
    for _, n in ipairs(pending) do out[#out+1] = n end
    return out
end

-- Config timers are reset by the host; service deadlines survive that reset.
function M.reload()
    for _, n in ipairs(M.retained()) do
        local deadline = n._deadline
        n._timer = nil
        n._bus:reset()
        if deadline then arm(n, math.max(.001, deadline - core._monotonic())) end
    end
end

function M.on_event(ev)
    if ev.name == "close" then
        for _, n in ipairs(M.retained()) do
            if n.id == ev.id then return n:dismiss("closed") end
        end
        return
    end
    local hints = ev.hints or {}
    local icon = ev.image or hints["image-path"] or hints.image_path
    if icon == nil and ev.app_icon and ev.app_icon ~= "" then icon = ev.app_icon end
    M.notify {
        _wire = true, id = ev.id, title = ev.summary, message = ev.body,
        app_name = ev.app_name, urgency = ev.urgency,
        timeout = ev.expire_timeout >= 0 and ev.expire_timeout / 1000 or nil,
        icon = icon, actions = ev.actions, value = hints.value, hints = hints,
    }
end

-- --------------------------------------------------------------------------
-- The default display. Public ui API only: float, band, text, image, on_press.
-- No new primitive: anything this display does, a config's replacement can do.

-- Module level, because ui.each keys its per-item store by this function's
-- identity (ui.lua): built per frame, every notification's state would be new
-- every frame.
local function notif_key(n)
	return "notification:" .. n.seq
end

function M.display(s)
	if #active == 0 then
		return
	end
	local th = state.theme
	ui.column({
		id = "notifications",
		float = {
			to = "root", band = "overlay",
			anchor = { parent = "right_top", element = "right_top" },
			-- The stack hangs off the screen's top-right, so it clears the bar
			-- by its own height; anchoring to the workarea instead would tie
			-- notifications to whatever chrome a config happens to reserve.
			offset = {
				x = -th.notification_offset,
				y = th.bar_height + th.notification_offset,
			},
		},
		gap = th.notification_gap,
	}, function()
		ui.each(active, notif_key, function(n, id)
			ui.column({
				id = id,
				w = th.notification_width,
				color = th.bg2,
				radius = th.notification_radius,
				pad = 8,
				gap = 6,
				-- Urgency is a border color, which is the whole of what urgency
				-- does here. It buys no order and no place in the stack: the
				-- column is arrival order, and a ranked one would be C's bait
				-- reimplemented in Lua.
				border = {
					width = 1,
					color = n.urgency == "critical" and th.urgent or th.muted,
				},
				-- The body dismisses. Actions are their own boxes below, and a
				-- press lands on the innermost hit, so they do not collide.
				on_press = function()
					n:dismiss("user")
				end,
			}, function()
				ui.row({ gap = 8 }, function()
					-- One icon field, already chosen: the intake ranked the three
					-- image facts C reported, because ranking them is a decision.
					if n.icon ~= nil then
						ui.image(n.icon, {
							id = id .. ":icon",
							w = 32, h = 32, radius = 2,
						})
					end
					ui.column({ w = "grow", gap = 2 }, function()
						if n.title ~= nil then
							ui.text(n.title)
						end
						if n.message ~= nil then
							-- Body text carries the notification's content, so it
							-- reads at full contrast; muted is for chrome, not copy.
							ui.text(n.message, { size = 12, color = th.fg })
						end
					end)
				end)

				-- A progress fill, from the `value` hint every volume and
				-- brightness script sends. It is a passthrough scalar, so this
				-- costs one box and no C at all.
				local value = n.value
				if type(value) == "number" then
					-- Through kiln.widgets.progress by its public name, so a
					-- config that swaps the widget governs the fill here too,
					-- the way widgets.client calls widgets.titlebar. The hint is
					-- 0..100 and the widget's contract is 0..1; the clamp is the
					-- widget's, because a client's hint is not a promise about
					-- its range.
					widgets.progress {
						id = "notification:" .. n.seq .. ":bar",
						fill_id = "notification:" .. n.seq .. ":fill",
						value = value / 100,
						w = "grow", h = 4,
					}
				end

				if #n.actions > 0 then
					ui.row({ gap = 6 }, function()
						for i, a in ipairs(n.actions) do
							ui.box({
								id = { "notification:" .. n.seq .. ":action", i },
								color = th.bg, radius = 2,
								pad = { x = 8, y = 4 },
								on_press = function()
									n:invoke(a.key)
								end,
							}, function()
								ui.text(a.label or a.key, { size = 12 })
							end)
						end
					end)
				end
			end)
		end)
	end)
end

-- M.display is what init.lua puts in kiln.defaults.notify_display, and the
-- declare tail calls whatever that holds. Replacing the whole presentation is
-- one assignment (or nil for none), with no listener bookkeeping and no
-- request::display indirection.

M.class = notification
return M
