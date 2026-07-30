-- Poll a command, keep its answer, redraw when the answer CHANGED.
--
-- This is the shape behind nearly every bar widget that shows something the
-- compositor does not know: a battery percentage, a volume, the weather, an
-- unread count. The parts were already here (spawn.watch runs it on an
-- interval, a declare reads whatever it finds), and what was missing between
-- them is the one thing neither can do alone: hold the last answer, and tell
-- when it is new.
--
-- The change test is the part worth having. A widget reading `h.value` at
-- declare needs a dirty mark when the value moves, and a poll that marked every
-- interval would keep a screen re-solving forever over an answer that never
-- changed, which is the idle cost this compositor is built to not pay.
--
-- Named kiln.poll rather than a `watch`: ui.widget already takes `watch` for
-- signal names and spawn.watch is the command loop under this one, so a third
-- meaning of the word would be the confusing one.

local spawn = require("kiln.spawn")

local poll = {}

local Poll = {}
Poll.__index = Poll

-- Stop the loop. The command already in flight is left alone (it is a process,
-- not config state), and its answer is dropped rather than applied, because a
-- caller that stopped asked for no more answers.
function Poll:stop()
	if self.watch ~= nil then
		self.watch.stop()
		self.watch = nil
	end
end

-- kiln.poll { cmd, every = seconds, parse = fn, screen = name } -> handle
--
-- parse takes the run's lines and returns the value; the default is the first
-- line, which is what a one-line command wants and what most of them are. The
-- handle carries `.value` and the raw `.lines`, both read at declare like every
-- other fact here, so a widget over this needs no update path.
function poll.new(spec)
	local cmd = spec.cmd or spec[1]
	if cmd == nil then
		error("kiln.poll needs a command", 2)
	end
	local parse = spec.parse
	local self = setmetatable({ value = nil, lines = {} }, Poll)
	-- Accumulated per run and handed over whole at the exit, so `parse` sees one
	-- answer rather than a line at a time and `.lines` is never half a run.
	local buf = {}
	self.watch = spawn.watch(cmd, spec.every or 5, {
		line = function(l)
			buf[#buf + 1] = l
		end,
		done = function()
			self.lines = buf
			buf = {}
			local v = self.lines[1]
			if parse ~= nil then
				v = parse(self.lines)
			end
			if v ~= self.value then
				self.value = v
				-- Explicitly branched rather than passing a nil through: no
				-- screen means every screen, and core.dirty says that by taking
				-- no argument at all.
				if spec.screen ~= nil then
					core.dirty(spec.screen)
				else
					core.dirty()
				end
			end
		end,
	})
	return self
end

return poll
