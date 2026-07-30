#!/bin/sh
# The capture + color battery: core.screenshot, and the three hands-off globals
# of the capture/color surface (primary selection, screencopy, gamma control).
#
#   scripts/capture-test.sh
#
# Two legs run headless here; two are TTY-manual and only documented (below),
# because they need a seat with a real keyboard, which a headless boot with
# WLR_LIBINPUT_NO_DEVICES=1 does not have (the kiln-testing rule: keyboard
# delivery is not exercisable headless).
#
# Automated:
#   1. core.screenshot(screen) returns a "screenshot:N" cache key; with a path it
#      also writes a PNG. The PNG is a real capture of the composed scene (chrome
#      + wallpaper + any clients), not a blank buffer: it is decoded by the same
#      image cache a widget's { image = { path = key } } reads, so a non-nil key
#      that produced a non-trivial PNG is the whole "usable as an image source"
#      claim, minus the on-screen display the interactive check covers.
#   2. The primary-selection, screencopy, and gamma-control globals are all
#      advertised to a connecting client (the managers exist and bind).
#
# TTY-manual (recorded here, run by hand on a seat):
#   - Primary selection round-trips: select text in one client, middle-click
#     paste into another (needs a keyboard/pointer serial, so not headless).
#   - OBS captures a region through the screencopy portal path.
#   - wlsunset shifts gamma, and the shift survives an output hotplug.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-capture-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
shot="$work/shot.png"

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
		printf 'ok   %s\n     (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s\n     expected %s\n     got      %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

# No subshell around the boot: $! must be the kiln process itself, so cleanup's
# kill lands on it and not a wrapping shell that would orphan kiln to init. The
# absolute paths below do not depend on the working directory.
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
	KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

name=$(eval_kiln 'local l = core.output.list()
return (l ~= nil and #l >= 1) and l[1].name or "none"')
if [ "$name" = "none" ] || [ -z "$name" ]; then
	printf 'FAIL no output to screenshot; aborting\n'
	echo "FAIL"
	exit 1
fi
printf 'info output under test: %s\n' "$name"
w=$(eval_kiln 'return core.output.list()[1].width')
h=$(eval_kiln 'return core.output.list()[1].height')

# --- 1. core.screenshot returns a cache key.
key=$(eval_kiln "return core.screenshot('$name') or 'nil'")
case "$key" in
	screenshot:*) printf 'ok   core.screenshot returns a cache key\n     (%s)\n' "$key" ;;
	*) printf 'FAIL core.screenshot key\n     expected screenshot:N\n     got      %s\n' "$key"; fail=1 ;;
esac

# A stale name is a checked no-op: nil, never an abort.
check "core.screenshot on an unknown screen returns nil" "nil" \
	"$(eval_kiln "return core.screenshot('NO-SUCH-OUTPUT') or 'nil'")"

# --- the save leg: with a path, one cairo write lands a PNG of the composed scene.
key2=$(eval_kiln "return core.screenshot('$name', '$shot') or 'nil'")
case "$key2" in
	screenshot:*) printf 'ok   core.screenshot(screen, path) returns a key\n     (%s)\n' "$key2" ;;
	*) printf 'FAIL core.screenshot save-leg key\n     got %s\n' "$key2"; fail=1 ;;
esac
sleep 0.5
if [ -f "$shot" ]; then
	kind=$(file -b "$shot" | cut -d, -f1)
	dims=$(file -b "$shot" | grep -o "$w x $h" || true)
	bytes=$(wc -c < "$shot")
	check "the save leg writes a PNG" "PNG image data" "$kind"
	check "the PNG matches the output resolution" "$w x $h" "$dims"
	# A blank single-colour frame zlib-compresses to ~1 KB; real chrome is many
	# KB. > 2000 bytes is the "not a blank buffer" floor.
	if [ "$bytes" -gt 2000 ]; then
		printf 'ok   the PNG holds a real capture (not a blank buffer)\n     (%s bytes)\n' "$bytes"
	else
		printf 'FAIL the PNG is suspiciously small (%s bytes), may be blank\n' "$bytes"
		fail=1
	fi
else
	printf 'FAIL the save leg wrote no file at %s\n' "$shot"
	fail=1
fi

# --- 2. the three globals are advertised. A connecting client sees them in the
# registry even with no keyboard (binding is not selecting). WAYLAND_DEBUG dumps
# every wl_registry.global; grep the interface names out of one trivial client.
disp=$(grep -o 'WAYLAND_DISPLAY=[a-z0-9-]*' "$log" | head -1 | cut -d= -f2)
if [ -z "$disp" ]; then
	printf 'FAIL could not read the compositor display name from the log\n'
	fail=1
elif ! command -v wl-paste >/dev/null 2>&1; then
	printf 'info wl-paste not installed; skipping the globals-advertised leg\n'
else
	reg=$(WAYLAND_DISPLAY="$disp" WAYLAND_DEBUG=1 timeout 2 wl-paste --list-types 2>&1 || true)
	has() { printf '%s\n' "$reg" | grep -q "\"$1\""; }
	if has zwp_primary_selection_device_manager_v1; then
		printf 'ok   primary-selection manager is advertised\n'
	else
		printf 'FAIL primary-selection manager not advertised\n'; fail=1
	fi
	if has zwlr_screencopy_manager_v1; then
		printf 'ok   screencopy manager is advertised\n'
	else
		printf 'FAIL screencopy manager not advertised\n'; fail=1
	fi
	if has zwlr_gamma_control_manager_v1; then
		printf 'ok   gamma-control manager is advertised\n'
	else
		printf 'FAIL gamma-control manager not advertised\n'; fail=1
	fi
fi

if [ "$fail" = "0" ]; then echo PASS; else echo FAIL; fi
exit "$fail"
