-- A cheat sheet of every binding the config registered, read from the key
-- registry at declare.
--
-- It is a ui.popup, which is where the open state, the keyboard claim, the
-- scrim and the per-frame declare come from. What is left here is the part that
-- is actually about hotkeys: bucketing the registry into groups and dealing
-- those groups into columns.
--
-- There is no model and no update path. The sheet is state.key_specs read at
-- declare, so a config that rebinds a key and reloads gets the new sheet by
-- having a new registry, with nothing to invalidate.

local ui = require("kiln.ui")
local state = require("kiln.state")
local popup = require("kiln.popup")

local hotkeys = {}

-- Without dealing the groups into columns the sheet is one row of N groups,
-- which runs off both edges of the screen once centered. Three is what fits.
local COLUMNS = 3

-- Bucket the registry by group, first-seen order, so the columns read in
-- declaration order rather than hash order. state.key_specs rather than
-- kiln.key.all(): requiring the library here would be a cycle, and this reads
-- the registry, it does not own it.
local function grouped()
	local groups, order = {}, {}
	for _, k in ipairs(state.key_specs) do
		local g = k.group or "other"
		if groups[g] == nil then
			groups[g] = {}
			table.insert(order, g)
		end
		table.insert(groups[g], k)
	end
	return groups, order
end

-- Deal the groups into columns of roughly equal height. A group is never split:
-- its header and its rows are one thing to read.
local function deal(groups, order)
	local total = 0
	for _, g in ipairs(order) do
		total = total + #groups[g] + 1
	end
	local cols, cur, used = {}, {}, 0
	for _, g in ipairs(order) do
		if used > 0 and #cols < COLUMNS - 1 and used >= total / COLUMNS then
			cols[#cols + 1] = cur
			cur, used = {}, 0
		end
		cur[#cur + 1] = g
		used = used + #groups[g] + 1
	end
	cols[#cols + 1] = cur
	return cols
end

-- Ids are plain strings throughout: a table id's second element must be NUMERIC
-- (a string there collides at index 0 and aborts the compositor on DUPLICATE_ID),
-- and a group name and a chord are neither. k.label is the chord as the user
-- reads it, resolved through kiln.modkey at bind time, and it is unique because
-- the registry collapses rebound chords (init.lua's record).
local function declare_row(k)
	local th = state.theme
	ui.row({ gap = 8, align = { y = "center" } }, function()
		ui.box({
			id = "hkkey:" .. k.label,
			color = th.bg2, radius = 3, pad = { x = 6 },
		}, function()
			ui.text(k.label, { size = 12 })
		end)
		ui.text(k.desc or "", { size = 12, color = th.muted })
	end)
end

local function declare_group(g, keys)
	ui.box({ id = "hkgroup:" .. g, pad = { y = 2 } }, function()
		ui.text(g, { size = 12, color = state.theme.accent })
	end)
	for _, k in ipairs(keys) do
		declare_row(k)
	end
end

-- The sheet. Any key dismisses: a cheat sheet is up to be read, and the next
-- thing the user does is not reading it. The claim swallows the key either way,
-- so nothing leaks to the binding under the sheet and Escape needs no case of
-- its own.
local sheet = popup.new {
	id = "hotkeys",
	anchor = "center",
	-- Dimmed rather than invisible: the sheet is modal, and the scrim is the
	-- only thing that says so.
	scrim = "#00000080",
	keys = { any = "close" },
	style = function()
		local th = state.theme
		return {
			color = th.bg, radius = 8, pad = 16, gap = 12,
			border = { width = 1, color = th.accent },
		}
	end,
	fn = function()
		ui.text("keys", { color = state.theme.accent })
		local groups, order = grouped()
		ui.row({ gap = 24, align = { y = "top" } }, function()
			for i, col in ipairs(deal(groups, order)) do
				ui.column({ id = "hotkeys:col:" .. i, gap = 6 }, function()
					for _, g in ipairs(col) do
						declare_group(g, groups[g])
					end
				end)
			end
		end)
	end,
}

function hotkeys.show(s)
	return sheet:show(s)
end

function hotkeys.close()
	return sheet:close()
end

function hotkeys.toggle(s)
	return sheet:toggle(s)
end

-- Kept because it was public. The registry calls the popup's own declare now,
-- so nothing in the runtime comes through here.
function hotkeys.declare(s)
	return sheet:declare(s)
end

-- hotkeys.open is the screen the sheet is on, or nil. A mirror rather than a
-- field, because the popup already owns that state and two copies of it would
-- be the drift this port exists to delete.
setmetatable(hotkeys, {
	__index = function(_, k)
		if k == "open" then
			return sheet.open
		end
	end,
})

return hotkeys
