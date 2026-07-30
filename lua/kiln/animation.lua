-- Animation: easing over the true frame delta. core.tick is the
-- clock; C delivers frame::tick { screen, dt } each output frame while armed and
-- keeps that output's frame clock scheduled. Everything here is Lua: the curve,
-- the dt clamp, the duration, the per-screen bookkeeping. C holds no animation
-- state and no easing.
--
-- One value per key eases toward a target. The frame handler and the layouts
-- read animation.get(key, dflt) instead of the raw value; while any key on a
-- screen is live, that screen ticks (and so re-solves) at panel rate, and no
-- other screen is touched. When a screen's last animation finishes, its tick is
-- disarmed and it goes idle again (INV-idle holds off the animation).
local animation = {}

local anims = {}   -- key -> { screen, from, to, elapsed, dur }
local live = {}    -- screen name -> count of live animations on it
local last = {}    -- key -> the settled value, so a re-arm eases from where it is

-- Ease-out cubic: fast then settling, the layout-animation default.
local function ease(t)
	local u = 1 - t
	return 1 - u * u * u
end

-- The eased value for `key` right now: mid-animation it interpolates. Idle, the
-- caller's `dflt` (the model's current value) IS the truth, so remember it: the
-- next start eases from where the display actually sits, not a stale point. The
-- only writer of a managed value is a start(), so this idle-seed never fights an
-- unanimated change.
function animation.get(key, dflt)
	local a = anims[key]
	if a == nil then
		last[key] = dflt
		return dflt
	end
	local p = a.dur > 0 and math.min(a.elapsed / a.dur, 1) or 1
	return a.from + (a.to - a.from) * ease(p)
end

-- Ease `key` on `screen` toward `target` over `dur` seconds. `from` defaults to
-- the last value get() saw (a resize re-aims from where the display sits, no
-- jump); pass it explicitly to restart from a fixed point (the tag-switch
-- reveal, always 0->1). The first live animation on a screen arms its tick clock.
function animation.start(screen, key, target, dur, from)
	if anims[key] == nil then
		live[screen] = (live[screen] or 0) + 1
		if live[screen] == 1 then
			core.tick(screen, true)
		end
	end
	anims[key] = {
		screen = screen,
		from = from or last[key] or target,
		to = target,
		elapsed = 0,
		dur = dur or 0.15,
	}
end

-- One output frame (frame::tick). Advance every animation on this screen by the
-- true delta, clamped so a DPMS resume or a long stall cannot jump an animation
-- (the large resume dt, clamped in Lua, never in C). Finished keys settle and
-- release the screen; when the last one goes, the tick clock is disarmed.
function animation.on_tick(ev)
	local dt = math.min(ev.dt, 0.05)
	local screen = ev.screen
	for key, a in pairs(anims) do
		if a.screen == screen then
			a.elapsed = a.elapsed + dt
			if a.elapsed >= a.dur then
				last[key] = a.to
				anims[key] = nil
				live[screen] = live[screen] - 1
				if live[screen] == 0 then
					core.tick(screen, false)
				end
			end
		end
	end
	core.dirty(screen)
end

return animation
