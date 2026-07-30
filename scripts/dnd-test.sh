#!/bin/sh
# The DnD battery: a real drag starts, the icon rides the cursor band, and kiln
# emits drag::start / drag::end. The drag grab is wlroots' own; C only validates
# the start serial the protocol demands, parents the icon into the cursor band,
# and reports the two informational events.
#
#   scripts/dnd-test.sh
#
# Getting a VALID start serial forces real pointer input (button held, serial
# matching a live pointer grab on the origin surface), so this follows the
# cursor-test / pointer-test pattern: kiln nested under the wlroots X11 backend
# inside Xvfb, driven by xdotool. The observed client is scripts/wl-drag, a
# fixture that maps a toplevel and, on the first pointer button press, calls
# wl_data_device.start_drag with that serial. The compositor-side facts (the two
# events) are read back over the IPC eval socket, not restated.
#
# THE ASSERTION: a plain button-1 press over the fixture starts the drag
# (drag::start, DRAG_STATE = "in"); the release is a drop that ends it
# (drag::end, DRAG_STATE = "out"), one drag::end for the drop. No target, no
# action, no drop policy is asserted, because C arbitrates none: choosing a
# target or an action belongs to the clients and the config, not here.
#
# The live leg (a file dragged between two GTK apps with the icon riding the
# cursor) stays a manual check; this is the automated, re-runnable half.
#
# Needs: Xvfb, xdotool (same as cursor-test); no xwayland build option (the
# fixture is a pure Wayland client).
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-dnd-test.XXXXXX)"
disp=":96"
sock="$work/kiln.sock"
log="$work/kiln.log"
rc="$work/rc.lua"
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
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   %s (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s: expected %s got %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

# The rc under test: one tiled tag per screen (so the single fixture fills the
# nest and sits under the cursor), plus a recorder over the informational drag
# signals. DRAG_STATE is the live in/out; the counters prove exactly one edge each.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
end)
DRAG = 0
DRAG_END = 0
DRAG_STATE = "out"
drag.on("start", function() DRAG = DRAG + 1; DRAG_STATE = "in" end)
drag.on("end",   function() DRAG_END = DRAG_END + 1; DRAG_STATE = "out" end)
EOF

Xvfb "$disp" -screen 0 1280x800x24 >"$work/xvfb.log" 2>&1 &
xvfb_pid=$!
sleep 2

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=x11 DISPLAY="$disp" KILN_RC="$rc" KILN_SOCK="$sock" \
	./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 3

check "the compositor booted" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"

nest=$(DISPLAY="$disp" xdotool search "" 2>/dev/null | tail -1)
check "the nest window exists" "yes" "$([ -n "$nest" ] && echo yes || echo no)"
DISPLAY="$disp" xdotool windowfocus "$nest"

# The fixture connects to kiln (core.spawn hands it kiln's WAYLAND_DISPLAY) and
# maps a toplevel; the tile layout fills the nest with it.
ev "core.spawn({\"$repo/build/wl-drag\"})" >/dev/null
sleep 3

mapped=$(ev 'for _, c in ipairs(client.all()) do
  if c.app_id == "kiln.dnd.probe" then return "yes" end
end
return "no"')
check "the drag fixture mapped" "yes" "$mapped"

# Before the drag: no start yet, state is "out".
check "no drag before the press" "0 out" "$(ev 'return DRAG .. " " .. DRAG_STATE')"

# =====================================================================
echo "== a held button-1 press over the fixture starts a real drag"
# Center of the 1024x768 nest: over the tiled fixture, so the press lands on its
# surface with pointer focus, the origin the start serial must match.
DISPLAY="$disp" xdotool mousemove --window "$nest" 200 200
sleep 1
DISPLAY="$disp" xdotool mousedown 1
sleep 2

# start_drag validated (serial matched a live pointer grab on the origin), the
# seat began the drag, the icon is in the cursor band, and drag::start drained.
check "drag::start fired exactly once" "1" "$(ev 'return tostring(DRAG)')"
check "the drag is in flight" "in" "$(ev 'return DRAG_STATE')"
# No end yet: a drag in flight has not dropped.
check "no drag::end while dragging" "0" "$(ev 'return tostring(DRAG_END)')"

# The icon rides the cursor: move it and confirm the drag still holds (the icon
# tree tracking the cursor is C-side; the observable here is that motion under the
# drag grab neither ends the drag nor faults).
DISPLAY="$disp" xdotool mousemove_relative -- 80 40
sleep 1
DISPLAY="$disp" xdotool mousemove_relative -- 60 -30
sleep 1
check "the drag survives motion (icon riding)" "in" "$(ev 'return DRAG_STATE')"

# =====================================================================
echo "== releasing the button drops, and the drop ends the drag"
DISPLAY="$disp" xdotool mouseup 1
sleep 2

check "drag::end fired exactly once (the drop)" "1" "$(ev 'return tostring(DRAG_END)')"
check "the drag is over" "out" "$(ev 'return DRAG_STATE')"

# =====================================================================
# No bus error snuck through the informational dispatch.
#
# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's
# pcall, so this leg MUST go red under it, or the grep is watching nothing.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	ev 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

check "no bus errors in the log" "0" \
	"$(grep -cE "error in '" "$log" || true)"

ev 'core.quit()' >/dev/null 2>&1 || true
[ "$fail" = 0 ] && echo PASS || { echo FAIL; exit 1; }
