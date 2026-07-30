#!/bin/sh
# The client-facing HiDPI scale test: a native Wayland client on a fractionally
# scaled output must be TOLD its scale via wp_fractional_scale_v1,
# or it renders at the wrong density and its input region drifts from the cursor.
#
#   scripts/hidpi-frac-test.sh
#
# Headless. Boot kiln, connect scripts/wl-fractional to its Wayland socket, and:
#   - assert the two globals are advertised (the manager + viewporter);
#   - at each output scale, map a toplevel and assert it received preferred_scale
#     equal to that scale in 120ths (120 at 1x, 180 at 1.5x, 240 at 2x).
# The scale is applied at runtime with core.output.set_scale before the
# client maps, so the surface enters an already-scaled output.
#
# Needs: build/wl-fractional (built by meson).
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-frac-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"

# Pin the config, the way prompt-test.sh does. Resolution order puts
# $XDG_CONFIG_HOME/kiln/rc.lua ahead of the repo copy, so an unpinned boot runs
# whatever config the user has installed rather than the one this battery
# asserts against, and the run silently stops testing what it says it tests.
rc="$repo/kilnrc.lua"
cfg="$work/config"
mkdir -p "$cfg"
kiln_pid=""

cleanup() {
	[ -n "$kiln_pid" ] && kill "$kiln_pid" 2>/dev/null || true
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

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
	XDG_RUNTIME_DIR="$work" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

# kiln prints its wayland socket name at boot; the fixture connects through it.
wldisp=$(sed -n 's/.*WAYLAND_DISPLAY=\([a-z0-9-]*\).*/\1/p' "$log" | head -1)
if [ -z "$wldisp" ]; then
	printf 'FAIL could not read WAYLAND_DISPLAY from the boot log\n'
	echo "FAIL"; exit 1
fi
printf 'info kiln on WAYLAND_DISPLAY=%s\n' "$wldisp"
frac() { WAYLAND_DISPLAY="$wldisp" XDG_RUNTIME_DIR="$work" "$repo/build/wl-fractional" "$@"; }

# --- the two globals are advertised, or no client can be told a scale at all.
check "fractional-scale + viewporter globals advertised" \
	"fractional=yes viewporter=yes" "$(frac globals)"

name=$(eval_kiln 'return core.output.list()[1].name')

# --- at each scale, a mapped client receives preferred_scale in 120ths.
for pair in "1:120" "1.5:180" "2:240"; do
	s=${pair%:*}; want=${pair#*:}
	eval_kiln "core.output.set_scale('$name', $s)" >/dev/null
	sleep 0.6
	got=$(frac scale | sed -n 's/^scale=//p')
	check "scale $s: client received preferred_scale $want (120ths)" "$want" "$got"
done

# --- no divergence through the scale changes.
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

check "no tree/scene divergence, no bus error" "0" \
	"$(grep -cE "tree==scene:|error in '|clay error" "$log" || true)"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
