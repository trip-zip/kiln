#!/bin/sh
# The shifted-chord battery: a REAL keypress, not a restated one.
#
#   scripts/shift-chord-test.sh
#
# Every other harness fires a binding by looking it up in state.keys and calling
# press() (parity-test.sh's key_fire, model-test.sh, rc-test.sh). That is the
# right discipline for routing, and it is structurally blind to the step BEFORE
# routing: what chord name a physical key actually produces. It cannot tell a
# working shift chord from a dead one, because it never asks xkb anything.
#
# It was blind to a real bug. xkb_state_key_get_syms returns the keysym at the
# level the held modifiers select, so shift+q resolved to Q: the origin event
# named "shift+super+Q", no config spells that, every mod+shift binding in
# kilnrc.lua was dead, and core_key_bound missed too, so the chord leaked to the
# focused client. The fix reads the chord off the BASE level (kiln.c, keyboard
# handle_key); shift stays a modifier bit instead of also rewriting the key.
#
# So this battery presses keys for real: the headless backend has no input
# devices at all, so kiln boots on the wlroots X11 backend inside a private
# Xvfb, which gives it a real keyboard, and xdotool presses into the kiln
# window.
#
# Needs: Xvfb, xdotool.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
rc="$repo/kilnrc.lua"
work="$(mktemp -d /tmp/kiln-shift-chord-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
disp=":97"
# Isolate XDG_CONFIG_HOME so config resolution cannot pick up the user's real
# ~/.config/kiln/rc.lua ahead of the rc this test means to boot.
cfg="$work/config"
mkdir -p "$cfg"
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
		printf 'ok   %s\n     (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s\n     expected %s\n     got      %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

Xvfb "$disp" -screen 0 1280x800x24 >"$work/xvfb.log" 2>&1 &
xvfb_pid=$!
sleep 2

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=x11 DISPLAY="$disp" KILN_SOCK="$sock" \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" LANG=en_US.UTF-8 \
	./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 3

nest=$(DISPLAY="$disp" xdotool search "" 2>/dev/null | tail -1)

# A real keypress into the nest. Focus has to settle before the press: XTEST
# delivers to whatever window holds X input focus at that moment.
press() {
	DISPLAY="$disp" xdotool windowfocus "$nest"
	sleep 0.3
	DISPLAY="$disp" xdotool key --clearmodifiers "$1"
	sleep 0.6
}
# The same press WITHOUT --clearmodifiers. xdotool's clearmodifiers turns off
# every active modifier for the duration of the press and NumLock is one of
# them, so the numpad row has to press raw or it would be testing the state it
# meant to set up having been undone.
press_raw() {
	DISPLAY="$disp" xdotool windowfocus "$nest"
	sleep 0.3
	DISPLAY="$disp" xdotool key "$1"
	sleep 0.6
}

# Record every chord the dispatcher looks up, so a failure names the string that
# actually arrived rather than only the effect that went missing.
eval_kiln "local st = require('kiln.state')
SEEN = {}
local real = st.keys
st.keys = setmetatable({}, {
  __index = function(_, k) SEEN[#SEEN + 1] = k; return real[k] end,
  __newindex = function(_, k, v) real[k] = v end,
  __pairs = function() return pairs(real) end,
})" >/dev/null
# Every chord looked up for a NON-modifier key, in order. Holding super looks up
# "Super_L" on both edges, and xdotool brackets a keypad press with its own
# Num_Lock presses to make the numbered level reachable; neither is a chord, so
# both drop out. Everything left is what a config could have bound.
saw() { eval_kiln "local skip = { Shift_L = true, Shift_R = true,
  Super_L = true, Super_R = true, Control_L = true, Control_R = true,
  Alt_L = true, Alt_R = true, Meta_L = true, Meta_R = true,
  Num_Lock = true, Caps_Lock = true, ISO_Level3_Shift = true }
local out = {}
for _, k in ipairs(SEEN) do
  if k:find('+', 1, true) ~= nil and not skip[k:match('[^+]+\$')] then
    out[#out + 1] = k
  end
end
return #out > 0 and table.concat(out, ' | ') or 'none'"; }
clear() { eval_kiln "SEEN = {}" >/dev/null; }

check "booted" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"

# The unshifted control: this one always worked, and must keep working.
clear
press "super+d"
check "super+d looks up the unshifted chord" "super+d" "$(saw)"

# The regression itself. Before the fix these read shift+super+D and
# shift+super+at: the shifted LEVEL leaking into the chord name.
clear
press "super+shift+d"
check "super+shift+d looks up the base-level chord" "shift+super+d" "$(saw)"
check "and the bound handler actually ran (do-not-disturb on)" "true" \
	"$(eval_kiln 'return tostring(notification.suspended == true)')"
press "super+shift+d"
check "pressing it again toggles back" "false" \
	"$(eval_kiln 'return tostring(notification.suspended == true)')"

# A digit, where shift changes the keysym to a punctuation name rather than a
# capital: 2 -> at. Same bug, different disguise.
clear
press "super+3"
check "super+3 views the third tag" "true" \
	"$(eval_kiln 'local s = screen.all()[1]
return tostring(s.selected_tag == s.tags[3])')"
clear
press "super+shift+2"
check "super+shift+2 looks up the base-level chord" "shift+super+2" "$(saw)"

# NumLock is a level-selecting modifier too, and level 0 of the keypad 1 key is
# KP_End. Cancelling the level unconditionally rather than only for shift/caps
# would take out kilnrc.lua's mod+KP_1..KP_9 whenever NumLock was on, which is
# the normal state of a keyboard that has a numpad.
# Pressed raw, because xdotool reaches the numbered level by turning NumLock on
# around the press, and --clearmodifiers would turn it back off: this row needs
# the modifier that provokes the bug, not a cleared keyboard.
clear
press_raw "super+KP_1"
check "NumLock keeps the numpad chord at its numbered level" "super+KP_1" "$(saw)"

# Shift must still reach the TEXT path: the chord fix reads the base level, the
# composed text keeps the shifted state, so a capital is still a capital.
eval_kiln "TYPED = nil
require('kiln.prompt').run { screen = screen.all()[1], label = 'T: ',
  done = function(t) TYPED = t end,
  cancelled = function() TYPED = '<cancelled>' end }" >/dev/null
press "shift+a"
press "b"
press "Return"
check "a shifted key still types its capital" "Ab" \
	"$(eval_kiln 'return tostring(TYPED)')"

# A chord shift does not change at all, as the control on the base-level lookup:
# space is space at every level.
clear
press "super+shift+space"
check "super+shift+space is unchanged by the level" "shift+super+space" "$(saw)"

# The one the user actually reported. This kills the instance, so it goes last.
press "super+shift+q"
sleep 1
if kill -0 "$kiln_pid" 2>/dev/null; then
	check "super+shift+q quits kiln" "exited" "still running"
else
	check "super+shift+q quits kiln" "exited" "exited"
	kiln_pid=""
fi

echo "---"
[ "$fail" = 0 ] && echo PASS || echo FAIL
exit "$fail"
