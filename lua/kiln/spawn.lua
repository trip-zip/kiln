-- Async spawn: the Lua leg over core.spawn_pipe. C hands up raw spawn::out
-- chunks and one spawn::exit; the line split, the stderr split, and the
-- watch re-arm all live here, on the origin queue.

local spawn = {}

-- pipes[id] = { buf = "", cbs = { on_line, on_err, on_exit } }
local pipes = {}

-- Every live watch, so a reload can stop them all.
local watches = {}

-- spawn.pipe(cmd, cbs) -> id. cbs may carry on_line (stdout, one call per complete
-- line), on_err (stderr, raw chunk, no split), on_exit(code).
function spawn.pipe(cmd, cbs)
	local id = core.spawn_pipe(cmd)
	pipes[id] = { buf = "", cbs = cbs or {} }
	return id
end

-- Called by init.lua's dispatcher for every ev.class == "spawn".
function spawn.on_event(ev)
	local p = pipes[ev.id]
	if p == nil then
		return
	end
	if ev.name == "out" then
		if ev.fd == 2 then
			-- Two fds, two facts: stderr is a raw chunk, config's call to split.
			if p.cbs.on_err then
				p.cbs.on_err(ev.data)
			end
			return
		end
		p.buf = p.buf .. ev.data
		while true do
			local line, rest = p.buf:match("^(.-)\n(.*)$")
			if line == nil then
				break
			end
			p.buf = rest
			if p.cbs.on_line then
				p.cbs.on_line(line)
			end
		end
	elseif ev.name == "exit" then
		-- Flush a trailing unterminated line, then exit, then drop the registry.
		if p.buf ~= "" and p.cbs.on_line then
			p.cbs.on_line(p.buf)
		end
		if p.cbs.on_exit then
			p.cbs.on_exit(ev.code)
		end
		pipes[ev.id] = nil
	end
end

-- spawn.watch(cmd, interval, cb) -> handle. Runs cmd, feeds
-- each line to cb, and re-arms interval SECONDS after it exits (core.timer is ms
-- and one-shot). handle:stop() drops the re-arm so a reload can cancel a watch
-- instead of doubling it.
--
-- cb is a function taking each line, or a table { line, done } when the caller
-- needs the RUN boundary as well: a command answering in three lines is one
-- answer, and a caller assembling it cannot tell from the lines alone which was
-- the last. done fires at the exit, before the re-arm, and not at all once the
-- watch is stopped, since a stopped watch is a caller that asked for no more
-- answers.
--
-- The re-arm is only as dependable as the exit that drives it, which is why C
-- learns of a child's exit from a pidfd and not from SIGCHLD: a watch stops
-- forever the first time an exit goes missing, and it stops silently.
-- scripts/poll-test.sh is the standing test, and it runs the loop long enough
-- to re-arm many times rather than once.
function spawn.watch(cmd, interval, cb)
	local line, done
	if type(cb) == "table" then
		line, done = cb.line, cb.done
	else
		line = cb
	end
	local handle = { dead = false }
	watches[#watches + 1] = handle
	local function run()
		if handle.dead then
			return
		end
		spawn.pipe(cmd, {
			on_line = line,
			on_exit = function(code)
				if handle.dead then
					return
				end
				if done ~= nil then
					done(code)
				end
				core.timer(interval * 1000, run)
			end,
		})
	end
	function handle.stop()
		handle.dead = true
	end
	run()
	return handle
end

-- Drop the config's async state on reload. The watches stop re-arming, so
-- the re-run config's watches replace them instead of doubling them; the pipe
-- callbacks go with them, since they close over the old config's widgets. The
-- CHILDREN are left alone: a running process is not config state, and its exit
-- now lands on a pipe nobody is registered for, which on_event already no-ops.
-- A one-shot timer already in flight is the same story, and is why the timer for
-- a re-arming loop belongs in a watch.
function spawn.reset()
	for _, handle in ipairs(watches) do
		handle.stop()
	end
	watches = {}
	pipes = {}
end

return spawn
