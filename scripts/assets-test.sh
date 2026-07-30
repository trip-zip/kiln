#!/bin/sh
# The asset battery. kilnrc.lua generates its own glyphs and its own wallpaper:
# an SVG built as a string in Lua, rendered to a cached PNG by rsvg-convert,
# declared through the `image = { path }` path that already exists. Zero C,
# zero new verbs; the whole capability is a recipe.
#
#   scripts/assets-test.sh
#
# What this guards, structurally (how the result LOOKS is judged by eye from
# before/after screenshots, which no battery can do):
#
#   1. A cold cache generates. Boot with an empty XDG_CACHE_HOME and the assets
#      dir fills with real PNGs: one wallpaper at the output's PHYSICAL size and
#      one file per glyph.
#   2. A warm cache forks nothing. The second boot leaves every mtime untouched,
#      which is the whole point of a content-addressed name.
#   3. The wallpaper is a live node, not just a file: `backdrop` answers a
#      core.hits probe at the desktop centre.
#   4. It is NOT the flat placeholder. core.hits returns ids and cannot say
#      whether an image decoded, so this leg is pixel-proved: the two bottom
#      corners differ (a gradient, not a fill) and a point on the logo mark's
#      centre stroke is the accent colour. The KNOWN TRAP this closes: svg
#      decodes here via glycin, a failed decode renders BLANK rather than
#      erroring, and decode is lazy until a frame. A frame is forced and pixels
#      are read; an empty box is never taken as proof of anything.
#   5. The glyph call sites are live: the layoutbox and all three titlebar
#      buttons, with clients mapped.
#   6. It degrades instead of blanking. With a failing rsvg-convert shim first on
#      PATH the compositor still boots, the generator returns nil, and the
#      backdrop falls back to a solid theme fill.
#
# The pixel legs need ImageMagick and are skipped with an info line when it is
# absent. foot is the client fixture.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-assets-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"

# Pin the config: resolution order puts
# $XDG_CONFIG_HOME/kiln/rc.lua ahead of the repo copy, so an unpinned boot runs
# whatever the user has installed rather than the config this battery asserts
# against. The cache home is isolated too, which is what makes leg 1 a real
# cold-cache run instead of a read of whatever the last session left behind.
rc="$repo/kilnrc.lua"
cfg="$work/config"
cache="$work/cache"
assets="$cache/kiln/assets"
mkdir -p "$cfg" "$cache"
kiln_pid=""

cleanup() {
	[ -n "$kiln_pid" ] && kill "$kiln_pid" 2>/dev/null || true
	pkill -f "WAYLAND_DISPLAY=$wl_disp foot" 2>/dev/null || true
	rm -rf "$work"
}
wl_disp=""
trap cleanup EXIT

fail=0
eval_kiln() { KILN_SOCK="$sock" "$repo/scripts/kiln-eval" "$1"; }
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   %s\n     (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s\n     expected %s\n     got      %s\n' "$1" "$2" "$3"
		fail=1
	fi
}
note() { printf 'info %s\n' "$1"; }

# Boot kilnrc on the headless backend against the isolated config and cache.
# No subshell: $! must be kiln itself, or cleanup kills a wrapper and orphans
# the compositor to init.
start_kiln() { # $1 = extra PATH prefix (may be empty)
	rm -f "$sock"
	cd "$repo"
	unset KILN_WALLPAPER || true
	PATH="${1:+$1:}$PATH" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
		XDG_CONFIG_HOME="$cfg" XDG_CACHE_HOME="$cache" KILN_RC="$rc" \
		KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
	kiln_pid=$!
	sleep 2
	wl_disp=$(sed -n 's/.*Running Wayland compositor on WAYLAND_DISPLAY=//p' \
		"$log" | head -1)
}
stop_kiln() {
	[ -n "$kiln_pid" ] && kill "$kiln_pid" 2>/dev/null || true
	[ -n "$kiln_pid" ] && wait "$kiln_pid" 2>/dev/null || true
	kiln_pid=""
}

# live: is this id declared RIGHT NOW?
live() { # lua-id-expr
	eval_kiln "
local s = screen.all()[1]
local id = $1
local b = core.box(id)
if b == nil then return 'absent' end
for _, h in ipairs(core.hits(s.name, b.x + b.width / 2, b.y + b.height / 2)) do
  local want = type(id) == 'table' and id[1] or id
  if h.name == want then return 'live' end
end
return 'absent'"
}

# =====================================================================
# The static half, run before the boot: the config reaches for no compositor
# primitive of its own, and carries no emdashes.

check "kilnrc reaches for no compositor primitive" "0" \
	"$(grep -c 'core\.' "$rc")"
check "no emdashes (house style)" "0" \
	"$(grep -cP '\x{2014}' "$rc" || true)"

# =====================================================================
# Boot 1: the cold cache.

check "the assets cache starts empty" "0" \
	"$(ls -1 "$assets" 2>/dev/null | wc -l | tr -d ' ')"

start_kiln ""
check "the compositor booted (cold cache)" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"

sname=$(eval_kiln 'return screen.all()[1].name')
# The wallpaper is generated at PHYSICAL pixels: s.width/s.height are logical
# (they are what the frame handler seeds and what every declaration is in), so
# the source has to be multiplied by the output scale or the panel upscales a
# smaller image. core.output.list() reports the mode, which IS that number.
phys_w=$(eval_kiln 'return core.output.list()[1].width')
phys_h=$(eval_kiln 'return core.output.list()[1].height')
log_h=$(eval_kiln 'return screen.all()[1].height')
note "output under test: $sname ${phys_w}x${phys_h} physical"

wall=$(ls -1 "$assets"/wallpaper-*.png 2>/dev/null | head -1)
if [ -n "$wall" ]; then
	check "the cold boot generated a wallpaper PNG" "PNG image data" \
		"$(file -b "$wall" 2>/dev/null | cut -d, -f1)"
	check "the wallpaper source is the output's physical size" \
		"$phys_w x $phys_h" \
		"$(file -b "$wall" 2>/dev/null | grep -o "$phys_w x $phys_h" || true)"
	check "the wallpaper name carries its inputs (content-addressed)" "yes" \
		"$(basename "$wall" | grep -q "^wallpaper-${phys_w}x${phys_h}-" \
			&& echo yes || echo no)"
else
	printf 'FAIL the cold boot generated no wallpaper PNG in %s\n' "$assets"
	fail=1
fi

glyphs=$(ls -1 "$assets"/*.png 2>/dev/null | grep -vc '/wallpaper-' || true)
if [ "${glyphs:-0}" -ge 12 ]; then
	printf 'ok   the cold boot generated the glyph set\n     (%s PNGs)\n' "$glyphs"
else
	printf 'FAIL too few glyph PNGs generated\n     expected >= 12\n     got      %s\n' \
		"${glyphs:-0}"
	fail=1
fi
bad=$(for f in "$assets"/*.png; do
	file -b "$f" 2>/dev/null | grep -q '^PNG image data' || echo "$f"
done | wc -l | tr -d ' ')
check "every generated asset is real PNG data" "0" "$bad"

# --- The wallpaper is a live node, not just a file on disk.
check "the wallpaper element is live at the desktop centre" "live" \
	"$(live '"backdrop"')"

# --- The glyph call sites, with real clients mapped so titlebars exist.
for i in 1 2; do
	WAYLAND_DISPLAY="$wl_disp" foot >"$work/foot$i.log" 2>&1 &
done
sleep 4
handle=$(eval_kiln 'local c = client.all()[1]
return c ~= nil and c.handle or -1')
check "two clients mapped for the titlebar rows" "yes" \
	"$([ "${handle:-0}" -ge 0 ] && echo yes || echo no)"
check "the layoutbox is live" "live" "$(live "\"layoutbox:$sname\"")"
check "the titlebar float button is live" "live" \
	"$(live "{ \"float\", $handle }")"
check "the titlebar maximize button is live" "live" \
	"$(live "{ \"maximize\", $handle }")"
check "the titlebar close button is live" "live" \
	"$(live "{ \"close\", $handle }")"

# --- The submenu chevron is a theme key the config points at a generated glyph.
# The stdlib renders it when set and keeps its ">" text when nil, so the wiring
# is what a battery can assert; how the glyph LOOKS is judged by eye.
check "the submenu chevron resolves to a generated glyph" "yes" \
	"$(eval_kiln 'local p = require("kiln").theme.menu_submenu_icon
if p == nil then return "no" end
local f = io.open(p, "r")
if f == nil then return "unreadable" end
f:close()
return "yes"')"
# The per-item icons ARE reachable: menu.lua already renders item.icon, so the
# config only has to generate one glyph per row and hand it over. The generated
# names are the evidence that it did.
missing=""
for g in terminal lock power restart edit chevron; do
	ls -1 "$assets/$g-"*.png >/dev/null 2>&1 || missing="$missing $g"
done
check "the menu row glyphs generated" "" "$missing"

# And the menu itself still opens over the new icon cells.
eval_kiln 'require("kiln").ui.menu {
  screen = screen.all()[1], x = 40, y = 60,
  items = {
    { "one", icon = require("kiln").theme.menu_submenu_icon,
      function() end },
    { "two", { { "sub", function() end } } },
  } }
core.dirty()' >/dev/null
sleep 0.6
check "a menu with a submenu row declares over the icon cells" "live" \
	"$(live '"menu:/2"')"
eval_kiln 'require("kiln").menu.close()
core.dirty()' >/dev/null
sleep 0.4

# --- A scale flip at a fixed mode regenerates. REGRESSION: the generator's memo
# was keyed on the physical pixel count alone, and a pure set_scale leaves that
# untouched (logical shrinks by exactly what the scale grew), so the memo hit and
# the desktop kept a wallpaper whose mark was sized for the old scale. The mark
# is 200 LOGICAL px, so it has to be re-rendered even though the panel did not
# change size. Counting files is the check the bug could not have passed.
before_wp=$(ls -1 "$assets"/wallpaper-*.png 2>/dev/null | wc -l | tr -d ' ')
eval_kiln "core.output.set_scale('$sname', 2)" >/dev/null
sleep 0.4
eval_kiln 'core.dirty()' >/dev/null
sleep 0.8
after_wp=$(ls -1 "$assets"/wallpaper-*.png 2>/dev/null | wc -l | tr -d ' ')
check "a scale flip at the same mode regenerates the wallpaper" \
	"$((before_wp + 1))" "$after_wp"
eval_kiln "core.output.set_scale('$sname', 1)" >/dev/null
sleep 0.4
eval_kiln 'core.dirty()' >/dev/null
sleep 0.6

# --- The frame. Force one, then read it: a blank decode is silent, so pixels
# are the only honest evidence that the wallpaper arrived.
eval_kiln 'core.dirty()' >/dev/null
sleep 0.6
eval_kiln "return core.screenshot('$sname', '$work/cold.png')" >/dev/null
sleep 0.5
# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's
# pcall, so this leg MUST go red under it, which is what proves the grep can see
# a swallowed handler error at all.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

noise=$(grep -cE "error in '|tree==scene:" "$log" || true)
stop_kiln

# =====================================================================
# Boot 2: the warm cache forks nothing.

before=$(find "$assets" -name '*.png' -printf '%T@ %p\n' 2>/dev/null | sort)
start_kiln ""
check "the compositor booted (warm cache)" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"
eval_kiln 'core.dirty()' >/dev/null
sleep 0.6
stop_kiln
after=$(find "$assets" -name '*.png' -printf '%T@ %p\n' 2>/dev/null | sort)
if [ "$before" = "$after" ]; then
	printf 'ok   a warm cache regenerates nothing (no mtime moved)\n'
else
	printf 'FAIL the warm boot regenerated assets\n'
	printf '%s\n' "$before" > "$work/before.txt"
	printf '%s\n' "$after" > "$work/after.txt"
	diff "$work/before.txt" "$work/after.txt" || true
	fail=1
fi

# =====================================================================
# Boot 3: rsvg-convert fails. The generator must return nil and the config must
# fall back to the solid fill, not declare a path that decodes to nothing.

shim="$work/shim"
mkdir -p "$shim"
printf '#!/bin/sh\nexit 1\n' > "$shim/rsvg-convert"
chmod +x "$shim/rsvg-convert"
cache="$work/cache-cold"
assets="$cache/kiln/assets"
mkdir -p "$cache"
start_kiln "$shim"
check "the compositor booted with a failing rsvg-convert" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"
check "no asset survived the failed render" "0" \
	"$(ls -1 "$assets"/*.png 2>/dev/null | wc -l | tr -d ' ')"
check "the wallpaper element is still live (degraded, not absent)" "live" \
	"$(live '"backdrop"')"
sname=$(eval_kiln 'return screen.all()[1].name')
eval_kiln 'core.dirty()' >/dev/null
sleep 0.6
eval_kiln "return core.screenshot('$sname', '$work/degraded.png')" >/dev/null
sleep 0.5
# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's
# pcall, so this leg MUST go red under it, which is what proves the grep can see
# a swallowed handler error at all.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

noise2=$(grep -cE "error in '|tree==scene:" "$log" || true)
stop_kiln

# =====================================================================
# The pixel legs, on the captured files now that kiln is down.

if command -v magick >/dev/null 2>&1; then
	IM=magick
elif command -v convert >/dev/null 2>&1; then
	IM=convert
else
	IM=""
fi
if [ -n "$IM" ]; then
	px() { # png x y -> RRGGBB
		"$IM" "$1" -crop "1x1+$2+$3" +repage -depth 8 \
			-format '%[hex:p{0,0}]' info: 2>/dev/null
	}
	cx=$((phys_w / 2)); cy=$((phys_h / 2))
	bl_x=4; bl_y=$((phys_h - 4))
	br_x=$((phys_w - 4)); br_y=$((phys_h - 4))
	# The logo mark is 200 LOGICAL px tall inside a 500x1100 viewBox, centred.
	# Its own centre is a gap (the two half-turn copies meet without touching),
	# so the sample follows the vertical stroke at path y=800: that is 200 path
	# units below the middle, which is 200/1100 of the mark's height in pixels.
	mark_h=$((200 * phys_h / log_h))
	mark_y=$((cy + 200 * mark_h / 1100))

	bl=$(px "$work/cold.png" "$bl_x" "$bl_y")
	br=$(px "$work/cold.png" "$br_x" "$br_y")
	ctr=$(px "$work/cold.png" "$cx" "$mark_y")
	flat=$(px "$work/degraded.png" "$cx" "$mark_y")

	note "cold frame: bottom-left=$bl bottom-right=$br mark=$ctr (at $cx,$mark_y)"
	note "degraded frame: same point=$flat"

	# A gradient, not a fill: the two bottom corners sit at different points
	# along the corner-to-corner ramp, so they cannot be equal.
	if [ -n "$bl" ] && [ "$bl" != "$br" ]; then
		printf 'ok   the wallpaper is a gradient (the two bottom corners differ)\n'
	else
		printf 'FAIL the wallpaper corners are equal; this is a flat fill\n'
		fail=1
	fi
	# The logo mark: the generated SVG strokes it in the accent colour over the
	# centre of the ramp, and nothing else is there on an empty desktop. That is
	# what says a real image decoded, not the flat placeholder.
	if [ "$ctr" = "CBA6F7" ]; then
		printf 'ok   the logo mark rendered in the accent colour\n     (%s)\n' "$ctr"
	else
		printf 'FAIL the mark stroke is not the accent colour\n     expected CBA6F7\n     got      %s\n' \
			"$ctr"
		fail=1
	fi
	# And the degraded boot is the flat theme background AT THE SAME POINT, which
	# makes the leg above non-vacuous: it is reading the generated image, not the
	# sky.
	if [ "$flat" = "1E1E2E" ]; then
		printf 'ok   the degraded boot falls back to the flat theme fill\n     (%s)\n' "$flat"
	else
		printf 'FAIL the degraded boot is not the solid fallback\n     expected 1E1E2E\n     got      %s\n' \
			"$flat"
		fail=1
	fi
else
	note "ImageMagick not installed; skipping the pixel legs"
fi

check "no bus errors, no tree/scene divergence (cold boot)" "0" "${noise:-0}"
check "no bus errors, no tree/scene divergence (degraded boot)" "0" "${noise2:-0}"

if [ "$fail" = "0" ]; then echo PASS; else echo FAIL; fi
exit "$fail"
