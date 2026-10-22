
local ui = require("kiln.ui")
local state = require("kiln.state")
local popup = require("kiln.popup")

local hotkeys = {}

local COLUMNS = 3

local function grouped()
	local groups, order = {}, {}
	for _, k in ipairs(require("kiln").key.all()) do
		local g = k.group or "other"
		if groups[g] == nil then
			groups[g] = {}
			table.insert(order, g)
		end
		table.insert(groups[g], k)
	end
	return groups, order
end

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

local sheet = popup.new {
	id = "hotkeys",
	anchor = "center",
	scrim = "#00000080",
	keys = { any = "close" },
	style = function()
		local th = state.theme
		return {
			color = th.bg, radius = 8, pad = 16, gap = 12,
			border = { width = 1, color = th.accent },
		}
	end,
	fn = function(_, s)
		ui.text("keys", { color = state.theme.accent })
		local groups, order = grouped()
        ui.scroll({id="hotkeys:viewport", w="fit", h={"fit",max=math.max(24,s.height-100)}},function()
		ui.row({ gap = 24, align = { y = "top" } }, function()
			for i, col in ipairs(deal(groups, order)) do
				ui.column({ id = "hotkeys:col:" .. i, gap = 6 }, function()
					for _, g in ipairs(col) do
						declare_group(g, groups[g])
					end
				end)
			end
		end)
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

function hotkeys.declare(s)
	return sheet:declare(s)
end

setmetatable(hotkeys, {
	__index = function(_, k)
		if k == "open" then
			return sheet.open
		end
	end,
})

return hotkeys
