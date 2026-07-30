-- Cache-soak config. Run with KILN_RC=scripts/soak-cache.lua, then
-- drive the globals over IPC and re-solve:
--
--   SOAK_MODE = "images"; SOAK_N = 100; core.dirty()   -- decode cache load
--   SOAK_MODE = "text"; SOAK_ROUND = 2; core.dirty()   -- distinct rasters
--   SOAK_MODE = "none"; core.dirty()                   -- drop everything
--
-- The full-height bar is the declare surface: no clients needed, every leaf
-- is chrome. scripts/cache-soak.sh drives the whole assert sequence.

local kiln = require("kiln")
local ui = kiln.ui

SOAK_MODE = SOAK_MODE or "none"
SOAK_N = SOAK_N or 0
SOAK_DIR = SOAK_DIR or "/tmp/kiln-soak"
SOAK_ROUND = SOAK_ROUND or 1

local PER_ROW = 16

screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()

	ui.bar(s, { edge = "top", height = 680 }, function()
		ui.column({ id = "soak-grid", gap = 2 }, function()
			local i = 0
			local row = 0
			while i < SOAK_N and SOAK_MODE ~= "none" do
				ui.row({ id = { "soak-row", row }, gap = 2 }, function()
					for _ = 1, PER_ROW do
						if i >= SOAK_N then break end
						i = i + 1
						if SOAK_MODE == "images" then
							ui.image(SOAK_DIR .. "/img-" .. i .. ".ppm",
								{ w = 24, h = 24 })
						else
							ui.text("soak-" .. SOAK_ROUND .. "-" .. i)
						end
					end
				end)
				row = row + 1
			end
		end)
	end)
end)
