-- The systray registry. C owns the watcher, reads each
-- StatusNotifierItem back, and reports it as tray::item (an upsert, keyed by the
-- item's bus name) or tray::gone. Every decision downstream of those facts lives
-- here and in kiln.widgets.systray: what to draw, in what order, and how a bare
-- IconName resolves to a themed icon.
--
-- No object class and no update path, the kiln.widgets.tasklist discipline: the
-- items are a plain ordered list that widgets.systray re-reads each declare. A
-- change dirties
-- the screen and the next solve is the new tray; there is nothing to keep in
-- sync because nothing is cached that the events do not already carry.

local M = {}

-- Registration order preserved (a list), with a linear find for the upsert: a
-- tray holds a handful of items, so an index would be more machinery than facts.
local items = {}

local function find(service)
	for i, it in ipairs(items) do
		if it.service == service then
			return i, it
		end
	end
	return nil
end

function M.on_event(ev)
	if ev.name == "item" then
		local _, it = find(ev.service)
		if it == nil then
			it = { service = ev.service, _order = ev._order }
            -- Async snapshots can finish out of order; registration is the stable fact.
            local at = #items + 1
            if it._order then
                for i, current in ipairs(items) do
                    if current._order and current._order > it._order then at = i; break end
                end
            end
            table.insert(items, at, it)
		end
		-- The upsert: the same service arriving again is the same item with new
		-- facts. Any field may be nil (the item offered nothing there).
		it.id = ev.id
		it.title = ev.title
		it.status = ev.status
		it.icon = ev.icon
	elseif ev.name == "gone" then
		local i = find(ev.service)
		if i ~= nil then
			table.remove(items, i)
		end
	end
	core.dirty()
end

function M.items()
	return items
end

return M
