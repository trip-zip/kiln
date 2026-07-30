#!/bin/sh
# The pointer-constraints battery: a pointer-locked game works, and mod+drag
# still wins.
#
#   scripts/pointer-test.sh
#
# The game is scripts/x11-lock.c, built in the tree like the other X11 fixtures:
# teeworlds headless is impractical, so this is the smallest X11 client that
# makes a game's ask (cursor hidden, pointer grabbed), which XWayland translates
# into a locked pointer on the compositor. That translation is the whole subject:
# with no constraints global the ask lands on nothing.
#
# The harness is the nested one, for the same reason: the headless backend has
# no input devices, so kiln boots on the wlroots X11 backend inside a private
# Xvfb, which gives it a real pointer, and xdotool moves it. Compositor-side
# assertions come back over IPC. The motion hook is pure Lua, installed at test
# time: every input::motion event reaches grabber.route_pointer, so wrapping it
# counts what C emitted. A locked pointer emits nothing (C never moves the
# cursor, so there is no motion fact), and that silence is the assertion.
#
# Needs: Xvfb, xdotool, a kiln built with -Dxwayland=enabled.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-pointer-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"

# Pin the config, the way prompt-test.sh does. Resolution order puts
# $XDG_CONFIG_HOME/kiln/rc.lua ahead of the repo copy, so an unpinned boot runs
# whatever config the user has installed rather than the one this battery
# asserts against, and the run silently stops testing what it says it tests.
rc="$repo/kilnrc.lua"
cfg="$work/config"
mkdir -p "$cfg"
disp=":97"
kiln_pid=""
xvfb_pid=""

cleanup() {
	[ -n "$kiln_pid" ] && kill "$kiln_pid" 2>/dev/null || true
	[ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

fail=0
eval_kiln() { KILN_SOCK="$sock" "$repo/scripts/kiln-eval" "$1"; }
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   %s (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s: expected %s got %s\n' "$1" "$2" "$3"
		fail=1
	fi
}
motions() { eval_kiln 'return MOTIONS'; }
fixture_motions() {
	n=$(sed -n 's/^LOCKFIX motions=\([0-9]*\).*/\1/p' "$log" | tail -1)
	printf '%s' "${n:-0}"
}
client_state() {
	eval_kiln 'for _, s in ipairs(screen.all()) do
  for _, t in ipairs(s.tags) do
    for _, c in ipairs(t.clients) do
      local f = c.float or {}
      return string.format("%s %s %d,%d", tostring(c.class),
        tostring(c.floating or false), f.x or 0, f.y or 0)
    end
  end
end
return "none"'
}

Xvfb "$disp" -screen 0 1280x800x24 >"$work/xvfb.log" 2>&1 &
xvfb_pid=$!
sleep 2

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=x11 DISPLAY="$disp" KILN_SOCK="$sock" \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
	./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 3

nest=$(DISPLAY="$disp" xdotool search "" 2>/dev/null | tail -1)
DISPLAY="$disp" xdotool windowfocus "$nest"

# The motion counter: input::motion is the only fact C emits when the cursor
# moves, and every one of them passes through this call.
eval_kiln 'local grabber = require("kiln.grab")
local orig = grabber.route_pointer
MOTIONS = 0
grabber.route_pointer = function(ev)
  if ev.name == "motion" then MOTIONS = MOTIONS + 1 end
  return orig(ev)
end
return "hooked"' >/dev/null

# set_pointer: libinput config over every pointer device, nil fields untouched.
# The nest's pointer is the X11 backend's, not libinput's, so every field falls
# out at the device: what this asserts is that the verb exists, takes its
# whole-value table, and touches nothing it was not given. A real touchpad is
# the daily-driver check, not a headless one.
cfg=$(eval_kiln 'core.input.set_pointer {
  tap_to_click = true, natural_scrolling = true, accel_speed = 0.3,
  accel_profile = "flat", scroll_method = "two_finger",
  click_method = "clickfinger", left_handed = false,
}
core.input.set_pointer { accel_speed = -0.2 }
return "applied"')
check "set_pointer takes its table" "applied" "$cfg"

# The game. Spawned through IPC: DISPLAY for the nest's own XWayland exists
# inside the compositor process and nowhere else.
eval_kiln 'core.spawn({"'"$repo"'/build/x11-lock"})' >/dev/null
sleep 4
state0=$(client_state)
case "$state0" in
	kiln-lock*) printf 'ok   the game mapped (%s)\n' "$state0" ;;
	*) check "the game mapped" "kiln-lock ..." "$state0" ;;
esac

# Put the pointer on it and let XWayland see the hidden cursor over a focused
# window: that pair is what it turns into a locked pointer.
DISPLAY="$disp" xdotool mousemove --window "$nest" 640 500
sleep 2
grab=$(grep -c '^LOCKFIX grab=ok' "$log" || true)
check "the game grabbed the X pointer" "1" "$grab"

# --- exit 1: locked, the cursor does not move. C emits no motion fact at all,
# because it never moves the cursor; the client keeps getting deltas.
m0=$(motions)
f0=$(fixture_motions)
DISPLAY="$disp" xdotool mousemove_relative -- 400 200
sleep 1
DISPLAY="$disp" xdotool mousemove_relative -- -200 -100
sleep 1
m1=$(motions)
f1=$(fixture_motions)
check "the locked cursor does not move (no motion facts)" "$m0" "$m1"
if [ "$f1" -gt "$f0" ]; then
	printf 'ok   the game keeps receiving motion under the lock (%s events)\n' \
		"$((f1 - f0))"
else
	printf 'FAIL the game receives no motion under the lock\n'
	fail=1
fi

# --- exit 2: mod+drag wins. The interactive grab clears pointer focus, which is
# what suspends the constraint; the cursor moves again and the window follows.
DISPLAY="$disp" xdotool mousemove --window "$nest" 640 500
sleep 1
m2=$(motions)
DISPLAY="$disp" xdotool keydown super
DISPLAY="$disp" xdotool mousedown 1
sleep 1
DISPLAY="$disp" xdotool mousemove_relative -- 120 80
sleep 1
DISPLAY="$disp" xdotool mouseup 1
DISPLAY="$disp" xdotool keyup super
sleep 1
m3=$(motions)
dragged=$(client_state)
if [ "$m3" -gt "$m2" ]; then
	printf 'ok   the grab suspends the lock: motion flows again (%s facts)\n' \
		"$((m3 - m2))"
else
	printf 'FAIL mod+drag is still locked out: no motion during the grab\n'
	fail=1
fi
# The drag is 120,80 from wherever the lock pinned the cursor, and grab_move
# floats the client at the tile it left, so the float lands near that delta.
dx=$(printf '%s' "$dragged" | sed -n 's/.* \([0-9-]*\),\([0-9-]*\)$/\1/p')
dy=$(printf '%s' "$dragged" | sed -n 's/.* \([0-9-]*\),\([0-9-]*\)$/\2/p')
case "$dragged" in
	"kiln-lock true"*)
		if [ "${dx:-0}" -gt 50 ] && [ "${dy:-0}" -gt 30 ]; then
			printf 'ok   mod+drag moved the locked game (%s)\n' "$dragged"
		else
			printf 'FAIL mod+drag floated but did not move the game: %s\n' "$dragged"
			fail=1
		fi
		;;
	*) check "mod+drag moved the locked game" "kiln-lock true <dx>,<dy>" "$dragged" ;;
esac

# --- exit 3: release restores the lock, and by focus alone: no saved pointer.
#
# Put the pointer back INSIDE the game first. A constraint applies while the
# pointer is over the constrained surface, so a drag that carries the cursor off
# a small floated window deactivates the lock for a reason that has nothing to do
# with what this leg asserts. The floated size is the config's policy, not this
# battery's, so the leg reads it back and aims rather than assuming the window is
# big enough to still be under the cursor.
cx=$(eval_kiln 'local c = client.all()[1]
if c == nil then return 0 end
return math.floor(c.x + c.width / 2)')
cy=$(eval_kiln 'local c = client.all()[1]
if c == nil then return 0 end
return math.floor(c.y + c.height / 2)')
DISPLAY="$disp" xdotool mousemove --window "$nest" "$cx" "$cy"
sleep 1
m4=$(motions)
DISPLAY="$disp" xdotool mousemove_relative -- 150 90
sleep 1
m5=$(motions)
check "the lock is back after the drag (no motion facts)" "$m4" "$m5"

exit "$fail"
