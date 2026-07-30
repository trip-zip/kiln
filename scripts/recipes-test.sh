#!/bin/sh
# The recipe battery: the screenshot and wallpaper recipes, proven against the
# public API. Runs last.
#
#   scripts/recipes-test.sh
#
# Both recipes are config space, zero stdlib lines, zero new C: the capture
# primitive they lean on was already there. This script proves they hold:
#
#   1. Wallpaper: a ui.box image fill floated to root in the background band,
#      wired live in rc.lua from KILN_WALLPAPER. The recipe is pure kiln.ui, zero
#      core references. A boot with a magenta wallpaper paints the background
#      band magenta, and a boot without it does not: the two frames differ, and
#      the wallpaper frame's centre is magenta. It survives a runtime flip to 2x
#      scale (the wallpaper fills at both scales, s.width being logical).
#   2. Screenshot: core.screenshot(screen, path), the recipe's one core
#      reference, writes a PNG of the composed scene.
#
# The dependency-free proof the wallpaper took effect is the two-frame diff; the
# magenta centre-pixel check is an enhancement that needs ImageMagick and is
# skipped with an info line when it is absent (the capture-test wl-paste pattern).
#
# TTY-manual (run by hand on a seat, since it needs real panels): a hi-res
# wallpaper on a real 2x panel beside a 1x monitor is sharp and seam-free on both.
# Headless has one virtual panel, so runtime set_scale stands in for the second.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
docs="${KILN_DOCS:-$HOME/tools/somewm-docs}/kiln/guides"
work="$(mktemp -d /tmp/kiln-recipes-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
wall="$work/wall.png"

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

# The magenta fixture: a 64x64 solid #FF00FF PNG, decoded here so the script is
# self-contained (no ImageMagick needed to make it, only to inspect it). A solid
# colour has no detail to blur, so upscaling it to fill the screen stays magenta.
base64 -d > "$wall" <<'B64'
iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAATElEQVR42u3PMQkAAAwDsPo33Uno
PQjEQNL0tQgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgILAdB
p+HSRtACMAAAAABJRU5ErkJggg==
B64

# Boot kiln with an optional wallpaper, wait for it, and leave it running. The
# caller drives it over IPC and then calls stop_kiln. No subshell: $! must be
# kiln itself so cleanup's kill lands on it (the capture-test rule).
start_kiln() { # $1 = KILN_WALLPAPER value (may be empty)
	rm -f "$sock"
	cd "$repo"
	KILN_WALLPAPER="$1" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
		XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
		KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
	kiln_pid=$!
	sleep 2
}
stop_kiln() {
	[ -n "$kiln_pid" ] && kill "$kiln_pid" 2>/dev/null || true
	[ -n "$kiln_pid" ] && wait "$kiln_pid" 2>/dev/null || true
	kiln_pid=""
}

# --- Boot 1: no wallpaper. The baseline frame the wallpaper frame must differ from.
start_kiln ""
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
eval_kiln "return core.screenshot('$name', '$work/baseline.png')" >/dev/null
sleep 0.5
stop_kiln

# --- Boot 2: the wallpaper recipe live from KILN_WALLPAPER.
start_kiln "$wall"
name=$(eval_kiln 'local l = core.output.list()
return (l ~= nil and #l >= 1) and l[1].name or "none"')
eval_kiln "return core.screenshot('$name', '$work/wall_1x.png')" >/dev/null
sleep 0.5

# The screenshot recipe, verbatim: the one core reference, given a path, lands a
# PNG of the composed scene.
recipe_key=$(eval_kiln "return core.screenshot('$name', '$work/recipe.png') or 'nil'")
sleep 0.5

# The 2x leg: flip the output to 2x at runtime and re-shoot. s.width is logical,
# so the wallpaper box (w = s.width) still fills the whole physical output.
eval_kiln "core.output.set_scale('$name', 2.0)" >/dev/null
sleep 0.6
check "set_scale: list() reports 2x" "2" \
	"$(eval_kiln 'return core.output.list()[1].scale')"
eval_kiln "return core.screenshot('$name', '$work/wall_2x.png')" >/dev/null
sleep 0.5
# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's pcall,
# so this leg MUST go red under it, which is what proves the grep can see a
# failure at all.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

noise=$(grep -cE "error in '|tree==scene:" "$log" || true)
stop_kiln

# --- Assertions, all on the captured files now that kiln is down.

png_kind() { file -b "$1" 2>/dev/null | cut -d, -f1; }
png_dims() { file -b "$1" 2>/dev/null | grep -o "$w x $h" || true; }
png_bytes() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# The screenshot recipe writes a PNG: the save leg.
case "$recipe_key" in
	screenshot:*) printf 'ok   the screenshot recipe returns a cache key\n     (%s)\n' "$recipe_key" ;;
	*) printf 'FAIL screenshot recipe key\n     expected screenshot:N\n     got      %s\n' "$recipe_key"; fail=1 ;;
esac
if [ -f "$work/recipe.png" ]; then
	check "the screenshot recipe writes a PNG" "PNG image data" "$(png_kind "$work/recipe.png")"
	check "the screenshot PNG matches the output resolution" "$w x $h" "$(png_dims "$work/recipe.png")"
else
	printf 'FAIL the screenshot recipe wrote no file\n'; fail=1
fi

# The wallpaper frame is a real, correctly sized capture.
if [ -f "$work/wall_1x.png" ]; then
	check "the wallpaper frame is a PNG" "PNG image data" "$(png_kind "$work/wall_1x.png")"
	check "the wallpaper frame matches the output resolution" "$w x $h" "$(png_dims "$work/wall_1x.png")"
	b=$(png_bytes "$work/wall_1x.png")
	if [ "${b:-0}" -gt 2000 ]; then
		printf 'ok   the wallpaper frame is a real capture (not blank)\n     (%s bytes)\n' "$b"
	else
		printf 'FAIL the wallpaper frame is suspiciously small (%s bytes)\n' "${b:-0}"; fail=1
	fi
else
	printf 'FAIL the wallpaper boot captured no frame\n'; fail=1
fi

# The dependency-free proof the wallpaper recipe took effect: the wallpaper frame
# differs from the no-wallpaper baseline. Only the recipe reads KILN_WALLPAPER, so
# a changed frame is the recipe rendering.
if [ -f "$work/baseline.png" ] && [ -f "$work/wall_1x.png" ]; then
	if cmp -s "$work/baseline.png" "$work/wall_1x.png"; then
		printf 'FAIL the wallpaper frame is identical to the baseline (recipe did not render)\n'; fail=1
	else
		printf 'ok   the wallpaper frame differs from the no-wallpaper baseline\n'
	fi
fi

# The 2x frame: the wallpaper still fills at 2x (same physical dims, real capture).
if [ -f "$work/wall_2x.png" ]; then
	check "the 2x wallpaper frame matches the output resolution" "$w x $h" "$(png_dims "$work/wall_2x.png")"
	b2=$(png_bytes "$work/wall_2x.png")
	if [ "${b2:-0}" -gt 2000 ]; then
		printf 'ok   the wallpaper fills at 2x scale too (not blank)\n     (%s bytes)\n' "$b2"
	else
		printf 'FAIL the 2x wallpaper frame is suspiciously small (%s bytes)\n' "${b2:-0}"; fail=1
	fi
else
	printf 'FAIL no 2x wallpaper frame captured\n'; fail=1
fi

# Enhanced check: the background band is actually magenta at both scales. Needs
# ImageMagick to read a pixel; skipped with an info line when it is absent. The
# sample point is the frame centre, below the 28px bar, so it lands on wallpaper.
if command -v magick >/dev/null 2>&1; then
	IM=magick
elif command -v convert >/dev/null 2>&1; then
	IM=convert
else
	IM=""
fi
if [ -n "$IM" ]; then
	cx=$((w / 2)); cy=$((h / 2))
	is_magenta() { # $1 = png
		"$IM" "$1" -crop "1x1+$cx+$cy" +repage txt: 2>/dev/null | grep -qi '#FF00FF'
	}
	if is_magenta "$work/wall_1x.png"; then
		printf 'ok   the wallpaper paints the background band magenta at 1x\n'
	else
		printf 'FAIL the 1x background band is not the wallpaper colour\n'; fail=1
	fi
	if is_magenta "$work/wall_2x.png"; then
		printf 'ok   the wallpaper paints the background band magenta at 2x\n'
	else
		printf 'FAIL the 2x background band is not the wallpaper colour\n'; fail=1
	fi
	# And the baseline centre is NOT magenta, so the check is not vacuous.
	if is_magenta "$work/baseline.png"; then
		printf 'FAIL the no-wallpaper baseline is already magenta (check is vacuous)\n'; fail=1
	else
		printf 'ok   the no-wallpaper baseline centre is not magenta (check is real)\n'
	fi
else
	printf 'info ImageMagick not installed; skipping the magenta centre-pixel check\n'
fi

# --- The wallpaper recipe is pure: zero core references in the config and the doc.
check "the config reaches for no core primitive (the wallpaper recipe is pure)" "0" \
	"$(grep -c 'core\.' "$rc" | tr -d ' ')"
if [ -f "$docs/wallpaper.md" ]; then
	check "wallpaper.md is core-free" "0" \
		"$(grep -c 'core\.' "$docs/wallpaper.md" | tr -d ' ')"
else
	printf 'FAIL wallpaper.md is missing from the docs checkout\n'; fail=1
fi

# The screenshot recipe doc exists and names its one primitive.
if [ -f "$docs/screenshots.md" ]; then
	if grep -q 'core\.screenshot' "$docs/screenshots.md"; then
		printf 'ok   screenshots.md documents its one core reference\n'
	else
		printf 'FAIL screenshots.md does not mention core.screenshot\n'; fail=1
	fi
else
	printf 'FAIL screenshots.md is missing from the docs checkout\n'; fail=1
fi

# The compositor stayed clean across the wallpaper boot and the scale flip.
check "no bus errors, no tree/scene divergence" "0" "${noise:-0}"

if [ "$fail" = "0" ]; then echo PASS; else echo FAIL; fi
exit "$fail"
