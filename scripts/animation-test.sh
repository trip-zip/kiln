#!/bin/sh
# The animation battery: core.tick and core.timer_cancel. Three facts:
#
#   1. An animated tag switch runs at panel rate on ONE output while the second
#      solves zero frames (the per-output frame clock is isolated).
#   2. DPMS-off freezes ticks at zero cost; re-enable resumes.
#   3. core.timer_cancel disarms a live timer; a stale id no-ops.
#
#   scripts/animation-test.sh
#
# Pure headless, two outputs (WLR_HEADLESS_OUTPUTS=2). The per-output solve
# counter is the solve log itself ("solve #N on <name>:", ui.c): no new C surface,
# the same counter the solve-count asserts read. The animation is the stock
# default-on stdlib (kiln.animation), so this runs against the shipped rc.lua.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-animation-test.XXXXXX)"
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
# Solves logged for one output since boot (the per-output frame counter).
solves() { grep -cE "solve #[0-9]+ on $1:" "$log" || true; }
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   %s\n     (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s\n     expected %s\n     got      %s\n' "$1" "$2" "$3"
		fail=1
	fi
}
check_gt() { # label threshold actual
	if [ "$3" -gt "$2" ]; then
		printf 'ok   %s\n     (%s > %s)\n' "$1" "$3" "$2"
	else
		printf 'FAIL %s\n     expected > %s\n     got        %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=2 \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
	WLR_LIBINPUT_NO_DEVICES=1 KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

A=$(eval_kiln 'return core.output.list()[1].name')
B=$(eval_kiln 'return core.output.list()[2].name')
if [ -z "$A" ] || [ -z "$B" ] || [ "$A" = "$B" ]; then
	printf 'FAIL need two distinct headless outputs (got "%s" "%s")\n' "$A" "$B"
	echo "FAIL"; exit 1
fi
printf 'info outputs: A=%s  B=%s\n' "$A" "$B"

# --- control: at rest, a 0.4s window is quiet on both outputs. This makes the
# zero-solve assertion below meaningful (the minute clock is not about to fire).
a0=$(solves "$A"); b0=$(solves "$B")
sleep 0.4
check "at rest, output A is idle (0 solves in 0.4s)" "0" "$(( $(solves "$A") - a0 ))"
check "at rest, output B is idle (0 solves in 0.4s)" "0" "$(( $(solves "$B") - b0 ))"

# --- 1. an animated tag switch on A runs at panel rate; B solves zero frames.
ac=$(solves "$A"); bc=$(solves "$B")
eval_kiln "for _, s in ipairs(screen.all()) do
  if s.name == '$A' then s.tags[2]:view() end
end
return 'switched'" >/dev/null
sleep 0.4
check_gt "animated tag switch drove solves on A at panel rate" "3" \
	"$(( $(solves "$A") - ac ))"
check "the second output solved zero frames during A's animation" "0" \
	"$(( $(solves "$B") - bc ))"

# --- 2. DPMS-off freezes ticks at zero cost; re-enable resumes. A 3s animation
# on A gives a window to disable it mid-flight.
eval_kiln "require('kiln.animation').start('$A', '__dpms', 1, 3.0, 0)
return 'armed'" >/dev/null
x0=$(solves "$A"); sleep 0.4
check_gt "the long animation is solving A" "0" "$(( $(solves "$A") - x0 ))"
eval_kiln "core.output.set_enabled('$A', false)" >/dev/null
sleep 0.2
d0=$(solves "$A"); sleep 0.4
check "DPMS-off freezes ticks (zero solves while disabled)" "0" \
	"$(( $(solves "$A") - d0 ))"
eval_kiln "core.output.set_enabled('$A', true)" >/dev/null
sleep 0.2
r0=$(solves "$A"); sleep 0.4
check_gt "re-enable resumes the frozen animation" "0" \
	"$(( $(solves "$A") - r0 ))"

# --- 3. timer_cancel disarms a live one-shot; a stale id no-ops without error.
eval_kiln '_G.__f1 = false; _G.__f2 = false
local id = core.timer(200, function() _G.__f1 = true end)
core.timer_cancel(id)                       -- disarm the live one
core.timer(200, function() _G.__f2 = true end)  -- control: not cancelled
return "ok"' >/dev/null
staleret=$(eval_kiln 'core.timer_cancel(999999) return "ok"')  # stale: no-op
check "timer_cancel on a stale id no-ops without error" "ok" "$staleret"
sleep 0.5
check "a cancelled timer never fires" "false" \
	"$(eval_kiln 'return tostring(_G.__f1)')"
check "an uncancelled timer still fires (control)" "true" \
	"$(eval_kiln 'return tostring(_G.__f2)')"

# --- the compositor stayed clean through every commit and animation frame.
#
# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's
# pcall, so this leg MUST go red under it.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

noise=$(grep -cE "lua error|error in '|tree==scene:" "$log" || true)
check "no lua errors, no tree/scene divergence" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
