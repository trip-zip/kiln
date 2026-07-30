#!/bin/sh
# The request-family battery: the three state asks, on both the xdg and the X11
# path, honored into the bands Lua declares.
#
#   scripts/fullscreen-test.sh
#
# The headline: Firefox F11 enters the fullscreen band and F11 again returns it
# to its tile, on both paths. F11 is a real keypress, not a synthesized verb
# call, and that is what forces the shape of this harness:
# the headless backend has no input devices at all, so kiln is booted on the
# wlroots X11 backend inside a private Xvfb, which gives it a real keyboard.
# xdotool presses the key into the kiln window; the assertions come back over the
# nested instance's own IPC socket.
#
# The other two asks have no app that raises them on demand, so scripts/x11-state
# (the fixture, built with -Dxwayland) sends them as the client messages a real
# X client would, and foot's startup flags raise the xdg ones. Needs: Xvfb,
# xdotool, firefox, foot.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-fs-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"

# Pin the config, the way prompt-test.sh does. Resolution order puts
# $XDG_CONFIG_HOME/kiln/rc.lua ahead of the repo copy, so an unpinned boot runs
# whatever config the user has installed rather than the one this battery
# asserts against, and the run silently stops testing what it says it tests.
rc="$repo/kilnrc.lua"
cfg="$work/config"
mkdir -p "$cfg"
disp=":99"
kiln_pid=""
xvfb_pid=""
ff_pid=""

cleanup() {
	[ -n "$ff_pid" ] && kill -9 "$ff_pid" 2>/dev/null || true
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

# The fullscreen flag and the surface box of each mapped client. The box is what
# proves the band: fullscreen is the whole output, edge to edge, with no chrome
# inset. Maximized is deliberately not in this line, because a fresh-profile
# firefox asks to be maximized as it starts (a real request::maximize, honored),
# and that is orthogonal to what F11 does.
state() {
	eval_kiln '
local o = {}
for _, s in ipairs(screen.all()) do
  for _, t in ipairs(s.tags) do
    for _, c in ipairs(t.clients) do
      o[#o+1] = string.format("fs=%s %dx%d",
        tostring(c.fullscreen or false), c.width, c.height)
    end
  end
end
return table.concat(o, " ; ")'
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

# The kiln window in the outer X server: the only client on this private display.
nest=$(DISPLAY="$disp" xdotool search "" 2>/dev/null | tail -1)
DISPLAY="$disp" xdotool windowfocus "$nest"
screen_box=$(eval_kiln 'local s = screen.all()[1] return s.width .. "x" .. s.height')
wl_disp=$(sed -n 's/.*Running Wayland compositor on WAYLAND_DISPLAY=//p' "$log" | head -1)

# A real keypress into the nest. The focus has to settle first: XTEST delivers to
# whatever window holds X input focus at the moment of the press, and a focus
# request issued in the same breath has not been acted on yet.
f11() {
	DISPLAY="$disp" xdotool windowfocus "$nest"
	sleep 1
	DISPLAY="$disp" xdotool key F11
	sleep 2
}

# --- the exit test, xdg path: a wayland-native Firefox, F11 in and F11 out.
# Its own profile and --no-remote, or it merges into a Firefox already running
# on the real session and nothing maps here. The profile directories must exist:
# firefox answers a missing one with a "Profile Missing" dialog, which maps and
# tiles like a browser and ignores F11 like a dialog.
mkdir -p "$work/ff-wl" "$work/ff-x11"
WAYLAND_DISPLAY="$wl_disp" MOZ_ENABLE_WAYLAND=1 firefox --profile "$work/ff-wl" \
	--new-instance --no-remote about:blank >"$work/ff-wl.log" 2>&1 &
ff_pid=$!
sleep 15
DISPLAY="$disp" xdotool windowfocus "$nest"
tiled=$(state)
case "$tiled" in
	*fs=true*) check "xdg: tiled at boot" "not fullscreen" "$tiled" ;;
	"") check "xdg: firefox mapped" "one client" "none" ;;
	*) printf 'ok   xdg: tiled at boot (%s)\n' "$tiled" ;;
esac
f11
check "xdg: F11 enters the fullscreen band" "fs=true ${screen_box}" "$(state)"
f11
check "xdg: F11 again returns it to its tile" "$tiled" "$(state)"
kill -9 "$ff_pid" 2>/dev/null || true
ff_pid=""
sleep 2

# --- the exit test, X11 path: the same Firefox forced onto XWayland. Spawned
# through IPC, because DISPLAY for the nest's own X server is set inside the
# compositor process and exists nowhere else.
eval_kiln 'core.spawn({"/bin/sh","-c","MOZ_ENABLE_WAYLAND=0 exec firefox --profile '"$work"'/ff-x11 --new-instance --no-remote about:blank"})' >/dev/null
sleep 18
DISPLAY="$disp" xdotool windowfocus "$nest"
tiled=$(state)
check "X11: mapped through XWayland" "true" \
	"$(eval_kiln 'for _, s in ipairs(screen.all()) do for _, t in ipairs(s.tags) do for _, c in ipairs(t.clients) do if c.class ~= nil then return "true" end end end end return "false"')"
# The state the window arrived holding, not one it asked for: firefox writes
# _NET_WM_STATE_MAXIMIZED_* on the window before it maps, wlroots reads that as
# property state and raises no request, and the map payload carries it instead.
# Without it a client that opens maximized opens tiled.
check "X11: opens in the state it mapped with" "true" \
	"$(eval_kiln 'for _, s in ipairs(screen.all()) do for _, t in ipairs(s.tags) do for _, c in ipairs(t.clients) do if c.class ~= nil then return tostring(c.maximized or false) end end end end return "none"')"
f11
check "X11: F11 enters the fullscreen band" "fs=true ${screen_box}" "$(state)"
f11
check "X11: F11 again returns it to its tile" "$tiled" "$(state)"

# --- maximize and minimize, X11: the client messages a taskbar or a titlebar
# button sends. No app raises these to order, hence the fixture.
# The window id is the nest's own X server's, so the lookup runs inside it too.
eval_kiln 'core.spawn({"/bin/sh","-c","xdotool search --name \"Mozilla Firefox\" > '"$work"'/xwin 2>&1"})' >/dev/null
sleep 2
xwin=$(head -1 "$work/xwin")
printf '     (X11 firefox window %s)\n' "$xwin"
st() { eval_kiln "core.spawn({\"$repo/build/x11-state\",\"$xwin\",\"$1\",\"$2\"})" >/dev/null; sleep 3; }

maximized() {
	eval_kiln 'for _, s in ipairs(screen.all()) do for _, t in ipairs(s.tags) do for _, c in ipairs(t.clients) do if c.class ~= nil then return tostring(c.maximized or false) end end end end return "none"'
}
# Off first, then on. A request is a state CHANGE, and firefox maps with
# _NET_WM_STATE_MAXIMIZED_* already on the window (it wants to start maximized),
# so asking to maximize an already-maximized window is not a request and wlroots
# emits nothing, correctly. That map-time state rides the map payload instead
# and is asserted above; off first is what makes the next ask a change.
st maximize off
check "X11: request::maximize off honored" "false" "$(maximized)"
st maximize on
check "X11: request::maximize on honored" "true" "$(maximized)"
st maximize off
st minimize on
# Minimized means the runtime stops declaring it: not drawn, not focused.
check "X11: request::minimize undeclares the client" "true" \
	"$(eval_kiln 'for _, s in ipairs(screen.all()) do for _, t in ipairs(s.tags) do for _, c in ipairs(t.clients) do if c.minimized and client.focus ~= c then return "true" end end end end return "false"')"
st minimize off
check "X11: un-minimize restores it" "false" \
	"$(eval_kiln 'for _, s in ipairs(screen.all()) do for _, t in ipairs(s.tags) do for _, c in ipairs(t.clients) do if c.minimized then return "true" end end end end return "false"')"

# --- the xdg ask raised before the client maps (xdg-shell allows set_fullscreen
# before the initial commit). The fact arrives with no client object to honor it
# on, so the runtime replays it at map; without that a kiosk client opens tiled.
eval_kiln 'core.spawn({"foot","--fullscreen"})' >/dev/null
sleep 4
check "xdg: pre-map fullscreen ask honored at map" "true" \
	"$(eval_kiln 'for _, s in ipairs(screen.all()) do for _, t in ipairs(s.tags) do for _, c in ipairs(t.clients) do if c.app_id == "foot" and c.fullscreen then return "true" end end end end return "false"')"

# The compositor stayed clean throughout: no Lua errors on the bus, no
# tree-vs-scene divergence from the always-on reconciler checks.
#
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
