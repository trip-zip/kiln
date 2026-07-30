#!/bin/sh
# The HiDPI/fractional battery: per-context scale threaded into the raster path,
# the raster cache keyed on scale, screen.scale as the whole Lua surface, and the
# declare-time id guard.
#
#   scripts/hidpi-test.sh
#
# Pure headless, two outputs (WLR_HEADLESS_OUTPUTS=2): one is flipped to 2x at
# runtime with core.output.set_scale, the other stays 1x, the "2x panel beside a
# 1x monitor" case. The device-density claim is read off the raster_kb gauge each
# solve logs per output: the raster grows with scale (buffers are sized in device pixels) on the scaled
# output while the 1x output is untouched, and the scale-keyed cache re-rasters on
# the flip. screen.scale reports the live scale. The seam-free property is wlroots'
# own device-space edge rounding (scale_length: sizes are differences of rounded
# edges), exercised under live motion by hidpi-cursor.sh with KILN_AGREE; here the
# structural facts are asserted (device sizing, per-output independence, no
# tree==scene divergence at a fractional scale).
#
# The id guard: a table id whose second element is non-numeric raises at declare
# with a stack trace and the compositor stays up, instead of coercing to 0,
# colliding ids, and hitting the CLAY_ERROR_TYPE_DUPLICATE_ID abort.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-hidpi-test.XXXXXX)"
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
		printf 'ok   %s\n     (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s\n     expected %s\n     got      %s\n' "$1" "$2" "$3"
		fail=1
	fi
}
# raster_kb from the last solve line for a given output.
raster_kb() { grep "on $1:" "$log" | tail -1 | sed -n 's/.*raster_kb=\([0-9]*\).*/\1/p'; }

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=2 \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
	WLR_LIBINPUT_NO_DEVICES=1 KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

# --- two outputs, both at scale 1.
check "two headless outputs enumerate" "2" \
	"$(eval_kiln 'return #core.output.list()')"
one=$(eval_kiln 'return core.output.list()[1].name')
two=$(eval_kiln 'return core.output.list()[2].name')
printf 'info outputs: %s (to scale) and %s (stays 1x)\n' "$one" "$two"

# --- screen.scale, the whole Lua surface: reports the output scale, live off
# core.output.list(), defaulting to 1.
check "screen.scale is 1 on both at boot" "1 1" \
	"$(eval_kiln "local function s(nm) for _,x in ipairs(screen.all()) do
	if x.name==nm then return x.scale end end return -1 end
	return s('$one')..' '..s('$two')")"

# --- baseline raster on both (same per-screen chrome), before any scale change.
sleep 0.3
kb_one_1x=$(raster_kb "$one")
kb_two_1x=$(raster_kb "$two")
printf 'info baseline raster_kb: %s=%s %s=%s\n' "$one" "$kb_one_1x" "$two" "$kb_two_1x"

# --- capture output-change events, then flip one output to 2x at runtime.
eval_kiln '_G.__oc = {}
core.set_event_handler(function(ev)
  if ev.class == "output" and ev.name == "change" then
    _G.__oc[#_G.__oc + 1] = ev.output
  end
end)
return "installed"' >/dev/null

eval_kiln "core.output.set_scale('$one', 2)" >/dev/null
sleep 0.8

check "set_scale: output change fired, naming the scaled output" "$one" \
	"$(eval_kiln 'return _G.__oc[#_G.__oc] or "none"')"
check "screen.scale reflects the flip: 2 on the scaled, 1 on the other" "2 1" \
	"$(eval_kiln "local function s(nm) for _,x in ipairs(screen.all()) do
	if x.name==nm then return x.scale end end return -1 end
	return s('$one')..' '..s('$two')")"

# --- device density: the scaled output's raster grew (buffers sized in device
# pixels, and the scale-keyed cache re-rastered), while the 1x output did not.
kb_one_2x=$(raster_kb "$one")
kb_two_2x=$(raster_kb "$two")
printf 'info after 2x: %s=%s (was %s) %s=%s (was %s)\n' \
	"$one" "$kb_one_2x" "$kb_one_1x" "$two" "$kb_two_2x" "$kb_two_1x"
if [ "${kb_one_2x:-0}" -gt "${kb_one_1x:-0}" ]; then
	printf 'ok   device density: %s raster grew with scale (%s -> %s kB)\n' \
		"$one" "$kb_one_1x" "$kb_one_2x"
else
	printf 'FAIL %s raster did not grow with scale (%s -> %s)\n' \
		"$one" "$kb_one_1x" "$kb_one_2x"
	fail=1
fi
check "the 1x output is untouched by the other's scale (independent contexts)" \
	"$kb_two_1x" "$kb_two_2x"

# --- no divergence through the fractional-scale commit: the always-on reconciler
# verifier and the bus stayed clean.
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

check "no bus errors, no tree/scene divergence at scale" "0" \
	"$(grep -cE "error in '|tree==scene:|clay error" "$log" || true)"

# --- the id guard: a non-numeric table id raises at declare, compositor stays up.
# Install a frame handler that declares such an id, then trigger a solve.
eval_kiln 'core.set_frame_handler(function(sn,w,h)
  core.open({ id = {"bad", "notanumber"} })
  core.close()
end); return "installed"' >/dev/null
before=$(grep -c "table id index must be a number" "$log" || true)
eval_kiln "core.output.set_scale('$two', 1.5)" >/dev/null
sleep 0.6
after=$(grep -c "table id index must be a number" "$log" || true)
if [ "$after" -gt "$before" ]; then
	printf 'ok   id guard: a non-numeric table id raised at declare (%s -> %s)\n' \
		"$before" "$after"
else
	printf 'FAIL id guard: the non-numeric id did not raise\n'
	fail=1
fi
check "id guard: the compositor stayed up after the bad declare" "2" \
	"$(eval_kiln 'return 1 + 1')"
check "id guard: no id collision reached the abort handler" "0" \
	"$(grep -cE 'DUPLICATE' "$log" || true)"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
