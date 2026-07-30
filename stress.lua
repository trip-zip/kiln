-- Performance stress harness. Run with KILN_RC=stress.lua. Declares a grid
-- of STRESS_N boxes in the workarea (no clients needed) so the per-frame timing
-- log (declare/solve/reconcile us) can be read against node count.
--
-- Tune live over IPC, then force a re-solve:
--   STRESS_N = 1000; core.dirty()
--   STRESS_COLS = 40; core.dirty()
--   STRESS_TEXT = true; core.dirty()          -- a text child per cell
--   STRESS_START()  /  STRESS_STOP()          -- continuous re-solve loop

local kiln = require("kiln")
local ui = kiln.ui
local th = kiln.theme
kiln.modkey = "alt"

STRESS_N = STRESS_N or 200
STRESS_COLS = STRESS_COLS or 24
if STRESS_TEXT == nil then STRESS_TEXT = false end
STRESS_ANIMATE = STRESS_ANIMATE or false

local frame = 0

local function grid()
	frame = frame + 1
	local n, cols = STRESS_N, STRESS_COLS
	local i = 0
	ui.column({ id = "grid", w = "grow", h = "grow", gap = 2 }, function()
		local row = 0
		while i < n do
			ui.row({ id = { "row", row }, gap = 2 }, function()
				for _ = 1, cols do
					if i >= n then break end
					i = i + 1
					if STRESS_RAW then
						-- Bypass ui.lua's to_declaration entirely: measures the
						-- C marshalling + open/close alone, no friendly parsing.
						core.open({ id = { "cell", i },
							layout = { sizing = { width = 40, height = 22 } } })
						core.close()
					elseif STRESS_BARE then
						-- id + size only: isolates fixed per-element overhead
						-- from the per-optional-field marshalling cost.
						ui.box({ id = { "cell", i }, w = 40, h = 22 })
					else
						-- Colour shifts with the frame when animating, so the
						-- reconcile does real rect mutations, not just a diff.
						local s = STRESS_ANIMATE and ((i + frame) % 180 + 40) or 90
						ui.box({
							id = { "cell", i },
							w = 40, h = 22, radius = 3,
							align = STRESS_TEXT and "center" or nil,
							color = { r = s, g = 70, b = 150, a = 255 },
						}, STRESS_TEXT and function()
							ui.text(tostring(i), { size = 10 })
						end or nil)
					end
				end
			end)
			row = row + 1
		end
	end)
end

-- Continuous re-solve loop (the sustained / animation hot path). The frame
-- callback gates it to the output refresh rate; core.dirty just re-arms it.
function STRESS_START()
	STRESS_ANIMATE = true
	local function tick()
		if not STRESS_ANIMATE then return end
		core.dirty()
		core.timer(1, tick)
	end
	tick()
end

function STRESS_STOP()
	STRESS_ANIMATE = false
end

screen.on("added", function(s)
	-- A layout that ignores clients and declares the grid instead.
	tag.new { name = "stress", screen = s, layout = function() grid() end }
	s.tags[1]:view()
	ui.bar(s, { edge = "top", height = 26, color = th.bg }, function()
		ui.text("STRESS  n=" .. STRESS_N .. "  cols=" .. STRESS_COLS ..
			"  text=" .. tostring(STRESS_TEXT) ..
			"  anim=" .. tostring(STRESS_ANIMATE) ..
			"   (mod+Escape quits, mod+Return terminal)")
	end)
end)

-- Escape hatches so a TTY run is never a trap: always able to quit and spawn.
kiln.key { mods = { "mod" }, key = "Escape", press = kiln.quit }
kiln.key { mods = { "mod" }, key = "Return",
	press = function() kiln.spawn(os.getenv("TERMINAL") or "ghostty") end }
