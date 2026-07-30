#!/bin/sh
# The grabs + prompt battery: the prompt accepts dead-key compose input, and a
# grab outranks every binding while it holds.
#
#   scripts/prompt-test.sh
#
# The claim is a REAL dead key, and the headless backend has no input devices at
# all, so kiln boots on the wlroots X11 backend inside a private Xvfb, which gives
# it a real keyboard, and xdotool presses keys into the kiln window. The assertions
# come back over the nested instance's IPC socket.
#
# The layout is switched to us-intl through core.input.set_keymap, which takes on
# every keyboard with no restart and puts dead_acute on the apostrophe key. The
# compose table is the locale's, built in C at keyboard setup, so LANG must name a
# UTF-8 locale.
#
# Needs: Xvfb, xdotool.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-prompt-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
disp=":98"
# Pin the config. The drag leg presses alt because rc.lua sets modkey to alt,
# but resolution order puts $XDG_CONFIG_HOME/kiln/rc.lua ahead of the repo copy,
# so on a machine where the user's own config lives there (a symlink to
# kilnrc.lua, modkey super) this battery silently booted a DIFFERENT config and
# the two drag rows failed on a chord that config does not bind. Naming the rc
# and emptying the search path makes the run say what it tests.
rc="$repo/kilnrc.lua"
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
		printf 'ok   %s (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s: expected %s got %s\n' "$1" "$2" "$3"
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
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
	LANG=en_US.UTF-8 ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 3

nest=$(DISPLAY="$disp" xdotool search "" 2>/dev/null | tail -1)

# A real keypress into the nest. Focus has to settle before the press: XTEST
# delivers to whatever window holds X input focus at that moment.
press() {
	DISPLAY="$disp" xdotool windowfocus "$nest"
	sleep 0.4
	DISPLAY="$disp" xdotool key "$1"
	sleep 0.6
}

# --- the input verb, in use: us-intl on every keyboard, no restart.
eval_kiln 'core.input.set_keymap { layout = "us", variant = "intl" }' >/dev/null
eval_kiln 'core.input.set_repeat(25, 600)' >/dev/null
eval_kiln 'core.input.set_numlock(true)' >/dev/null

# The probe binding: what a grab has to outrank. Unmodified F5, so the press
# needs no modifier state to settle.
eval_kiln 'local kiln = require("kiln")
FIRED = false
kiln.key { mods = {}, key = "F5", press = function() FIRED = true end }' >/dev/null

press F5
check "binding fires with no grab" "true" "$(eval_kiln 'return tostring(FIRED)')"

# --- the prompt takes the keyboard.
eval_kiln 'local kiln = require("kiln")
FIRED = false
DONE = nil
P = kiln.prompt.run { label = "Run: ", done = function(t) DONE = t end }' >/dev/null
sleep 0.5
check "prompt declared on Clay" "true" \
	"$(eval_kiln 'local b = core.box("prompt:" .. screen.all()[1].name)
	return tostring(b ~= nil and b.width > 0 and b.height > 0)')"

# The grab rank: a grabbed key never reaches a binding while the grab holds.
press F5
check "grab outranks the binding" "false" "$(eval_kiln 'return tostring(FIRED)')"
check "F5 typed nothing" "" "$(eval_kiln 'return P.text')"

# --- THE EXIT TEST: a dead key. apostrophe is dead_acute under us-intl, so it
# composes with the e behind it and enters the prompt as one grapheme. The
# compose state is C's, resolved at the single utf8 site every key on the queue
# passes through; the prompt just inserts what the key brought.
press apostrophe
check "mid-compose key types nothing" "" "$(eval_kiln 'return P.text')"
press e
check "dead key + e composes into the prompt" "é" "$(eval_kiln 'return P.text')"
check "one grapheme, two bytes" "2" "$(eval_kiln 'return tostring(#P.text)')"

# Ordinary keys still type after a compose, and backspace steps over the whole
# composed grapheme rather than splitting it into half a codepoint.
press t
check "plain keys type after a compose" "ét" "$(eval_kiln 'return P.text')"
press BackSpace
press BackSpace
check "backspace drops the whole grapheme" "" "$(eval_kiln 'return P.text')"

# --- Return closes the prompt, releases the claim, and restores routing.
# The line is typed the same way: c, a, f, then the dead key and e.
press c
press a
press f
press apostrophe
press e
check "the composed line" "café" "$(eval_kiln 'return P.text')"
press Return
check "Return runs the completion callback" "café" "$(eval_kiln 'return tostring(DONE)')"
check "prompt is gone" "nil" "$(eval_kiln 'return tostring(require("kiln").prompt.active)')"
check "history kept the line" "café" \
	"$(eval_kiln 'local h = require("kiln").prompt.history return tostring(h[#h])')"

press F5
check "release restores the binding" "true" "$(eval_kiln 'return tostring(FIRED)')"

# --- Escape cancels without running done, and a second prompt replaces the
# first (one keyboard, one claim).
eval_kiln 'local kiln = require("kiln")
DONE = nil
CANCELLED = false
P = kiln.prompt.run { text = "x", cancelled = function() CANCELLED = true end }
Q = kiln.prompt.run { text = "y" }' >/dev/null
check "the second prompt took the claim" "true" \
	"$(eval_kiln 'return tostring(require("kiln").prompt.active == Q)')"
check "the first prompt was stopped, not left holding" "true" \
	"$(eval_kiln 'return tostring(P.claim == nil)')"
eval_kiln 'FIRED = false' >/dev/null
press Escape
check "Escape runs no done callback" "nil" "$(eval_kiln 'return tostring(DONE)')"
check "no prompt holds the keyboard" "nil" \
	"$(eval_kiln 'return tostring(require("kiln").prompt.active)')"
press F5
check "the binding is live again" "true" "$(eval_kiln 'return tostring(FIRED)')"

# --- menu keys through the real queue. menu-test.sh drives the nav verbs
# headless, which proves the mechanism; this is the leg only a seat can prove,
# that a PHYSICAL key reaches the map at all. Same grab rank as the prompt's,
# because it is the same claim: the menu holds the keyboard for the life of the
# chain, so F5 must go nowhere while it is up.
msel() { # the path of the row the deepest open level has selected
	eval_kiln 'local m = require("kiln").menu.open
	if m == nil then return "closed" end
	local lv = m.levels[#m.levels]
	return lv.hover or "none"'
}
eval_kiln 'local kiln = require("kiln")
FIRED = false
MFIRED = "none"
kiln.ui.menu { screen = screen.all()[1], x = 100, y = 100, items = {
  { "one", function() MFIRED = "one" end },
  { "sub", { { "deep", function() MFIRED = "deep" end } } },
} }' >/dev/null
sleep 0.5
press Down
check "a real Down walks the menu" "/1" "$(msel)"
press Down
press Right
check "a real Right descends into the submenu" "/2/1" "$(msel)"
press Escape
check "a real Escape closes one level" "/2" "$(msel)"
press F5
check "the open chain outranks the binding" "false" \
	"$(eval_kiln 'return tostring(FIRED)')"
press Up
press Return
check "a real Return runs the selected row" "one" "$(eval_kiln 'return MFIRED')"
check "and the chain closed" "closed" "$(msel)"
press F5
check "the menu released the keyboard" "true" "$(eval_kiln 'return tostring(FIRED)')"
# No chain past this line: an open menu leaves a capturing scrim over the whole
# screen, and the drag below presses through where it would be.
eval_kiln 'require("kiln").menu.close()' >/dev/null

# --- the mousegrabber, through the one claim the runtime's own drag now makes:
# mod+drag is not a second grab path any more, it is a mousegrabber like any a
# config could start, so a working drag is the pointer claim proving itself.
# alt is the modkey; the client floats and follows the pointer, and the release
# of the button that started the drag ends it.
wl_disp=$(sed -n 's/.*Running Wayland compositor on WAYLAND_DISPLAY=//p' "$log" | head -1)
WAYLAND_DISPLAY="$wl_disp" foot >"$work/foot.log" 2>&1 &
sleep 3
DISPLAY="$disp" xdotool windowfocus "$nest"
sleep 0.5

float() { # the focused client's float box, or "tiled"
	eval_kiln 'local c = client.focus
	if c == nil then return "no client" end
	if not c.floating then return "tiled" end
	local f = c.float or {}
	return math.floor(f.x or 0) .. "," .. math.floor(f.y or 0)'
}
check "foot mapped and tiled" "tiled" "$(float)"

DISPLAY="$disp" xdotool mousemove 300 300
sleep 0.3
DISPLAY="$disp" xdotool keydown super
DISPLAY="$disp" xdotool mousedown 1
sleep 0.5
start=$(float)
DISPLAY="$disp" xdotool mousemove 380 340
sleep 0.5
moved=$(float)
DISPLAY="$disp" xdotool mouseup 1
DISPLAY="$disp" xdotool keyup super
sleep 0.5
after=$(float)

check "mod+press floats the client" "true" \
	"$(test "$start" != "tiled" -a "$start" != "no client" && echo true || echo false)"
check "the drag moved it by the pointer delta" "true" \
	"$(test "$moved" != "$start" && echo true || echo false)"
check "the release ended the drag" "$moved" "$after"
printf '     (float %s -> %s, released at %s)\n' "$start" "$moved" "$after"
# The claim released with the button: a stranded grab would leave the pointer
# withheld from every client and the drag still tracking the cursor.
check "the pointer claim released" "true" \
	"$(DISPLAY="$disp" xdotool mousemove 500 500; sleep 0.4; test "$(float)" = "$after" && echo true || echo false)"

# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's pcall,
# so this leg MUST go red under it, which is what makes the green mean anything.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

noise=$(grep -cE "error in '|tree==scene:" "$log" || true)
check "no bus errors, no tree/scene divergence" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
