#!/bin/sh
# The HiDPI agreement + cursor-theme leg, the half that needs a live pointer.
#
#   scripts/hidpi-cursor.sh
#
# The headless facts live in hidpi-test.sh; this is the part that needs a live
# pointer, so it nests kiln in the wlroots X11 backend under Xvfb and drives
# xdotool. Two claims:
#
#   agreement:  the KILN_AGREE asserter stays clean at both scales. It fires
#               on every pointer motion and aborts if the scene's topmost chrome
#               leaf under the point is not the one Clay ranks there. Sweeping the
#               cursor across a rounded-bordered client, over its body, its border
#               ring and corners, and empty desktop, at scale 1 and at 1.5, is a
#               live check that the geometric border hit test and the 9-slice
#               corner tiles agree with Clay's logical hit at a fractional scale,
#               where the device raster and the logical hit path diverge in
#               density but must still name the same leaf. A divergence aborts
#               the process; the test catches a dead compositor or an
#               `agreement:` log line.
#   theme:      core.input.set_cursor_theme swaps the xcursor manager and
#               the session survives, the cursor reloading at the live scale.
#
# Needs: Xvfb, xdotool, foot, a kiln built with -Dxwayland=enabled.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-hidpi-cursor.XXXXXX)"
disp=":96"
sock="$work/kiln.sock"
log="$work/kiln.log"
kiln_pid=""
xvfb_pid=""

cleanup() {
	[ -n "$kiln_pid" ] && kill "$kiln_pid" 2>/dev/null || true
	[ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

fail=0
ev() { KILN_SOCK="$sock" "$repo/scripts/kiln-eval" "$1"; }
alive() { kill -0 "$kiln_pid" 2>/dev/null && [ -z "$(grep 'agreement:' "$log" || true)" ]; }

# Sweep the pointer across a set of logical points, scaled to the outer X server's
# device pixels. Each move samples KILN_AGREE. After the sweep, the compositor must
# still be up with no agreement divergence logged.
sweep() { # label scale nest x1,y1 x2,y2 ...
	label="$1"; scale="$2"; nest="$3"; shift 3
	for pt in "$@"; do
		lx=${pt%,*}; ly=${pt#*,}
		dx=$(awk -v v="$lx" -v s="$scale" 'BEGIN { printf "%d", v * s }')
		dy=$(awk -v v="$ly" -v s="$scale" 'BEGIN { printf "%d", v * s }')
		DISPLAY="$disp" xdotool mousemove --window "$nest" "$dx" "$dy"
		sleep 0.3
	done
	if alive; then
		printf 'ok   %s: KILN_AGREE clean across the sweep (no abort, no divergence)\n' \
			"$label"
	else
		printf 'FAIL %s: KILN_AGREE fired or the compositor died\n' "$label"
		grep 'agreement:' "$log" | head -2 || true
		fail=1
	fi
}

Xvfb "$disp" -screen 0 1280x800x24 >"$work/xvfb.log" 2>&1 &
xvfb_pid=$!
sleep 2

# Boot with the asserter on. The X11 backend gives a real pointer xdotool drives.
# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=x11 DISPLAY="$disp" KILN_AGREE=1 KILN_SOCK="$sock" \
	./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 3

nest=$(DISPLAY="$disp" xdotool search "" 2>/dev/null | tail -1)
DISPLAY="$disp" xdotool windowfocus "$nest"

# A floated terminal at a known logical box, rounded-bordered by the default theme
# (client_radius = 4), so the sweep crosses its border ring, its corner tiles, and
# its body.
ev 'core.spawn({"foot"})' >/dev/null
sleep 4
floated=$(ev 'for _, s in ipairs(screen.all()) do
  for _, t in ipairs(s.tags) do
    for _, c in ipairs(t.clients) do
      c.floating = true
      c.float = { x = 100, y = 100, width = 400, height = 300 }
      core.dirty()
      return "floated"
    end
  end
end
return "none"')
if [ "$floated" != "floated" ]; then
	printf 'FAIL no client mapped to sweep over\n'
	echo "FAIL"; exit 1
fi
sleep 2

# The sweep points, in logical coords: client body center, near each rounded
# corner (where the corner tiles overlay the body and must fall through), over the
# left border edge, over the titlebar row, and empty desktop.
pts="300,250 101,101 498,101 101,398 498,398 100,250 300,104 700,650"

# --- scale 1.
sweep "scale 1" 1 "$nest" $pts

# --- flip to a fractional scale at runtime and sweep again: the device raster is
# now 1.5x while the hit path stays logical; agreement must hold.
oname=$(ev 'return core.output.list()[1].name')
ev "core.output.set_scale('$oname', 1.5)" >/dev/null
sleep 1
ev 'for _, s in ipairs(screen.all()) do
  for _, t in ipairs(s.tags) do
    for _, c in ipairs(t.clients) do
      c.float = { x = 100, y = 100, width = 400, height = 300 }
      core.dirty()
    end
  end
end
return "reset"' >/dev/null
sleep 2
sweep "scale 1.5" 1.5 "$nest" $pts

# --- set_cursor_theme swaps the manager and the session survives, the cursor
# reloading at the live (fractional) scale.
themed=$(ev 'core.input.set_cursor_theme("Adwaita", 24)
return "themed"')
sleep 1
DISPLAY="$disp" xdotool mousemove --window "$nest" 450 375
sleep 0.5
if [ "$themed" = "themed" ] && kill -0 "$kiln_pid" 2>/dev/null; then
	printf 'ok   set_cursor_theme swapped the manager, the session survived at 1.5\n'
else
	printf 'FAIL set_cursor_theme killed the session or errored\n'
	fail=1
fi

# --- the whole run stayed clean: no agreement divergence, no tree/scene split.
#
# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's pcall,
# so this leg MUST go red under it, which is what makes the green mean anything.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	ev 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

noise=$(grep -cE "agreement:|tree==scene:|error in '|clay error" "$log" || true)
if [ "$noise" = 0 ]; then
	printf 'ok   no agreement divergence, no tree/scene split across the run\n'
else
	printf 'FAIL divergence logged (%s lines)\n' "$noise"
	grep -E "agreement:|tree==scene:|error in '|clay error" "$log" | head -3 || true
	fail=1
fi

ev 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
