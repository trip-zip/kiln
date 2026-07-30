#!/bin/sh
# The cursor battery: the cursor changes shape over a resize edge at fractional
# scale, without blur.
#
#   scripts/cursor-test.sh
#
# Two boots of the same tree, one per scale, and the difference between them is
# the whole assertion. On each: hover a client's south-east resize handle, and
# read back both halves of the claim.
#
#   shape:  the name Lua handed core.input.set_cursor. At a fractional scale the
#           chrome hit still lands on the edge handle, so the shape still gets
#           named: Clay hit-tests in logical coords and the scale never enters.
#   sharp:  the size of the cursor image the compositor actually handed the
#           output, read out of the OUTER X server with XFixes (scripts/
#           x11-cursor.c), because the wlroots X11 backend sets a real X cursor.
#           At scale 1 that is the theme's base raster; at 1.5 it must be a
#           BIGGER raster, loaded at the output's scale. A base raster stretched
#           to 1.5 is exactly what blur is, and it would come back the same size.
#
# The scale is applied at runtime through core.output.set_scale, not a boot-time
# env knob. Committing the scale reloads the xcursor theme at the output's live
# scale, which is the fact the sharpness claim rests on.
#
# Needs: Xvfb, xdotool, foot, a kiln built with -Dxwayland=enabled.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-cursor-test.XXXXXX)"

# Pin the config, the way prompt-test.sh does. Resolution order puts
# $XDG_CONFIG_HOME/kiln/rc.lua ahead of the repo copy, so an unpinned boot runs
# whatever config the user has installed rather than the one this battery
# asserts against, and the run silently stops testing what it says it tests.
rc="$repo/kilnrc.lua"
cfg="$work/config"
mkdir -p "$cfg"
disp=":95"
kiln_pid=""
xvfb_pid=""

cleanup() {
	[ -n "$kiln_pid" ] && kill "$kiln_pid" 2>/dev/null || true
	[ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

fail=0
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

# One pass at one scale: boot kiln, map a terminal, exercise the shape asks, then
# hover its SE resize handle. Writes "<logical screen> <cursor name> <cursor image
# size>" to $work/res-<scale>; runs in this shell, so its checks count.
pass() { # scale
	scale="$1"
	sock="$work/kiln-$scale.sock"
	log="$work/kiln-$scale.log"
	# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
	# orphans the compositor to init (the capture-test.sh rule).
	cd "$repo"
	WLR_BACKENDS=x11 DISPLAY="$disp" KILN_SOCK="$sock" \
		XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
		./build/kiln > "$log" 2>&1 &
	kiln_pid=$!
	sleep 3
	ev() { KILN_SOCK="$sock" "$repo/scripts/kiln-eval" "$1"; }

	# Apply the scale before the client maps, the runtime verb standing in for the
	# old KILN_SCALE boot knob. The commit reloads the theme at the live scale.
	ev "local o = core.output.list()[1]
core.output.set_scale(o.name, $scale)
return o.name" >/dev/null
	sleep 1

	nest=$(DISPLAY="$disp" xdotool search "" 2>/dev/null | tail -1)
	DISPLAY="$disp" xdotool windowfocus "$nest"

	# The cursor name is Lua's fact: the resize handle's on_hover names the
	# theme's edge cursor and hands it to C. Wrapping the verb records it.
	ev 'local orig = core.input.set_cursor
CURSOR = "none"
core.input.set_cursor = function(name) CURSOR = name; return orig(name) end
return "hooked"' >/dev/null

	ev 'core.spawn({"foot"})' >/dev/null
	sleep 4

	# Resize handles are declared for floating clients only (a tiled client's
	# geometry is the solved cell, not a thing to drag), so float it at a box
	# this test knows, in LOGICAL coords: the only space Lua and Clay speak.
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
	screen_box=$(ev 'local s = screen.all()[1] return s.width .. "x" .. s.height')
	if [ "$floated" = "none" ]; then
		printf 'FAIL scale %s: no client mapped\n' "$scale"
		fail=1
		kill "$kiln_pid" 2>/dev/null || true
		kiln_pid=""
		return 0
	fi
	sleep 2

	# The SE handle is the bottom-right corner of that box. xdotool moves the
	# pointer in DEVICE pixels (the outer X server's space), so the logical
	# corner is scaled on the way out: the one conversion in this test, and the
	# reason a fractional scale is worth testing at all. A hit at 498,398 and a
	# hit at 747,597 are the same logical pixel.
	# First the client's own body: foot names a shape through cursor-shape-v1
	# rather than shipping a buffer, and holding pointer focus is what makes the
	# ask valid. This is also where the grab check below starts from.
	bx=$(awk -v v=300 -v s="$scale" 'BEGIN { printf "%d", v * s }')
	by=$(awk -v v=250 -v s="$scale" 'BEGIN { printf "%d", v * s }')
	DISPLAY="$disp" xdotool mousemove --window "$nest" "$bx" "$by"
	sleep 2
	shapes=$(grep -c "cursor-shape: honored" "$log" || true)
	if [ "$shapes" -gt 0 ]; then
		printf 'ok   scale %s: the client named a shape, no buffer (%s honored)\n' \
			"$scale" "$shapes"
	else
		printf 'FAIL scale %s: no cursor-shape-v1 ask was honored over the client\n' \
			"$scale"
		fail=1
	fi

	# A shape ask under an interactive grab must die, and by the grab's cleared
	# pointer focus alone: there is no guard in the shape handler. Hold mod+drag
	# and watch: Lua's grab cursor stands, and no further ask is honored, because
	# the client has no pointer focus to make one valid.
	DISPLAY="$disp" xdotool keydown super
	DISPLAY="$disp" xdotool mousedown 1
	sleep 1
	DISPLAY="$disp" xdotool mousemove_relative -- 40 30
	sleep 1
	held=$(ev 'return CURSOR')
	shapes_grab=$(grep -c "cursor-shape: honored" "$log" || true)
	DISPLAY="$disp" xdotool mouseup 1
	DISPLAY="$disp" xdotool keyup super
	sleep 1
	check "scale $scale: the grab's cursor stands (Lua's, not the client's)" \
		"grabbing" "$held"
	check "scale $scale: no shape ask survives the grab (focus is gone)" \
		"$shapes" "$shapes_grab"

	# Put the client back where the handle math expects it, then hover the SE
	# handle. xdotool moves the pointer in DEVICE pixels (the outer X server's
	# space), so the logical corner is scaled on the way out: the one conversion
	# in this test, and the reason a fractional scale is worth testing at all. A
	# hit at 498,398 and a hit at 747,597 are the same logical pixel.
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
	hx=$(awk -v v=498 -v s="$scale" 'BEGIN { printf "%d", v * s }')
	hy=$(awk -v v=398 -v s="$scale" 'BEGIN { printf "%d", v * s }')
	DISPLAY="$disp" xdotool mousemove --window "$nest" "$hx" "$hy"
	sleep 2

	name=$(ev 'return CURSOR')
	size=$(DISPLAY="$disp" "$repo/build/x11-cursor" | sed -n 's/^w=\([0-9]*\).*/\1/p')
	printf '%s %s %s\n' "$screen_box" "$name" "${size:-0}" > "$work/res-$scale"
	kill "$kiln_pid" 2>/dev/null || true
	kiln_pid=""
	sleep 1
}

# The nest is 1024x768 device pixels (the wlroots X11 backend's window), so at
# scale 1 that is what the output measures logically: the baseline raster.
pass 1
set -- $(cat "$work/res-1")
check "scale 1: the output is 1024x768 logical" "1024x768" "$1"
check "scale 1: the SE resize edge names its shape" "se-resize" "$2"
base_size=$3
printf 'ok   scale 1: the cursor raster is %s px\n' "$base_size"

# The same 1024x768 device pixels at scale 1.5: 682x512 logical, fractional.
pass 1.5
set -- $(cat "$work/res-1.5")
check "scale 1.5: the output is 682x512 logical (fractional)" "682x512" "$1"
check "scale 1.5: the SE resize edge still names its shape" "se-resize" "$2"
frac_size=$3

# The sharpness claim: a theme loaded at the output's scale hands the output a
# bigger raster. A base raster stretched to a fractional output would come back
# at the base size, and that is blur.
if [ "${frac_size:-0}" -gt "${base_size:-0}" ]; then
	printf 'ok   scale 1.5: the cursor raster grew with the scale, %s -> %s px (no upscale)\n' \
		"$base_size" "$frac_size"
else
	printf 'FAIL scale 1.5: the cursor raster stayed %s px: the base theme was stretched (blur)\n' \
		"$frac_size"
	fail=1
fi

exit "$fail"
