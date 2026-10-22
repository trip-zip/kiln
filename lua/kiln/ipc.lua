-- The Lua side of the socket, in two halves.
--
-- kiln_eval is the raw path: text in, one reply string out. C hands the
-- request across and takes the reply back, and everything between is loading
-- a chunk and joining what it answered with, which is this language's job.
--
-- kiln_ipc is the command dispatcher on top of it: a fixed verb surface plus
-- a reflection layer over the object classes, so an external tool reaches the
-- config API without hand-writing Lua. A command arrives wrapped in
-- kiln_ipc(...) rather than as bare text, because a verb is often itself
-- valid Lua: `quit` evaluates to nil and would silently succeed if the socket
-- had to guess which of the two it was reading. The wrapper makes them
-- distinct with nothing to infer.
--
-- The reply carries no terminator. The socket closes after one reply, so EOF
-- is the frame, and a payload holding a blank line cannot end it early.

local ipc = {}

-- Handlers by verb name, plus declaration order so the `commands` verb reads
-- back stable enough to generate completion from.
local handlers = {}
local order = {}

-- What each verb takes, as data. One declaration feeds three readers: the
-- usage text a caller is shown, the arity dispatch enforces before a handler
-- runs, and the candidates completion answers with. Written as three separate
-- facts they would drift, and the drift would be silent in all three
-- directions.
local specs = {}

-- Set for the length of one dispatch. Handlers stay unaware of it; only the
-- reply formatter asks.
local as_json = false

-- Which of the current dispatch's arguments arrived quoted, indexed as the
-- handler sees them. A quoted word stays a string: it is the only way to set
-- a title of "42" without it arriving as a number.
local arg_quoted = {}

-- The library table, handed over at install time. Requiring it here would
-- close a cycle, since this module is loaded from inside that one.
local kiln

-- ---------------------------------------------------------------------
-- JSON, because nothing else here produces it.

local escapes = {
	['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n",
	["\r"] = "\\r", ["\t"] = "\\t",
}

local function json_string(s)
	return '"' .. s:gsub('[%c"\\]', function(ch)
		return escapes[ch] or string.format("\\u%04x", ch:byte())
	end) .. '"'
end

-- An empty table encodes as [], which is what every list verb wants when it
-- found nothing.
local function is_array(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" then
			return false
		end
		n = n + 1
	end
	return n == #t
end

local function json(v)
	local t = type(v)
	if v == nil then
		return "null"
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "number" then
		-- Neither NaN nor an infinity has a JSON spelling.
		if v ~= v or v == math.huge or v == -math.huge then
			return "null"
		end
		return tostring(v)
	elseif t == "string" then
		return json_string(v)
	elseif t ~= "table" then
		return json_string(tostring(v))
	end
	local out = {}
	if is_array(v) then
		for i = 1, #v do
			out[i] = json(v[i])
		end
		return "[" .. table.concat(out, ",") .. "]"
	end
	-- Sorted so two replies of the same shape diff cleanly.
	local keys = {}
	for k in pairs(v) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	for i, k in ipairs(keys) do
		out[i] = json_string(tostring(k)) .. ":" .. json(v[k])
	end
	return "{" .. table.concat(out, ",") .. "}"
end

ipc.json = json

-- ---------------------------------------------------------------------
-- Parsing.

local quote_escapes = { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\" }

-- Split a command into words, honoring quotes so an argument holding a space
-- survives. The client quotes what needs it, so argument boundaries are not
-- lost the way a plain join-on-space loses them.
local function tokenize(text)
	local words, quoted = {}, {}
	local i, n = 1, #text
	while i <= n do
		if text:sub(i, i):match("%s") then
			i = i + 1
		else
			local buf, was_quoted = {}, false
			while i <= n do
				local ch = text:sub(i, i)
				if ch:match("%s") then
					break
				elseif ch == '"' or ch == "'" then
					was_quoted = true
					i = i + 1
					while i <= n do
						local c = text:sub(i, i)
						if c == ch then
							i = i + 1
							break
						elseif c == "\\" and ch == '"' and i < n then
							local nxt = text:sub(i + 1, i + 1)
							buf[#buf + 1] = quote_escapes[nxt] or nxt
							i = i + 2
						else
							buf[#buf + 1] = c
							i = i + 1
						end
					end
				else
					buf[#buf + 1] = ch
					i = i + 1
				end
			end
			words[#words + 1] = table.concat(buf)
			quoted[#words] = was_quoted
		end
	end
	return words, quoted
end

-- ---------------------------------------------------------------------
-- Objects: identity, printing, selection.

local function classes()
	return { client = client, screen = screen, tag = tag, layer = layer,
		notification = notification }
end

-- What an object answers with when it has to fit in one cell.
local function ident(o)
	if type(o) ~= "table" then
		return o
	elseif o.name ~= nil then
		return o.name
	elseif o.handle ~= nil then
		return o.handle
	end
	return tostring(o)
end

-- A property value as something printable. An object gives its identity
-- rather than a table address, a list of objects a comma list of theirs, and
-- a layout its registered name (layouts are plain functions).
local function describe(v)
	local t = type(v)
	if t ~= "table" and t ~= "function" then
		return v
	end
	-- A layout is a plain function or a callable family table, and reads as
	-- its registered name either way.
	local lname = kiln ~= nil and kiln.layout.name(v) or nil
	if lname ~= nil then
		return lname
	elseif t == "function" then
		return tostring(v)
	elseif v.name ~= nil or v.handle ~= nil then
		return ident(v)
	end
	local out = {}
	for i, e in ipairs(v) do
		out[i] = tostring(ident(e))
	end
	if #out > 0 then
		return table.concat(out, ",")
	end
	-- A plain record (a float box, a keymap) is worth answering whole.
	return v
end

local function all_of(cname)
	if cname == "client" then
		return client.all()
	elseif cname == "screen" then
		return screen.all()
	elseif cname == "layer" then
		return require("kiln.layers").all
	elseif cname == "notification" then
		return notification.all()
	elseif cname == "tag" then
		local out = {}
		for _, s in ipairs(screen.all()) do
			for _, t in ipairs(s.tags) do
				out[#out + 1] = t
			end
		end
		return out
	end
	return {}
end

-- The plain properties a class carries, as a set. The mixin keeps no schema,
-- so the live objects are the only place the answer exists.
local function live_props(cname)
	local seen = {}
	for _, o in ipairs(all_of(cname)) do
		for k in pairs(o._data) do
			seen[k] = true
		end
	end
	return seen
end

-- The settings `input` knows to list. Reaching one it does not name still
-- works; this is what a bare `input` reports and what completion offers.
local input_keys = { "keymap", "repeat_rate", "repeat_delay", "numlock",
	"tap_to_click", "natural_scrolling", "left_handed", "accel_speed",
	"accel_profile", "scroll_method", "click_method" }

-- Every registered layout, families flattened into their variants, which is
-- the set `layout set` will resolve a name against.
local function layout_names()
	local out = {}
	for _, fn in ipairs(kiln.layout.list) do
		out[#out + 1] = kiln.layout.name(fn)
		if type(fn) == "table" then
			local variants = {}
			for _, variant in pairs(fn) do
				variants[#variants + 1] = kiln.layout.name(variant)
			end
			table.sort(variants)
			for _, v in ipairs(variants) do
				out[#out + 1] = v
			end
		end
	end
	return out
end

-- Resolve <class> <selector> to a list. A selector is a handle, a name, one
-- of the keywords, or a <field>:<pattern> filter.
local function select_objects(cname, sel)
	local pool = all_of(cname)
	if sel == nil or sel == "all" then
		return pool
	end
	if sel == "focused" then
		if cname == "client" then
			return client.focus ~= nil and { client.focus } or {}
		elseif cname == "screen" then
			return screen.focused ~= nil and { screen.focused } or {}
		elseif cname == "tag" then
			local s = screen.focused
			local t = s ~= nil and s.selected_tag or nil
			return t ~= nil and { t } or {}
		end
		return {}
	end
	if cname == "client" and (sel == "previous" or sel == "mru") then
		local c = client.history.previous()
		return c ~= nil and { c } or {}
	end
	if cname == "tag" and sel == "selected" then
		local out = {}
		for _, t in ipairs(pool) do
			if t.selected then
				out[#out + 1] = t
			end
		end
		return out
	end
	local field, pat = sel:match("^([%a_][%w_]*):(.+)$")
	if field ~= nil then
		local out = {}
		for _, o in ipairs(pool) do
			local v = o[field]
			-- A field holding an object compares by that object's name, so
			-- tag:web reads the way it looks.
			if type(v) == "table" and v.name ~= nil then
				v = v.name
			end
			local ok, hit = pcall(string.match, tostring(v), pat)
			if v ~= nil and ok and hit then
				out[#out + 1] = o
			end
		end
		return out
	end
	local num = tonumber(sel)
	if num ~= nil then
		local out = {}
		for _, o in ipairs(pool) do
			if o.handle == num then
				out[#out + 1] = o
			end
		end
		if #out > 0 then
			return out
		end
	end
	local out = {}
	for _, o in ipairs(pool) do
		if o.name == sel then
			out[#out + 1] = o
		end
	end
	return out
end

-- Errors carry level 0: a reply is read by a person or a script, and a
-- chunk name with a line number in front of the message helps neither.
local function one(cname, sel)
	local list = select_objects(cname, sel)
	if #list == 0 then
		error(cname .. ": no match for '" .. tostring(sel) .. "'", 0)
	end
	return list[1]
end

-- An argument as a Lua value. A leading @ resolves to an object, which is how
-- a method taking one (a swap, a move) stays reachable without writing Lua.
local function value_at(i, word)
	if word == nil then
		return nil
	elseif arg_quoted[i] then
		return word
	elseif word:sub(1, 1) == "@" then
		local cname, sel = word:sub(2):match("^([%a_][%w_]*):(.+)$")
		if cname ~= nil then
			return one(cname, sel)
		end
	elseif word == "true" then
		return true
	elseif word == "false" then
		return false
	end
	return tonumber(word) or word
end

-- A word as a boolean. Not value_at's job: every string is truthy in Lua and
-- so is 0, so `off` and `0` would set the flag they were written to clear.
-- Anything outside the two spellings is a mistake worth naming rather than
-- quietly reading as one of them.
local truths = { on = true, ["true"] = true, ["1"] = true, yes = true,
	enable = true }
local falsehoods = { off = false, ["false"] = false, ["0"] = false, no = false,
	disable = false }

local function truthy(word, what)
	local v = truths[word] or falsehoods[word]
	if v == nil then
		error(what .. ": '" .. tostring(word) .. "' is not on or off", 0)
	end
	return v
end

-- A word as a number, named the same way, since a verb that passes nil into
-- the primitive layer reports the failure in its terms rather than its own.
local function number(word, what)
	local n = tonumber(word)
	if n == nil then
		error(what .. ": '" .. tostring(word) .. "' is not a number", 0)
	end
	return n
end

-- ---------------------------------------------------------------------
-- Reply shaping. A handler answers with a string, a record, or a
-- { cols, rows } table; nothing here needs a handler to know about --json.

local function fmt_cell(v)
	if v == nil then
		return "-"
	elseif type(v) == "boolean" then
		return v and "yes" or "no"
	elseif type(v) == "table" then
		-- Whatever reaches here is a plain record (a float box, a keymap),
		-- since describe already answers for anything with an identity. It
		-- reads as its pairs; an address would tell a reader nothing.
		local keys = {}
		for k in pairs(v) do
			keys[#keys + 1] = k
		end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local out = {}
		for i, k in ipairs(keys) do
			out[i] = tostring(k) .. "=" .. tostring(v[k])
		end
		return "{" .. table.concat(out, ",") .. "}"
	end
	return tostring(v)
end

local function fmt_rows(cols, rows)
	local width, cells = {}, {}
	for i, c in ipairs(cols) do
		width[i] = #c
	end
	for r, row in ipairs(rows) do
		cells[r] = {}
		for i, c in ipairs(cols) do
			local s = fmt_cell(row[c])
			cells[r][i] = s
			if #s > width[i] then
				width[i] = #s
			end
		end
	end
	local out = {}
	for r, row in ipairs(cells) do
		local parts = {}
		for i = 1, #cols do
			parts[i] = i == #cols and row[i]
				or row[i] .. string.rep(" ", width[i] - #row[i])
		end
		out[r] = table.concat(parts, "  ")
	end
	return table.concat(out, "\n")
end

local function fmt_record(rec)
	local keys = {}
	for k in pairs(rec) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local out = {}
	for i, k in ipairs(keys) do
		out[i] = tostring(k) .. "\t" .. fmt_cell(rec[k])
	end
	return table.concat(out, "\n")
end

local function reply_ok(result)
	if as_json then
		local payload = result
		if type(payload) == "table" and payload.cols ~= nil then
			payload = payload.rows
		end
		return json({ status = "ok", result = payload })
	end
	if result == nil then
		return "OK"
	elseif type(result) ~= "table" then
		return "OK\n" .. fmt_cell(result)
	elseif result.cols ~= nil then
		if #result.rows == 0 then
			return "OK"
		end
		return "OK\n" .. fmt_rows(result.cols, result.rows)
	end
	return "OK\n" .. fmt_record(result)
end

local function reply_error(msg)
	if as_json then
		return json({ status = "error", error = msg })
	end
	return "ERROR " .. msg
end

-- ---------------------------------------------------------------------
-- The registry.

function ipc.register(name, handler, spec)
	if handlers[name] == nil then
		order[#order + 1] = name
	end
	handlers[name] = handler
	specs[name] = spec
end

-- The argument shape, derived rather than stored: a verb cannot be shown a
-- shape it does not enforce, because the same list produces both. It also
-- leaves the verb's own name out, so a rename cannot strand a stale one inside
-- a message.
local function shape_of(name)
	local spec = specs[name]
	if spec == nil or spec.args == nil then
		return ""
	end
	local out = {}
	for i, a in ipairs(spec.args) do
		local w = a.rest and (a.name .. "...") or a.name
		out[i] = a.required and ("<" .. w .. ">") or ("[" .. w .. "]")
	end
	return table.concat(out, " ")
end

-- The verb as a caller types it: the registry keys on `tag.gap` and a terminal
-- receives `tag gap`.
local function spoken(name)
	return (name:gsub("%.", " "))
end

local function usage_of(name)
	local shape = shape_of(name)
	if shape == "" then
		return spoken(name)
	end
	return spoken(name) .. " " .. shape
end

local function required_of(name)
	local spec = specs[name]
	local n = 0
	for _, a in ipairs(spec ~= nil and spec.args or {}) do
		if a.required then
			n = n + 1
		end
	end
	return n
end

-- Two-word names win over one-word ones, so `client list` reaches client.list
-- rather than a `client` verb with a stray argument. The one place that rule
-- lives: dispatch routes by it, and help and complete have to answer for the
-- verb dispatch would actually have run. Returns the name and how many words
-- it ate, so a caller knows where the arguments start.
local function resolve(first, second)
	if first == nil then
		return nil, 0
	end
	if second ~= nil and handlers[first .. "." .. second] ~= nil then
		return first .. "." .. second, 2
	end
	if handlers[first] ~= nil then
		return first, 1
	end
	return nil, 0
end

local function dispatch(text)
	as_json = false
	arg_quoted = {}
	-- The separator is required, or `--jsonping` parses as the flag plus a
	-- verb the caller never wrote.
	local body = text:match("^%s*%-%-json%s(.*)$")
		or (text:match("^%s*%-%-json%s*$") and "")
	if body ~= nil then
		as_json = true
		text = body
	end
	local words, quoted = tokenize(text)
	if #words == 0 then
		return reply_error("empty command")
	end
	local name, span = resolve(words[1], words[2])
	if name == nil then
		local shown = words[1]
		if words[2] ~= nil then
			shown = shown .. " " .. words[2]
		end
		return reply_error("unknown command: " .. shown)
	end
	local start = span + 1
	local args, n = {}, #words - start + 1
	for i = start, #words do
		args[i - start + 1] = words[i]
		arg_quoted[i - start + 1] = quoted[i]
	end
	-- Checked here rather than in each handler, so the shape a caller is shown
	-- is the shape that was actually enforced. A verb whose requirement is
	-- conditional rather than positional declares no required args and keeps
	-- its own guard.
	if n < required_of(name) then
		return reply_error("usage: " .. usage_of(name))
	end
	return reply_ok(handlers[name](unpack(args, 1, n)))
end

-- One pcall over the whole of it, not just over the handler. unpack raises on
-- an argument list past a few thousand words and the formatters can raise on
-- what a handler answered with, and both of those are outside a handler call:
-- an error escaping here would leave the socket holding the eval layer's own
-- failure text in place of a reply in the shape the caller asked for.
function ipc.dispatch(text)
	local ok, reply = pcall(dispatch, text)
	if ok then
		return reply
	end
	return reply_error(tostring(reply))
end

-- ---------------------------------------------------------------------
-- Reflection: three verbs that reach every getter, setter, method, and
-- property the object mixin carries.
--
-- The handler installers are not reachable from here and must not become so:
-- each replaces live runtime state with no restore path, so a wrong one ends
-- the session. They live on the primitive namespace, which is deliberately
-- not a reflectable class, and stay reachable only through `eval`.

local function class_or_die(cname)
	local c = classes()[cname]
	if c == nil then
		error("no such class: " .. tostring(cname), 0)
	end
	return c
end

ipc.register("get", function(cname, sel, prop)
	class_or_die(cname)
	local list = select_objects(cname, sel)
	if #list == 0 then
		error(cname .. ": no match for '" .. tostring(sel) .. "'", 0)
	elseif #list == 1 then
		return describe(list[1][prop])
	end
	local rows = {}
	for i, o in ipairs(list) do
		rows[i] = { id = ident(o), value = describe(o[prop]) }
	end
	return { cols = { "id", "value" }, rows = rows }
end, {
	desc = "read a property off every object a selector resolves to",
	args = {
		{ name = "class", required = true, complete = "class" },
		{ name = "selector", required = true, complete = "selector" },
		{ name = "property", required = true, complete = "property" },
	},
})

ipc.register("set", function(cname, sel, prop, val)
	class_or_die(cname)
	local value = value_at(4, val)
	local list = select_objects(cname, sel)
	if #list == 0 then
		error(cname .. ": no match for '" .. tostring(sel) .. "'", 0)
	end
	for _, o in ipairs(list) do
		-- A property that reads as a boolean is written as one, so `0` and
		-- `off` clear rather than set and no flag ends up holding a number.
		if type(o[prop]) == "boolean" then
			o[prop] = truthy(val, prop)
		else
			o[prop] = value
		end
	end
	return #list .. " set"
end, {
	desc = "write a property on every object a selector resolves to",
	args = {
		{ name = "class", required = true, complete = "class" },
		{ name = "selector", required = true, complete = "selector" },
		{ name = "property", required = true, complete = "property" },
		{ name = "value", required = true },
	},
})

-- The bus methods the mixin puts on every class. They are real API and a
-- config uses all three, but they are not callable from here for the same
-- reason the handler installers are not: `on` installs a listener with no
-- name to remove it by, `off` drops one a config is relying on, and `emit`
-- runs those listeners for something that never happened. Each outlives its
-- reply with no way back, and the escape hatch for all of them is `eval`.
local uncallable = { on = true, off = true, emit = true }

ipc.register("call", function(cname, sel, method, ...)
	local class = class_or_die(cname)
	if uncallable[method] then
		error("call: '" .. method .. "' changes listeners, not state; use eval",
			0)
	end
	local fn = class.methods[method]
	if fn == nil then
		error(cname .. " has no method '" .. method .. "'", 0)
	end
	local raw = { ... }
	local n = select("#", ...)
	local args = {}
	for i = 1, n do
		args[i] = value_at(3 + i, raw[i])
	end
	local list = select_objects(cname, sel)
	if #list == 0 then
		error(cname .. ": no match for '" .. tostring(sel) .. "'", 0)
	end
	local out = {}
	for _, o in ipairs(list) do
		local r = fn(o, unpack(args, 1, n))
		if r ~= nil then
			out[#out + 1] = fmt_cell(describe(r))
		end
	end
	if #out == 0 then
		return #list .. " called"
	end
	return table.concat(out, "\n")
end, {
	desc = "invoke a method on every object a selector resolves to",
	args = {
		{ name = "class", required = true, complete = "class" },
		{ name = "selector", required = true, complete = "selector" },
		{ name = "method", required = true, complete = "method" },
		{ name = "arg", rest = true },
	},
})

-- The reflectable surface itself, so completion and a coverage check read
-- the live API instead of a hand-kept list.
ipc.register("reflect", function(cname)
	if cname == nil then
		local out = {}
		for k in pairs(classes()) do
			out[#out + 1] = k
		end
		table.sort(out)
		return table.concat(out, "\n")
	end
	local class = class_or_die(cname)
	local rows = {}
	local function add(kind, tbl)
		local keys = {}
		for k in pairs(tbl) do
			keys[#keys + 1] = k
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			rows[#rows + 1] = { kind = kind, name = k }
		end
	end
	add("method", class.methods)
	add("getter", class.getters)
	add("setter", class.setters)
	add("property", live_props(cname))
	return { cols = { "kind", "name" }, rows = rows }
end, {
	desc = "every method, getter, setter, and property a class carries",
	args = { { name = "class", complete = "class" } },
})

-- ---------------------------------------------------------------------
-- Session and process.

ipc.register("ping", function() return "pong" end,
	{ desc = "answer, so a caller can tell a live socket from a dead one" })

-- Names only, and staying that way: a script parses this, and the coverage
-- check needs an enumeration of the surface that does not come from `help`
-- itself. `help` is where a person looks.
ipc.register("commands", function()
	local out = {}
	for i, n in ipairs(order) do
		out[i] = n
	end
	table.sort(out)
	return table.concat(out, "\n")
end, { desc = "every verb this build answers to, one per line" })

-- ---------------------------------------------------------------------
-- Discovery: what a verb takes, and what a word could be.

local function help_row(name)
	local spec = specs[name] or {}
	local args = {}
	for i, a in ipairs(spec.args or {}) do
		args[i] = { name = a.name, required = a.required or false,
			rest = a.rest or false, complete = a.complete }
	end
	-- fmt_rows reads only the declared columns, so the whole usage line and
	-- the structured args ride along for a --json caller without widening the
	-- table a person reads.
	return { verb = spoken(name), shape = shape_of(name),
		desc = spec.desc or "undocumented",
		name = name, usage = usage_of(name), args = args }
end

local help_cols = { "verb", "shape", "desc" }

local function help_all(prefix)
	local rows = {}
	for _, n in ipairs(order) do
		if prefix == nil or n:sub(1, #prefix) == prefix then
			rows[#rows + 1] = help_row(n)
		end
	end
	table.sort(rows, function(a, b) return a.name < b.name end)
	return rows
end

ipc.register("help", function(a, b)
	if a == nil then
		return { cols = help_cols, rows = help_all(nil) }
	end
	local name = resolve(a, b)
	if name ~= nil then
		return { cols = help_cols, rows = { help_row(name) } }
	end
	-- A namespace is what a caller reaches for when they know the family and
	-- not the verb, and it is never a handler of its own. A second word means
	-- a verb was named, so a miss there is a miss rather than the family.
	local rows = b == nil and help_all(a .. ".") or {}
	if #rows == 0 then
		error("unknown command: " .. a .. (b ~= nil and (" " .. b) or ""), 0)
	end
	return { cols = help_cols, rows = rows }
end, {
	desc = "what a verb takes, for one verb, one namespace, or all of them",
	args = { { name = "verb", rest = true, complete = "verb" } },
})

-- Candidates by kind, each read from live state at the moment of asking. A
-- kind answering from a written list would be a second copy of a fact this
-- process already holds, and would go stale against it silently.
--
-- Each takes the same context: the class a caller already named, and the word
-- immediately before the one being completed.
local completers = {}

local function heads()
	local out = {}
	for _, n in ipairs(order) do
		out[#out + 1] = n:match("^([^.]+)%.") or n
	end
	return out
end

-- Serves both the verb a command starts with and a verb NAMED as an argument,
-- which is what `help` takes. A head already typed means the family's tails
-- are what is wanted; anything else means the heads.
completers.verb = function(ctx)
	local prefix = ctx.prev ~= nil and (ctx.prev .. ".") or nil
	if prefix == nil then
		return heads()
	end
	local out = {}
	for _, n in ipairs(order) do
		if n:sub(1, #prefix) == prefix then
			out[#out + 1] = n:sub(#prefix + 1)
		end
	end
	if #out == 0 then
		return heads()
	end
	return out
end

completers.client = function()
	local out = { "focused", "all", "previous" }
	for _, c in ipairs(client.all()) do
		out[#out + 1] = tostring(c.handle)
		if c.app_id ~= nil then
			out[#out + 1] = c.app_id
		end
	end
	return out
end

completers.tag = function()
	local out = {}
	local s = screen.focused
	for i, t in ipairs(s ~= nil and s.tags or {}) do
		out[#out + 1] = tostring(i)
		if t.name ~= nil then
			out[#out + 1] = t.name
		end
	end
	return out
end

completers.screen = function()
	local out = { "focused" }
	for _, s in ipairs(screen.all()) do
		out[#out + 1] = s.name
	end
	return out
end

completers.output = function()
	local out = {}
	for _, o in ipairs(core.output.list()) do
		out[#out + 1] = o.name
	end
	return out
end

completers.selector = function(ctx)
	local out = { "all" }
	local fn = completers[ctx.class]
	if fn then for _, v in ipairs(fn(ctx)) do out[#out + 1] = v end end
	for _, o in ipairs(all_of(ctx.class)) do out[#out + 1] = tostring(ident(o)) end
	return out
end

completers.layout = layout_names

completers.theme_key = function()
	local out = {}
	for k in pairs(kiln.theme) do
		out[#out + 1] = k
	end
	return out
end

completers.input_key = function()
	return input_keys
end

completers.class = function()
	local out = {}
	for k in pairs(classes()) do
		out[#out + 1] = k
	end
	return out
end

completers.bool = function()
	return { "on", "off", "toggle" }
end

completers.method = function(ctx)
	local cname = ctx.class
	local c = cname ~= nil and classes()[cname] or nil
	local out = {}
	for k in pairs(c ~= nil and c.methods or {}) do
		-- The three `call` refuses are not offered, so what completion
		-- suggests and what the verb accepts cannot disagree.
		if not uncallable[k] then
			out[#out + 1] = k
		end
	end
	return out
end

completers.property = function(ctx)
	local cname = ctx.class
	local c = cname ~= nil and classes()[cname] or nil
	if c == nil then
		return {}
	end
	local seen = live_props(cname)
	for k in pairs(c.getters) do
		seen[k] = true
	end
	for k in pairs(c.setters) do
		seen[k] = true
	end
	local out = {}
	for k in pairs(seen) do
		out[#out + 1] = k
	end
	return out
end

ipc.register("complete", function(...)
	local raw = { ... }
	local at = number(raw[1], "complete")
	local words = {}
	for i = 2, select("#", ...) do
		words[i - 1] = raw[i]
	end

	local name, span = resolve(words[1], words[2])

	local ctx = { prev = at > 1 and words[at - 1] or nil }

	local out
	if name == nil or at <= span then
		-- Still inside the verb's own name, which is the same question the
		-- verb completer answers for a verb named as an argument.
		out = completers.verb(ctx)
	else
		local list = specs[name] ~= nil and specs[name].args or {}
		local a = list[at - span]
		if a == nil then
			-- A trailing repeating argument keeps answering past its own slot.
			local last = list[#list]
			a = (last ~= nil and last.rest) and last or nil
		end
		local fn = a ~= nil and a.complete ~= nil and completers[a.complete]
			or nil
		if fn == nil then
			return ""
		end
		-- A class-scoped kind needs the class the caller already named.
		for i, arg in ipairs(list) do
			if arg.complete == "class" then
				ctx.class = words[span + i]
			end
		end
		out = fn(ctx)
	end

	local seen, uniq = {}, {}
	for _, w in ipairs(out) do
		if w ~= nil and w ~= "" and not seen[w] then
			seen[w] = true
			uniq[#uniq + 1] = w
		end
	end
	table.sort(uniq)
	return table.concat(uniq, "\n")
end, {
	desc = "candidates for the word at index, for a shell completion",
	args = {
		{ name = "index", required = true, complete = "number" },
		{ name = "word", rest = true },
	},
})

-- The escape hatch. Everything refused above is reachable here, on purpose:
-- the ergonomic surface stays safe by construction and arbitrary power is an
-- explicit thing to type.
ipc.register("eval", function(...)
	local code = table.concat({ ... }, " ")
	-- Not the arity check's case: one quoted empty argument is an argument.
	if code == "" then
		error("usage: " .. usage_of("eval"), 0)
	end
	local fn, err = loadstring(code)
	if fn == nil then
		error(tostring(err), 0)
	end
	local results = { pcall(fn) }
	if not results[1] then
		error(tostring(results[2]), 0)
	end
	local out = {}
	for i = 2, #results do
		out[#out + 1] = fmt_cell(describe(results[i]))
	end
	return table.concat(out, "\t")
end, {
	desc = "run Lua in the compositor, the one door to everything refused above",
	args = { { name = "lua", required = true, rest = true } },
})

ipc.register("exec", function(...)
	local cmd = table.concat({ ... }, " ")
	if cmd == "" then
		error("usage: " .. usage_of("exec"), 0)
	end
	kiln.spawn(cmd)
	return "spawned"
end, {
	desc = "spawn a command",
	args = { { name = "command", required = true, rest = true } },
})

ipc.register("quit", function()
	kiln.quit()
	return "quitting"
end, { desc = "end the session" })

ipc.register("reload", function()
	kiln.reload()
	return "reloaded"
end, { desc = "re-run the config, keeping the session up if it raises" })

ipc.register("lock", function()
	kiln.lock()
	return "locked"
end, { desc = "lock the session" })

ipc.register("unlock", function()
	if not kiln.unlock() then error("unlock: authentication required or externally locked", 0) end
	return "unlocked"
end, { desc = "unlock the session" })

ipc.register("dirty", function()
	kiln.dirty()
	return "dirty"
end, { desc = "mark every screen for a re-declare on the next frame" })

ipc.register("idle", function(ms)
	if ms == "off" or ms == "0" then
		kiln.set_idle_timeout(nil)
		return "idle timeout cleared"
	end
	local n = number(ms, "idle")
	kiln.set_idle_timeout(n)
	return "idle timeout " .. n .. "ms"
end, {
	desc = "set or clear the idle timeout, in milliseconds",
	args = { { name = "ms|off", required = true } },
})

ipc.register("inspector", function(sname)
    local s = sname ~= nil and one("screen", sname) or nil
    return kiln.inspector(s) and "on" or "off"
end, {desc="toggle the Clay debug inspector",args={{name="screen",complete="screen"}}})

ipc.register("notify", function(...)
	local words = { ... }
	local props, text = {}, {}
	local i = 1
	while i <= #words do
		local w = words[i]
		local key = w:match("^%-%-(%a+)$")
		if key ~= nil and words[i + 1] ~= nil then
			props[key] = value_at(i + 1, words[i + 1])
			i = i + 2
		else
			text[#text + 1] = w
			i = i + 1
		end
	end
	if #text > 0 then
		props.message = table.concat(text, " ")
	end
	-- Conditional, not positional: either half satisfies it, so the arity
	-- check cannot state this and the guard stays.
	if props.message == nil and props.title == nil then
		error("usage: " .. usage_of("notify")
			.. " [--title T] [--timeout N] [--urgency U]", 0)
	end
	local n = kiln.notify(props)
	return "notification " .. tostring(n.seq)
end, {
	desc = "post a notification, --title/--timeout/--urgency anywhere in it",
	args = { { name = "message", rest = true } },
})

ipc.register("screenshot", function(path, sname)
	local s = sname ~= nil and one("screen", sname) or screen.focused
	if s == nil then
		error("screenshot: no screen", 0)
	end
	local key = core.screenshot(s.name, path)
	if key == nil then
		error("screenshot: readback failed on " .. s.name, 0)
	end
	return path
end, {
	desc = "write a screen's pixels to a file",
	args = {
		{ name = "path", required = true, complete = "path" },
		{ name = "screen", complete = "screen" },
	},
})

-- ---------------------------------------------------------------------
-- Tags.

-- A tag reads by name, or by 1-based position on its screen, which is what a
-- keybinding-shaped habit reaches for first.
local function find_tag(sel, sname)
	local s = sname ~= nil and one("screen", sname) or screen.focused
	if s == nil then
		error("no screen", 0)
	end
	local idx = tonumber(sel)
	if idx ~= nil and s.tags[idx] ~= nil then
		return s.tags[idx], s
	end
	for _, t in ipairs(s.tags) do
		if t.name == sel then
			return t, s
		end
	end
	error("no tag '" .. tostring(sel) .. "' on " .. s.name, 0)
end

ipc.register("tag.list", function(sname)
	local rows = {}
	for _, s in ipairs(sname ~= nil and { one("screen", sname) } or screen.all()) do
		for i, t in ipairs(s.tags) do
			rows[#rows + 1] = {
				n = i, name = t.name or "-", screen = s.name,
				layout = describe(t.layout),
				selected = t.selected, clients = #(t.clients or {}),
			}
		end
	end
	return { cols = { "n", "name", "screen", "layout", "selected", "clients" },
		rows = rows }
end, {
	desc = "every tag, on one screen or on all of them",
	args = { { name = "screen", complete = "screen" } },
})

ipc.register("tag.current", function(sname)
	local s = sname ~= nil and one("screen", sname) or screen.focused
	if s == nil then
		error("no screen", 0)
	end
	local out = {}
	for i, t in ipairs(s.selected_tags or {}) do
		out[i] = t.name or "-"
	end
	return table.concat(out, "\n")
end, {
	desc = "the selected tags on a screen",
	args = { { name = "screen", complete = "screen" } },
})

-- A tag argument and a screen argument, which most of the family takes.
local function tag_args(desc)
	return {
		desc = desc,
		args = {
			{ name = "tag", required = true, complete = "tag" },
			{ name = "screen", complete = "screen" },
		},
	}
end

ipc.register("tag.view", function(sel, sname)
	local t = find_tag(sel, sname)
	t:view()
	return "viewing " .. (t.name or tostring(sel))
end, tag_args("select a tag, replacing the current selection"))

ipc.register("tag.toggle", function(sel, sname)
	local t = find_tag(sel, sname)
	t:toggle()
	return (t.name or tostring(sel)) .. (t.selected and " on" or " off")
end, tag_args("add or remove a tag from the current selection"))

ipc.register("tag.add", function(name, sname)
	local s = sname ~= nil and one("screen", sname) or screen.focused
	if s == nil then
		error("no screen", 0)
	end
	tag.new { name = name, screen = s }
	return "added " .. name
end, {
	desc = "create a tag on a screen",
	args = {
		{ name = "name", required = true },
		{ name = "screen", complete = "screen" },
	},
})

ipc.register("tag.delete", function(sel, sname)
	local t = find_tag(sel, sname)
	local name = t.name or tostring(sel)
	t:delete()
	return "deleted " .. name
end, tag_args("delete a tag"))

ipc.register("tag.rename", function(sel, new, sname)
	local t = find_tag(sel, sname)
	local old = t.name or tostring(sel)
	t.name = new
	return old .. " -> " .. new
end, {
	desc = "rename a tag",
	args = {
		{ name = "tag", required = true, complete = "tag" },
		{ name = "new", required = true },
		{ name = "screen", complete = "screen" },
	},
})

ipc.register("tag.screen", function(sel, sname)
	local t = find_tag(sel, sname)
	return t.screen ~= nil and t.screen.name or "-"
end, tag_args("which screen a tag lives on"))

-- The tag properties a layout reads, each a plain write, so one handler and
-- one spec serve them all.
local tag_params = {
	gap = { desc = "the workarea inset and the space between layout cells" },
	mwfact = { prop = "master_width_factor",
		desc = "the master area's share of the width, 0 to 1" },
	master_count = { desc = "how many clients the master area holds" },
	column_count = { desc = "how many columns the layout splits into" },
	carousel_width = { desc = "the focused cell's width in the carousel layout" },
}

for verb, param in pairs(tag_params) do
	local key = param.prop or verb
	ipc.register("tag." .. verb, function(sel, val, sname)
		local t = find_tag(sel, sname)
		if val == nil then
			return describe(t[key])
		end
		local n = number(val, "tag " .. verb)
		t[key] = n
		return tostring(n)
	end, {
		desc = param.desc,
		args = {
			{ name = "tag", required = true, complete = "tag" },
			{ name = "value", complete = "number" },
			{ name = "screen", complete = "screen" },
		},
	})
end

-- ---------------------------------------------------------------------
-- Layouts.

local function layout_by_name(want)
	for _, fn in ipairs(kiln.layout.list) do
		if kiln.layout.name(fn) == want then
			return fn
		end
		if type(fn) == "table" then
			for _, variant in pairs(fn) do
				if kiln.layout.name(variant) == want then
					return variant
				end
			end
		end
	end
	error("no layout '" .. tostring(want) .. "'", 0)
end

ipc.register("layout.list", function()
	return table.concat(layout_names(), "\n")
end, { desc = "every layout name, families flattened into their variants" })

ipc.register("layout.get", function(sel, sname)
	local t = sel ~= nil and find_tag(sel, sname)
		or one("tag", "focused")
	return describe(t.layout)
end, {
	desc = "the layout a tag is using",
	args = {
		{ name = "tag", complete = "tag" },
		{ name = "screen", complete = "screen" },
	},
})

ipc.register("layout.set", function(name, sel, sname)
	local t = sel ~= nil and find_tag(sel, sname) or one("tag", "focused")
	t.layout = layout_by_name(name)
	return kiln.layout.name(t.layout)
end, {
	desc = "set a tag's layout by name",
	args = {
		{ name = "name", required = true, complete = "layout" },
		{ name = "tag", complete = "tag" },
		{ name = "screen", complete = "screen" },
	},
})

ipc.register("layout.next", function(sel, sname)
	local t = sel ~= nil and find_tag(sel, sname) or one("tag", "focused")
	t.layout = kiln.layout.next(t.layout)
	return kiln.layout.name(t.layout)
end, {
	desc = "step a tag to the next layout in the ring",
	args = {
		{ name = "tag", complete = "tag" },
		{ name = "screen", complete = "screen" },
	},
})

ipc.register("layout.prev", function(sel, sname)
	local t = sel ~= nil and find_tag(sel, sname) or one("tag", "focused")
	-- No prev in the library: stepping forward around the ring lands on the
	-- entry before the current one.
	local list = kiln.layout.list
	local fn = t.layout
	for _ = 1, #list - 1 do
		fn = kiln.layout.next(fn)
	end
	t.layout = fn
	return kiln.layout.name(t.layout)
end, {
	desc = "step a tag to the previous layout in the ring",
	args = {
		{ name = "tag", complete = "tag" },
		{ name = "screen", complete = "screen" },
	},
})

-- ---------------------------------------------------------------------
-- Clients.

ipc.register("client.list", function()
	local rows = {}
	for i, c in ipairs(client.all()) do
		rows[i] = {
			handle = c.handle, app_id = c.app_id or "-",
			title = (c.title or "-"):sub(1, 40),
			tag = c.tag ~= nil and c.tag.name or "-",
			screen = c.screen ~= nil and c.screen.name or "-",
			-- floating is the flag; float is the geometry box every client
			-- carries from the moment it maps, so it says nothing here.
			state = c.minimized and "min" or c.fullscreen and "full"
				or c.maximized and "max" or c.floating and "float" or "tiled",
			focus = client.focus == c and "*" or "",
		}
	end
	return { cols = { "handle", "app_id", "title", "tag", "screen", "state",
		"focus" }, rows = rows }
end, { desc = "every client, with its tag, screen, and window state" })

-- The selector most of the client family takes, defaulting to the focused one.
local function client_args(desc, extra)
	local args = { { name = "client", complete = "client" } }
	for _, a in ipairs(extra or {}) do
		args[#args + 1] = a
	end
	return { desc = desc, args = args }
end

ipc.register("client.info", function(sel)
	local c = one("client", sel or "focused")
	local rec = {}
	for k, v in pairs(c._data) do
		rec[k] = describe(v)
	end
	rec.focused = client.focus == c
	return rec
end, client_args("every property one client carries"))

ipc.register("client.focus", function(sel)
	if sel == "next" or sel == "prev" then
		local list = client.all()
		if #list == 0 then
			error("no clients", 0)
		end
		local at = 1
		for i, c in ipairs(list) do
			if c == client.focus then
				at = i
			end
		end
		local step = sel == "next" and 1 or -1
		local c = list[(at - 1 + step) % #list + 1]
		c:focus()
		return tostring(c.handle)
	end
	local c = one("client", sel or "focused")
	c:focus()
	return tostring(c.handle)
end, client_args("focus a client, or `next` or `prev` around the list"))

-- Each applies to every client the selector resolves to, not just the first,
-- which is why the description says so.
local sweeps = {
	close = "ask every matching client to close",
	kill = "kill every matching client without asking",
	raise = "raise every matching client within its band",
	lower = "lower every matching client within its band",
}

for verb, desc in pairs(sweeps) do
	ipc.register("client." .. verb, function(sel)
		local list = select_objects("client", sel or "focused")
		if #list == 0 then
			error("client: no match for '" .. tostring(sel) .. "'", 0)
		end
		for _, c in ipairs(list) do
			c[verb](c)
		end
		return #list .. " " .. verb
	end, client_args(desc))
end

ipc.register("client.swap", function(a, b)
	local first, second = one("client", a), one("client", b)
	first:swap(second)
	return first.handle .. " <-> " .. second.handle
end, {
	desc = "swap two clients' positions in the layout",
	args = {
		{ name = "client", required = true, complete = "client" },
		{ name = "other", required = true, complete = "client" },
	},
})

ipc.register("client.movetotag", function(sel, cli, sname)
	local t = find_tag(sel, sname)
	local c = one("client", cli or "focused")
	c.tags = { t }
	return (c.app_id or tostring(c.handle)) .. " -> " .. (t.name or "?")
end, {
	desc = "move a client to one tag, replacing the tags it had",
	args = {
		{ name = "tag", required = true, complete = "tag" },
		{ name = "client", complete = "client" },
		{ name = "screen", complete = "screen" },
	},
})

ipc.register("client.toggletag", function(sel, cli, sname)
	local t = find_tag(sel, sname)
	local c = one("client", cli or "focused")
	local next_tags, had = {}, false
	for _, existing in ipairs(c.tags or {}) do
		if existing == t then
			had = true
		else
			next_tags[#next_tags + 1] = existing
		end
	end
	if not had then
		next_tags[#next_tags + 1] = t
	end
	-- A client on no tag is unreachable, so the last one off is refused.
	if #next_tags == 0 then
		error("client would be left with no tag", 0)
	end
	c.tags = next_tags
	return (t.name or "?") .. (had and " off" or " on")
end, {
	desc = "add or remove one tag from a client, keeping the rest",
	args = {
		{ name = "tag", required = true, complete = "tag" },
		{ name = "client", complete = "client" },
		{ name = "screen", complete = "screen" },
	},
})

ipc.register("client.movetoscreen", function(sname, cli)
	local s = one("screen", sname or "focused")
	local c = one("client", cli or "focused")
	c:move_to(s)
	return (c.app_id or tostring(c.handle)) .. " -> " .. s.name
end, {
	desc = "move a client to another screen's selected tag",
	args = {
		{ name = "screen", complete = "screen" },
		{ name = "client", complete = "client" },
	},
})

ipc.register("client.geometry", function(sel)
	local c = one("client", sel or "focused")
	return { x = c.x, y = c.y, width = c.width, height = c.height }
end, client_args("a client's solved box"))

ipc.register("client.visible", function()
	local rows = {}
	for _, c in ipairs(client.all()) do
		local t = c.tag
		if t ~= nil and t.selected and not c.minimized then
			rows[#rows + 1] = { handle = c.handle, app_id = c.app_id or "-",
				title = (c.title or "-"):sub(1, 40) }
		end
	end
	return { cols = { "handle", "app_id", "title" }, rows = rows }
end, { desc = "the clients on a selected tag, minimized ones excluded" })

-- The window states plus urgency, each a plain property, so one loop registers
-- the get-or-set verb for all of them. No value reads the flag back, which is
-- why the argument is optional and the description says both halves.
local client_flags = {
	floating = "whether a client floats above the tiled ones",
	fullscreen = "whether a client fills its screen over the chrome",
	maximized = "whether a client fills its workarea",
	minimized = "whether a client is withheld from the declare entirely",
	urgent = "whether a client is asking for attention",
	sticky = "whether a client follows every tag selection",
}

for prop, desc in pairs(client_flags) do
	ipc.register("client." .. prop, function(sel, val)
		local c = one("client", sel or "focused")
		if val == nil then
			return c[prop] and true or false
		end
		if val == "toggle" then
			c[prop] = not c[prop]
		else
			c[prop] = truthy(val, prop)
		end
		return c[prop] and true or false
	end, client_args(desc .. ", read or written",
		{ { name = "on|off|toggle", complete = "bool" } }))
end

-- ---------------------------------------------------------------------
-- Screens and outputs.

ipc.register("screen.list", function()
	local rows = {}
	for i, s in ipairs(screen.all()) do
		rows[i] = {
			name = s.name, width = s.width or 0, height = s.height or 0,
			scale = s.scale, tags = #(s.tags or {}),
			selected = s.selected_tag ~= nil and s.selected_tag.name or "-",
			focus = screen.focused == s and "*" or "",
		}
	end
	return { cols = { "name", "width", "height", "scale", "tags", "selected",
		"focus" }, rows = rows }
end, { desc = "every screen, with its geometry and selected tag" })

ipc.register("screen.focused", function()
	local s = screen.focused
	return s ~= nil and s.name or "-"
end, { desc = "which screen has focus" })

ipc.register("screen.count", function()
	return #screen.all()
end, { desc = "how many screens there are" })

ipc.register("screen.clients", function(sname)
	local s = one("screen", sname or "focused")
	local rows = {}
	for _, c in ipairs(client.all()) do
		if c.screen == s then
			rows[#rows + 1] = { handle = c.handle, app_id = c.app_id or "-",
				title = (c.title or "-"):sub(1, 40) }
		end
	end
	return { cols = { "handle", "app_id", "title" }, rows = rows }
end, {
	desc = "every client homed to a screen, whatever tag it is on",
	args = { { name = "screen", complete = "screen" } },
})

ipc.register("screen.focus", function(sel)
	local list = screen.all()
	if #list == 0 then
		error("no screens", 0)
	end
	local s
	if sel == "next" or sel == "prev" then
		local at = 1
		for i, candidate in ipairs(list) do
			if candidate == screen.focused then
				at = i
			end
		end
		s = list[(at - 1 + (sel == "next" and 1 or -1)) % #list + 1]
	else
		s = one("screen", sel or "focused")
	end
	screen.focused = s
	return s.name
end, {
	desc = "focus a screen, or `next` or `prev` around the list",
	args = { { name = "screen", complete = "screen" } },
})

ipc.register("screen.scale", function(sname, val)
	local s = one("screen", sname or "focused")
	if val == nil then
		return s.scale
	end
	s.scale = number(val, "screen scale")
	return s.scale
end, {
	desc = "a screen's scale factor, read or written",
	args = {
		{ name = "screen", complete = "screen" },
		{ name = "factor", complete = "number" },
	},
})

ipc.register("screen.workarea", function(sname)
	local s = one("screen", sname or "focused")
	return s.workarea
end, {
	desc = "the box left after bars and reserving layer surfaces",
	args = { { name = "screen", complete = "screen" } },
})

ipc.register("output.list", function()
	local rows = {}
	for i, o in ipairs(core.output.list()) do
		rows[i] = {
			name = o.name, width = o.width, height = o.height,
			refresh = math.floor((o.refresh or 0) / 1000),
			scale = o.scale, x = o.x, y = o.y,
			enabled = o.enabled,
		}
	end
	return { cols = { "name", "width", "height", "refresh", "scale", "x", "y",
		"enabled" }, rows = rows }
end, { desc = "every output as the hardware reports it" })

ipc.register("output.mode", function(name, w, h, hz)
	core.output.set_mode(name, number(w, "output mode"),
		number(h, "output mode"), hz ~= nil and number(hz, "output mode") or 0)
	return "ok"
end, {
	desc = "set an output's resolution, and optionally its refresh rate",
	args = {
		{ name = "output", required = true, complete = "output" },
		{ name = "width", required = true, complete = "number" },
		{ name = "height", required = true, complete = "number" },
		{ name = "hz", complete = "number" },
	},
})

ipc.register("output.scale", function(name, factor)
	core.output.set_scale(name, number(factor, "output scale"))
	return "ok"
end, {
	desc = "set an output's scale factor",
	args = {
		{ name = "output", required = true, complete = "output" },
		{ name = "factor", required = true, complete = "number" },
	},
})

ipc.register("output.position", function(name, x, y)
	core.output.set_position(name, number(x, "output position"),
		number(y, "output position"))
	return "ok"
end, {
	desc = "place an output in the layout",
	args = {
		{ name = "output", required = true, complete = "output" },
		{ name = "x", required = true, complete = "number" },
		{ name = "y", required = true, complete = "number" },
	},
})

ipc.register("output.enabled", function(name, on)
	core.output.set_enabled(name, truthy(on, "output enabled"))
	return "ok"
end, {
	desc = "turn an output on or off",
	args = {
		{ name = "output", required = true, complete = "output" },
		{ name = "on|off", required = true, complete = "bool" },
	},
})

ipc.register("output.adaptive_sync", function(name, on)
	core.output.set_adaptive_sync(name, truthy(on, "output adaptive_sync"))
	return "ok"
end, {
	desc = "turn adaptive sync on or off for an output",
	args = {
		{ name = "output", required = true, complete = "output" },
		{ name = "on|off", required = true, complete = "bool" },
	},
})

-- ---------------------------------------------------------------------
-- Input, theme, and the declarative registries.

ipc.register("input", function(key, val)
	-- Three arities, three meanings, so nothing here is a required argument.
	if key == nil then
		local rows = {}
		for _, k in ipairs(input_keys) do
			rows[#rows + 1] = { setting = k, value = describe(kiln.input[k]) }
		end
		return { cols = { "setting", "value" }, rows = rows }
	end
	if val == nil then
		return describe(kiln.input[key])
	end
	kiln.input[key] = value_at(2, val)
	return describe(kiln.input[key])
end, {
	desc = "list every input setting, or read or write one",
	args = {
		{ name = "setting", complete = "input_key" },
		{ name = "value" },
	},
})

ipc.register("theme.get", function(key)
	if key ~= nil then
		return describe(kiln.theme[key])
	end
	local rows = {}
	local keys = {}
	for k in pairs(kiln.theme) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	for i, k in ipairs(keys) do
		rows[i] = { key = k, value = describe(kiln.theme[k]) }
	end
	return { cols = { "key", "value" }, rows = rows }
end, {
	desc = "every theme key, or the value of one",
	args = { { name = "key", complete = "theme_key" } },
})

ipc.register("theme.set", function(key, val)
	kiln.theme[key] = value_at(2, val)
	kiln.dirty()
	return describe(kiln.theme[key])
end, {
	desc = "write a theme key, taking effect on the next frame",
	args = {
		{ name = "key", required = true, complete = "theme_key" },
		{ name = "value", required = true },
	},
})

ipc.register("key.list", function()
	local rows = {}
	for i, k in ipairs(kiln.key.all()) do
		rows[i] = {
			mods = type(k.mods) == "table" and table.concat(k.mods, "+")
				or fmt_cell(k.mods),
			key = fmt_cell(k.key), desc = k.desc or "-", group = k.group or "-",
		}
	end
	return { cols = { "mods", "key", "desc", "group" }, rows = rows }
end, { desc = "every key the config bound, as written" })

ipc.register("rule.list", function()
	local rows = {}
	for i, r in ipairs(kiln.rule.all()) do
		local match, props = {}, {}
		-- match and match_any are alternatives, and a spec may carry either
		-- alongside its negative clauses; all of them read as one column.
		for _, clause in ipairs({ "match", "match_any", "except", "except_any" }) do
			for k, v in pairs(r[clause] or {}) do
				match[#match + 1] = (clause == "match" and "" or clause .. ".")
					.. k .. "=" .. fmt_cell(describe(v))
			end
		end
		for k, v in pairs(r.props or {}) do
			props[#props + 1] = k .. "=" .. fmt_cell(describe(v))
		end
		table.sort(match)
		table.sort(props)
		rows[i] = { n = i, match = table.concat(match, ","),
			props = table.concat(props, ","), on = r.on ~= nil }
	end
	return { cols = { "n", "match", "props", "on" }, rows = rows }
end, { desc = "every client rule the config declared, in order" })

ipc.eval = kiln_eval

function ipc.install(library)
	kiln = library
	kiln_ipc = ipc.dispatch
	return ipc
end

return ipc
