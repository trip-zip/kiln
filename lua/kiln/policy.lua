-- Registries own policy; the native consume set only decides seat forwarding.
local Bus = require('kiln.bus')
local object = require('kiln.object')
return function(kiln, by_name)
local state = {keys={}, key_specs={}, buttons={}, rules={}}
local function report(name, err) pcall(Bus.on_error, name, err) end
local mod_order = { "ctrl", "alt", "shift", "super" }

-- The chord name for a set of held modifiers, canonical order. has is
-- any table truthy at the modifier names ("ctrl".."super"), so both a
-- resolved spec set and an origin event's ev.mods serialize the same.
local function mods_prefix(has)
	local s = ""
	for _, m in ipairs(mod_order) do
		if has[m] then
			s = s .. m .. "+"
		end
	end
	return s
end

-- A modifier spec ("mod" resolving to kiln.modkey) as a set keyed by
-- canonical name. Shared by key chords and button chords so both agree on
-- what a modifier means.
local function resolve_mods(mods)
	local set = {}
	for _, m in ipairs(mods or {}) do
		set[m == "mod" and kiln.modkey or m] = true
	end
	return set
end

-- Returns the chord string and the resolved modifier list (with "mod"
-- expanded to kiln.modkey), the form core.set_key_bindings wants.
local function chord_name(mods, keyname)
	local set = resolve_mods(mods)
	local list = {}
	for _, m in ipairs(mod_order) do
		if set[m] then
			table.insert(list, m)
		end
	end
	return mods_prefix(set) .. keyname, list
end

-- The whole consume set, replaced wholesale. A chord with only a release
-- handler must be in here too: C consumes on the PRESS edge and swallows the
-- matching release, so a chord C does not know about would leak its press to
-- the focused client and never reach the release handler.
local function sync_key_bindings()
	local bindings = {}
	for _, b in pairs(state.keys) do
		table.insert(bindings, { mods = b.mods, key = b.key })
	end
	core.set_key_bindings(bindings)
end

-- Returns the chord it bound, which is what lets the registry mirror dispatch.
local function bind(spec, keyname, press, release)
	local chord, mods = chord_name(spec.mods or {}, keyname)
	state.keys[chord] = {
		press = press, release = release, mods = mods, key = keyname,
	}
	return chord
end

-- A range expands into one BINDING per value, and the handler is passed the
-- value: digits as numbers (the numrow-indexing case keygroups existed for),
-- letters as letters. It stays ONE REGISTRY ENTRY, though: a hotkeys sheet
-- wants a row reading "1-9  view tag", not nine rows reading "1".."9".
local function expand(spec)
	local chords = {}
	local from, to = tostring(spec.key):match("^(%d)%-(%d)$")
	if from ~= nil then
		for n = tonumber(from), tonumber(to) do
			local i = n
			chords[#chords + 1] = bind(spec, tostring(n),
				spec.press and function() spec.press(i) end,
				spec.release and function() spec.release(i) end)
		end
		return chords
	end
	from, to = tostring(spec.key):match("^(%a)%-(%a)$")
	if from ~= nil and #from == 1 and #to == 1 then
		for b = string.byte(from), string.byte(to) do
			local l = string.char(b)
			chords[#chords + 1] = bind(spec, l,
				spec.press and function() spec.press(l) end,
				spec.release and function() spec.release(l) end)
		end
		return chords
	end
	-- A "-" that matched neither range form is not a key name either: no keysym
	-- name contains one. "1-10" is the case that looks like it should work, and
	-- widening the pattern would not save it, since the numrow's tenth key is
	-- named "0" and there is no "10" to bind. Refused HERE, before anything is
	-- written: C rejects the unknown name too, but only after state.keys and the
	-- registry have already taken a row that can never dispatch.
	if tostring(spec.key):find("%-") then
		error("kiln.key: not a key name, and not a single-digit or "
			.. "single-letter range: " .. tostring(spec.key), 3)
	end
	chords[1] = bind(spec, spec.key, spec.press, spec.release)
	return chords
end

-- The registry must MIRROR DISPATCH, or a cheat sheet built from it advertises
-- bindings that cannot fire: bind() overwrites state.keys, so a rebound chord
-- replaces the old handler, while appending here unconditionally would keep both
-- rows. A call whose chords cover an existing row's chords replaces that row in
-- place, so declaration order (which is the sheet's column order) survives a
-- rebind, and chord labels stay unique, which the sheet's element ids depend
-- on.
local function record(spec, chords)
	local set = {}
	for _, c in ipairs(chords) do
		set[c] = true
	end
	local row = {
		mods = spec.mods or {}, key = spec.key,
		desc = spec.desc, group = spec.group,
		-- The chord as a user reads it, resolved through kiln.modkey at BIND
		-- time, which is when "mod" means anything. Resolving it at read time is
		-- only possible above this layer, where kiln.modkey is visible, so every
		-- consumer had to compute it by hand.
		label = mods_prefix(resolve_mods(spec.mods)) .. tostring(spec.key),
		chords = chords,
	}
	for i, k in ipairs(state.key_specs) do
		local covered, overlap = true, false
		for _, c in ipairs(k.chords) do
			if set[c] then
				overlap = true
			else
				covered = false
			end
		end
		if covered then
			state.key_specs[i] = row
			return
		elseif overlap then
			-- A chord taken out of the MIDDLE of a range is not a registry row:
			-- the range row would go on advertising a chord that now dispatches
			-- somewhere else, and splitting the row into the parts that still
			-- hold is not something the config wrote. Reported rather than
			-- silently mis-advertised.
	        report("kiln.key", "chord " .. chords[1]
				.. " overrides part of the range " .. tostring(k.key)
				.. "; the sheet will list both")
		end
	end
	table.insert(state.key_specs, row)
end

-- kiln.key is a callable table so the registry can hang off it.
kiln.key = setmetatable({}, {
	__call = function(_, spec)
		-- The registry: one entry per call, NOT per expanded chord, so a range
		-- reads back as the range the config wrote. This is the whole of what the
		-- hotkeys sheet consumes, and the only reason desc and group exist.
        local old_keys, old_specs = state.keys, state.key_specs
        state.keys, state.key_specs = {}, {unpack(old_specs)}
        for k, v in pairs(old_keys) do state.keys[k] = v end
        local saved = {}
        for k, v in pairs(spec) do saved[k] = v end
        saved.mods = {unpack(spec.mods or {})}
        local ok, err = pcall(function()
            record(saved, expand(saved))
            sync_key_bindings()
        end)
        if not ok then
            state.keys, state.key_specs = old_keys, old_specs
            error(err, 2)
        end
	end,
})

-- The registry, in declaration order. A copy: a sheet reads it, it does not own
-- it. `chords` stays internal, being the reconciliation's own bookkeeping.
function kiln.key.all()
	local out = {}
	for i, k in ipairs(state.key_specs) do
		out[i] = {
			mods = {unpack(k.mods)}, key = k.key, desc = k.desc, group = k.group,
			label = k.label,
		}
	end
	return out
end

-- Reset every binding, for hot-reload. sync_key_bindings already replaces the
-- whole consume set in C, so this needs no C at all.
function kiln.key.clear()
	state.keys = {}
	state.key_specs = {}
	sync_key_bindings()
end

kiln.button = setmetatable({}, {
	__call = function(_, spec)
        local saved = {}
        for k, v in pairs(spec) do saved[k] = v end
        saved.mods = {unpack(spec.mods or {})}
        table.insert(state.buttons, saved)
	end,
})

function kiln.button.clear()
	state.buttons = {}
end

function kiln.focused(fn)
	return function(...)
		if client.focus ~= nil then
			return fn(client.focus, ...)
		end
	end
end

kiln.rule = setmetatable({}, {
	__call = function(_, spec)
		table.insert(state.rules, spec)
	end,
})

function kiln.rule.all() return {unpack(state.rules)} end
function kiln.rule.clear()
	state.rules = {}
end

-- Does one string field hit? Values are LUA PATTERNS, and a list means any-of,
-- so a single value and a list of one behave the same.
local function field_hit(value, pats)
	if value == nil or pats == nil then
		return false
	end
	if type(pats) ~= "table" then
		pats = { pats }
	end
	for _, pat in ipairs(pats) do
		if value:match(pat) then
			return true
		end
	end
	return false
end

-- One matcher clause against a client. Fields: app (vs app_id), class and
-- instance (X11 WM_CLASS, where there is no app id), title, role (X11
-- WM_WINDOW_ROLE), dialog (a boolean: does it have a parent), and fn, the
-- general escape into plain Lua. fn is a matcher, not a hatch: it reads the same
-- public object every other field does.
--
-- all = true requires every present field to hit (`match`); all = false requires
-- any one of them (`match_any`).
local function clause_hit(clause, c, all)
	local tested, hit = false, false
	local function test(ok)
		tested = true
		if ok then
			hit = true
		elseif all then
			hit = false
		end
		return not (all and not ok)
	end

	if clause.app ~= nil and not test(field_hit(c.app_id, clause.app)) then
		return false
	end
	if clause.class ~= nil and not test(field_hit(c.class, clause.class)) then
		return false
	end
	if clause.instance ~= nil and
			not test(field_hit(c.instance, clause.instance)) then
		return false
	end
	if clause.title ~= nil and not test(field_hit(c.title, clause.title)) then
		return false
	end
	-- role is X11's WM_WINDOW_ROLE, the identity beyond the class (a "pop-up"
	-- vs a "browser" of the same app). A Lua pattern like every match value, so
	-- a literal dash needs escaping: match = { role = "pop%-up" }.
	if clause.role ~= nil and not test(field_hit(c.role, clause.role)) then
		return false
	end
	if clause.dialog ~= nil and
			not test(clause.dialog == (c.parent ~= nil)) then
		return false
	end
	if clause.fn ~= nil and not test(clause.fn(c) and true or false) then
		return false
	end
	return tested and hit
end

-- match (all fields must hit) and match_any (any field hits) select; except and
-- except_any veto. A spec with no selector at all matches nothing, not
-- everything: a rule that fires on every client is a mistake worth making loud.
local function rule_matches(spec, c)
	if spec.except ~= nil and clause_hit(spec.except, c, true) then
		return false
	end
	if spec.except_any ~= nil and clause_hit(spec.except_any, c, false) then
		return false
	end
	if spec.match ~= nil and clause_hit(spec.match, c, true) then
		return true
	end
	if spec.match_any ~= nil and clause_hit(spec.match_any, c, false) then
		return true
	end
	return false
end

-- Rules apply in declaration order on map, before the client takes focus; a
-- later rule overrides an earlier one's props.
--
-- The specials are not property writes and are applied first: `tag` and `screen`
-- name a home (by name or by object), and `focus = false` is a decision the map
-- path consumes rather than state anyone stores. Everything else IS a plain
-- property write, and order-independent by construction: each one is read at
-- declare, so no two of them can race (a Lua table has no order to honor
-- anyway).
local function tag_named(name, s)
	for _, scr in ipairs(s ~= nil and { s } or screen.all()) do
		for _, t in ipairs(scr.tags) do
			if t.name == name then
				return t
			end
		end
	end
	return nil
end

local function apply_rules(c)
    for _, spec in ipairs({unpack(state.rules)}) do
        local ok, err = pcall(function()
        if rule_matches(spec, c) then
			local props = spec.props or {}
			local s = props.screen
			if type(s) == "string" then
				s = by_name(s)
			end
			local t = props.tag
			if type(t) == "string" then
				t = tag_named(t, s)
			end
			if t ~= nil then
				c.tags = { t }
			elseif s ~= nil and s.selected_tag ~= nil then
				c.tags = { s.selected_tag }
			end
			if props.focus == false then
				c.no_focus = true
			end
			for k, v in pairs(props) do
				if k ~= "tag" and k ~= "screen" and k ~= "focus" then
					c[k] = v
				end
			end
			if spec.on ~= nil then
				spec.on(c)
			end
		end
        end)
        if not ok then report('rule', err) end
	end
end


local function on_key(ev)
    local chord = mods_prefix(ev.mods or {}) .. ev.key
    local binding = state.keys[chord]
    if not binding then return end
    local fn
    if ev.pressed then fn = binding.press else fn = binding.release end
    if fn then
        local ok, err = pcall(fn)
        if not ok then report('key ' .. chord, err) end
    end
end
local function on_button(ev)
    if not ev.screen or (ev.surface and not ev.client) then return end
    local c = object.lookup(ev.client)
    if ev.client and (not c or not c.mapped) then return end
    local where = c and 'client' or 'root'
    for _, b in ipairs({unpack(state.buttons)}) do
        if b.button == ev.button and (b.on or 'client') == where
            and mods_prefix(resolve_mods(b.mods)) == mods_prefix(ev.mods or {}) then
            local fn
            if ev.pressed then fn = b.press else fn = b.release end
            if fn then
                local ok, err = pcall(fn, c)
                if not ok then report('button ' .. tostring(ev.button), err) end
                return
            end
        end
    end
    if c and ev.pressed then c:focus() end
end
return {key=on_key, button=on_button, rules=apply_rules}
end
