#!/bin/sh
# The output-verbs battery: core.output.list, set_mode, set_scale, set_position,
# set_enabled, set_adaptive_sync, all write-only, with the one contracted read
# (list) and the `output change` fact channel they emit on.
#
#   scripts/output-test.sh
#
# Pure headless: the verbs operate on outputs, not clients, so nothing here needs
# a real input device or a mapped surface. The single headless output is driven
# over IPC and read back through core.output.list(); the change event is caught by
# a capturing handler installed by the test itself (no lua/kiln/ lines: the probe
# lives here, and replacing the config's event dispatcher is safe in a quiet run
# that quits right after).
#
# The change event carries the connector name only; the new scale/mode/position are
# read back through list(), the one contracted read. So "set_scale fires
# output change carrying the new scale" is asserted as two facts: the event named
# the output, AND list() reports 1.5.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-output-test.XXXXXX)"
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

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
	KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

# --- one output exists, and list() reads it.
name=$(eval_kiln 'local l = core.output.list()
return (l ~= nil and #l >= 1) and l[1].name or "none"')
check "list() enumerates the headless output" "1" \
	"$(eval_kiln 'return #core.output.list()')"
if [ "$name" = "none" ] || [ -z "$name" ]; then
	printf 'FAIL no output to drive; aborting\n'
	echo "FAIL"
	exit 1
fi
printf 'info output under test: %s\n' "$name"

# list()'s per-output shape carries the contracted fields; modes is a table
# (empty on headless, which has no mode list), not nil.
check "list() row carries a modes table" "table" \
	"$(eval_kiln "local o = core.output.list()[1]
return type(o.modes)")"
check "list() row carries scale, x, y, enabled" "number number number boolean" \
	"$(eval_kiln "local o = core.output.list()[1]
return type(o.scale)..' '..type(o.x)..' '..type(o.y)..' '..type(o.enabled)")"

# --- the capturing handler: append the name of every output-change event. This
# replaces the config's event dispatcher, which is fine: no clients, no input,
# quits after.
eval_kiln '_G.__oc = {}
core.set_event_handler(function(ev)
  if ev.class == "output" and ev.name == "change" then
    _G.__oc[#_G.__oc + 1] = ev.output
  end
end)
return "installed"' >/dev/null

# --- set_scale: flips to 1.5 at runtime; output change fires; list() reports 1.5.
eval_kiln "core.output.set_scale('$name', 1.5)" >/dev/null
sleep 0.6
check "set_scale: output change fired, naming the output" "$name" \
	"$(eval_kiln 'return _G.__oc[#_G.__oc] or "none"')"
check "set_scale: list() reports the new scale" "1.5" \
	"$(eval_kiln 'return core.output.list()[1].scale')"

# --- set_mode: a custom mode round-trips through list().
eval_kiln '_G.__oc = {}' >/dev/null
eval_kiln "core.output.set_mode('$name', 1280, 720)" >/dev/null
sleep 0.6
check "set_mode: width round-trips through list()" "1280" \
	"$(eval_kiln 'return core.output.list()[1].width')"
check "set_mode: height round-trips through list()" "720" \
	"$(eval_kiln 'return core.output.list()[1].height')"
check "set_mode: output change fired" "$name" \
	"$(eval_kiln 'return _G.__oc[#_G.__oc] or "none"')"

# --- set_position: a layout move round-trips through list().
eval_kiln '_G.__oc = {}' >/dev/null
eval_kiln "core.output.set_position('$name', 100, 50)" >/dev/null
sleep 0.6
check "set_position: x round-trips through list()" "100" \
	"$(eval_kiln 'return core.output.list()[1].x')"
check "set_position: y round-trips through list()" "50" \
	"$(eval_kiln 'return core.output.list()[1].y')"
check "set_position: output change fired" "$name" \
	"$(eval_kiln 'return _G.__oc[#_G.__oc] or "none"')"

# --- stale name no-ops (does not error, emits nothing).
eval_kiln '_G.__oc = {}' >/dev/null
staleret=$(eval_kiln "core.output.set_scale('NO-SUCH-OUTPUT', 2.0)
return 'ok'")
sleep 0.4
check "stale output name no-ops without error" "ok" "$staleret"
check "stale name emitted no output change" "0" \
	"$(eval_kiln 'return #_G.__oc')"

# --- the KILN_SCALE dev knob is gone from the tree: scale is a runtime verb now,
# so no env override may linger behind it.
check "KILN_SCALE knob deleted from the C tree" "0" \
	"$(grep -rl KILN_SCALE "$repo"/*.c "$repo"/*.h 2>/dev/null | wc -l | tr -d ' ')"

# --- the compositor stayed clean: no Lua errors on the bus, no tree/scene
# divergence from the always-on reconciler through every commit above.
#
# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's
# pcall, so this leg MUST go red under it, or the grep is watching nothing.
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
