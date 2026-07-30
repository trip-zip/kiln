-- The prompt widget: an inline text entry, pure Lua on Clay, holding
-- a keygrabber for its lifetime. Zero C. The caret is a box, the selection is
-- a colored box behind a text run, and the layout is Clay's row solve, so
-- nothing here measures a glyph or owns a pixel. Every launcher, rename box,
-- and run-command line is this.
--
-- Composed text needs no code here at all: ev.utf8 carries what the xkb
-- compose state resolved C-side (empty mid-sequence, the grapheme on the
-- completing key), so a dead key types an accent because the prompt inserts
-- whatever utf8 the key brought.

local ui = require("kiln.ui")
local state = require("kiln.state")
local grab = require("kiln.grab")

local prompt = {}

-- The running prompt, or nil. One at a time: the keygrabber is one claim.
prompt.active = nil

-- The default run-history, shared across prompt.run calls that do not bring
-- their own. In memory only; the compositor writes no history file.
prompt.history = {}

-- LuaJIT has no utf8 library, and the whole point of this widget is that a
-- keypress can produce a multi-byte grapheme, so every motion and delete steps
-- over codepoints, never bytes. i is a byte offset (0 .. #s).
-- A byte offset is a boundary: the byte AFTER it is the one that says whether
-- the offset splits a codepoint, so both steps test s:byte(j + 1).
local function prev_char(s, i)
	local j = i - 1
	while j > 0 and s:byte(j + 1) >= 0x80 and s:byte(j + 1) < 0xC0 do
		j = j - 1
	end
	return j >= 0 and j or 0
end

local function next_char(s, i)
	local j = i + 1
	while j < #s and s:byte(j + 1) >= 0x80 and s:byte(j + 1) < 0xC0 do
		j = j + 1
	end
	return j <= #s and j or #s
end

-- Word motion: skip the run of spaces behind (ahead of) the cursor, then the
-- run of non-spaces. Bytes are safe here: a UTF-8 continuation byte is never
-- ASCII space, so a multi-byte word is one unbroken non-space run.
local function prev_word(s, i)
	while i > 0 and s:sub(i, i):match("%s") do
		i = i - 1
	end
	while i > 0 and not s:sub(i, i):match("%s") do
		i = i - 1
	end
	return i
end

local function next_word(s, i)
	while i < #s and s:sub(i + 1, i + 1):match("%s") do
		i = i + 1
	end
	while i < #s and not s:sub(i + 1, i + 1):match("%s") do
		i = i + 1
	end
	return i
end

local p = {}
p.__index = p

local function dirty(self)
	if self.screen ~= nil then
		core.dirty(self.screen.name)
	end
end

-- The selected span as an ordered byte range, or nil when there is no
-- selection (no anchor, or an anchor the cursor sits on).
function p:selection()
	if self.anchor == nil or self.anchor == self.cursor then
		return nil
	end
	return math.min(self.anchor, self.cursor), math.max(self.anchor, self.cursor)
end

-- Move the cursor, extending the selection when shift is held and dropping it
-- otherwise. The one place the anchor is set, so no motion can leave a stale
-- one behind.
function p:move(to, extend)
	if extend then
		if self.anchor == nil then
			self.anchor = self.cursor
		end
	else
		self.anchor = nil
	end
	self.cursor = to
end

function p:delete(from, to)
	if from >= to then
		return
	end
	self.text = self.text:sub(1, from) .. self.text:sub(to + 1)
	self.cursor = from
	self.anchor = nil
	self:changed()
end

-- Drop the selection if there is one; the edit that follows applies at the
-- cursor the deletion leaves behind. Returns whether anything went.
function p:delete_selection()
	local a, b = self:selection()
	if a == nil then
		return false
	end
	self:delete(a, b)
	return true
end

function p:insert(str)
	self:delete_selection()
	self.text = self.text:sub(1, self.cursor) .. str
		.. self.text:sub(self.cursor + 1)
	self.cursor = self.cursor + #str
	self:changed()
end

function p:changed()
	-- A history walk that gets edited becomes a fresh line, exactly as a shell
	-- does: the walk position is dropped, the stashed line is not restorable.
	self.hist_i = nil
	if self.spec.changed ~= nil then
		self.spec.changed(self.text)
	end
end

-- Walk the history. dir is -1 (older) or 1 (newer). The line in progress is
-- stashed on the first step back and restored when the walk returns past the
-- newest entry.
function p:walk_history(dir)
	local h = self.hist
	if #h == 0 then
		return
	end
	local i = self.hist_i
	if i == nil then
		if dir > 0 then
			return
		end
		self.stash = self.text
		i = #h + 1
	end
	i = i + dir
	if i > #h then
		self.text = self.stash or ""
		self.hist_i = nil
	elseif i >= 1 then
		self.text = h[i]
		self.hist_i = i
	else
		return -- already at the oldest
	end
	self.cursor = #self.text
	self.anchor = nil
	if self.spec.changed ~= nil then
		self.spec.changed(self.text)
	end
end

function p:stop()
	if prompt.active == self then
		prompt.active = nil
	end
	if self.claim ~= nil then
		local claim = self.claim
		self.claim = nil
		claim:stop()
	end
	dirty(self)
end

function p:finish()
	local text = self.text
	-- History keeps one copy of a line, most recent last, and never grows a
	-- run of duplicates from someone hammering the same command.
	if text ~= "" and self.hist[#self.hist] ~= text then
		table.insert(self.hist, text)
	end
	self:stop()
	if self.spec.done ~= nil then
		self.spec.done(text)
	end
end

function p:cancel()
	self:stop()
	if self.spec.cancelled ~= nil then
		self.spec.cancelled()
	end
end

-- One queued key, routed here by the grabber claim ahead of every binding.
function p:on_key(ev)
	if not ev.pressed then
		return
	end
	local mods = ev.mods or {}
	local ctrl, shift = mods.ctrl, mods.shift
	local t, cur = self.text, self.cursor
	local key = ev.key

	if key == "Return" or key == "KP_Enter" then
		self:finish()
		return
	elseif key == "Escape" then
		self:cancel()
		return
	elseif key == "BackSpace" then
		if not self:delete_selection() then
			self:delete(ctrl and prev_word(t, cur) or prev_char(t, cur), cur)
		end
	elseif key == "Delete" then
		if not self:delete_selection() then
			self:delete(cur, ctrl and next_word(t, cur) or next_char(t, cur))
		end
	elseif key == "Left" then
		self:move(ctrl and prev_word(t, cur) or prev_char(t, cur), shift)
	elseif key == "Right" then
		self:move(ctrl and next_word(t, cur) or next_char(t, cur), shift)
	elseif key == "Home" or (ctrl and key == "a") then
		self:move(0, shift)
	elseif key == "End" or (ctrl and key == "e") then
		self:move(#t, shift)
	elseif ctrl and key == "u" then
		self:delete(0, cur)
	elseif ctrl and key == "k" then
		self:delete(cur, #t)
	elseif ctrl and key == "w" then
		self:delete(prev_word(t, cur), cur)
	elseif key == "Up" then
		self:walk_history(-1)
	elseif key == "Down" then
		self:walk_history(1)
	elseif key == "Tab" then
		if self.spec.completion ~= nil then
			local text, cursor = self.spec.completion(t, cur)
			if text ~= nil then
				self.text = text
				self.cursor = math.max(0, math.min(cursor or #text, #text))
				self.anchor = nil
			end
		end
	elseif ev.utf8 ~= nil and ev.utf8 ~= "" and not ctrl
			and not mods.alt and not mods.super
			and ev.utf8:byte(1) >= 0x20 and ev.utf8:byte(1) ~= 0x7f then
		-- The text leg, and the compose leg with it: whatever C resolved (a
		-- plain letter, or the grapheme a dead-key sequence completed into)
		-- goes in as typed. A mid-compose key carries "" and lands nowhere,
		-- which is what makes the dead key silent until it resolves.
		self:insert(ev.utf8)
	else
		return -- a modifier, a function key: nothing typed, nothing to repaint
	end
	dirty(self)
end

-- A Tab-cycle completion over a candidates function, in the spec.completion
-- shape (text, cursor) -> (text, cursor) or nil. On a fresh input it finds the
-- word behind the cursor (to whitespace, the prev_word convention), asks
-- candidates for that prefix, keeps the prefix matches, and returns the first;
-- called again on its own last output it advances the cycle, wrapping. Any input
-- it did not itself produce (an edit) resets the cycle. No matches returns nil,
-- and the Tab branch no-ops. The candidates fn is the caller's: a shell/PATH
-- source is config territory, not built here.
function prompt.completion(candidates)
	local matches, head, tail, idx, last_text, last_cur
	return function(text, cursor)
		if text ~= last_text or cursor ~= last_cur then
			local from = cursor
			while from > 0 and not text:sub(from, from):match("%s") do
				from = from - 1
			end
			local prefix = text:sub(from + 1, cursor)
			head, tail = text:sub(1, from), text:sub(cursor + 1)
			matches, idx = {}, 0
			for _, w in ipairs(candidates(prefix) or {}) do
				if w:sub(1, #prefix) == prefix then
					matches[#matches + 1] = w
				end
			end
		end
		if #matches == 0 then return nil end
		idx = idx % #matches + 1
		local word = matches[idx]
		last_text = head .. word .. tail
		last_cur = #head + #word
		return last_text, last_cur
	end
end

-- prompt.run {
--   screen = s,                 -- default screen.focused
--   label = "Run: ",
--   text = "",                  -- initial content (cursor lands at its end)
--   done = function(text) end,  -- Return
--   cancelled = function() end, -- Escape
--   changed = function(text) end,
--   completion = function(text, cursor) return text, cursor end,  -- Tab
--   history = { ... },          -- default prompt.history
-- }
--
-- Returns the prompt object; :stop() closes it with no callback. Starting one
-- while another runs stops the first (the keyboard is one claim).
function prompt.run(spec)
	spec = spec or {}
	local self = setmetatable({
		spec = spec,
		screen = spec.screen or screen.focused,
		label = spec.label or "",
		text = spec.text or "",
		anchor = nil,
		hist = spec.history or prompt.history,
		hist_i = nil,
	}, p)
	self.cursor = #self.text

	if prompt.active ~= nil then
		prompt.active:stop()
	end
	prompt.active = self
	-- The keygrabber IS the prompt's lifetime: it holds from here until stop,
	-- and while it holds no binding fires and no client sees a key.
	self.claim = grab.keygrabber {
		key = function(ev) self:on_key(ev) end,
		stopped = function()
			-- Something else claimed the keyboard (or the grabber released
			-- itself after an error). The prompt does not linger on screen
			-- without the keys it needs.
			if prompt.active == self then
				prompt.active = nil
				self.claim = nil
				dirty(self)
			end
		end,
	}
	dirty(self)
	return self
end

-- The declare: cut the text at the cursor and at the selection edges, then
-- emit the runs in order with the caret box at its cut. Clay's row solve
-- places them, so the caret sits after the exact glyphs before it with no
-- text measurement anywhere in Lua.
local function declare_text(self, th)
	local t = self.text
	local a, b = self:selection()
	local cuts = { [0] = true, [#t] = true, [self.cursor] = true }
	if a ~= nil then
		cuts[a], cuts[b] = true, true
	end
	local marks = {}
	for k in pairs(cuts) do
		table.insert(marks, k)
	end
	table.sort(marks)

	local size = th.font_size
	local function caret()
		ui.box({ w = 2, h = size + 2, color = th.accent })
	end
	for i = 1, #marks - 1 do
		local from, to = marks[i], marks[i + 1]
		if from == self.cursor then
			caret()
		end
		local run = t:sub(from + 1, to)
		if a ~= nil and from >= a and to <= b then
			ui.box({ color = th.accent }, function()
				ui.text(run, { size = size, color = th.bg })
			end)
		else
			ui.text(run, { size = size, color = th.fg })
		end
	end
	if self.cursor == #t then
		caret()
	end
end

-- Called by the runtime inside each screen's declare, after the clients: the
-- prompt is chrome in the overlay band, floating over whatever is tiled under
-- it. Nothing is declared when no prompt runs, or when it belongs to another
-- screen.
-- The prompt's width on a screen, resolved rather than handed to Clay: percent
-- sizing measures against the in-flow parent, and a float attached to the root
-- has none, so Clay would solve it to zero. The screen box is right there, so
-- this is arithmetic, not a workaround for a missing Clay.
--
-- Public because anything declared to LINE UP with the prompt needs the same
-- answer on the same frame, and the prompt's solved box cannot give it: on the
-- frame the prompt first appears there is no previous solve to read. The
-- launcher's result list is that caller.
function prompt.width(s)
	local w = state.theme.prompt_width
	if type(w) == "string" then
		local pct = w:match("^(%d+%.?%d*)%%$")
		w = pct ~= nil and math.floor(s.width * tonumber(pct) / 100) or w
	end
	return w
end

function prompt.declare(s)
	local self = prompt.active
	if self == nil or self.screen ~= s then
		return
	end
	local th = state.theme
	local w = prompt.width(s)
	ui.row({
		id = "prompt:" .. s.name,
		float = { to = "root", anchor = "top",
			offset = { x = 0, y = th.prompt_offset }, band = "overlay" },
		w = w,
		color = th.bg,
		radius = 6,
		pad = { x = 10, y = 8 },
		border = { width = 1, color = th.accent },
		align = { y = "center" },
	}, function()
		if self.label ~= "" then
			ui.text(self.label, { size = th.font_size, color = th.muted })
		end
		declare_text(self, th)
	end)
end

return prompt
