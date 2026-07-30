#!/bin/sh
# The idle battery: core.set_idle_timeout arms a C timer that emits idle::start
# after the timeout with no input and idle::stop on the first activity after;
# the existing inhibit leg emits idle::inhibit { on } when a visible inhibitor
# flips. Auto-lock after idle, inexpressible from the public API before this,
# becomes six rc.lua lines.
#
#   scripts/idle-test.sh
#
# The harness is pointer-test.sh's, for the same reason: the re-arm leg
# needs real input and the headless backend has no input devices, so kiln boots
# on the wlroots X11 backend inside a private Xvfb, which gives it a real pointer
# xdotool can move. Everything else (IPC readback, a private KILN_SOCK, a wl
# fixture connecting to kiln's own WAYLAND_DISPLAY) is unchanged by the backend.
#
# The idle timer fires on wall time, not input, so idle::start arrives even while
# an inhibitor holds the idle NOTIFIER off: C never combines the two, and whether
# inhibit blocks auto-lock is the config's own `if` (asserted here). The inhibitor
# is scripts/wl-inhibit, a real client that binds the manager and maps a surface
# the stock config tiles on screen.
#
# Needs: Xvfb, xdotool, and a kiln built with -Dxwayland=enabled.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-idle-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
rc="$work/rc.lua"
disp=":98"
kiln_pid=""
xvfb_pid=""
inhib_pid=""

cleanup() {
	[ -n "$inhib_pid" ] && kill "$inhib_pid" 2>/dev/null || true
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
# The recorder log, read back over one eval each. starts() counts idle::start so
# a leg can assert it grew (or did not); last() is the newest token.
starts() { eval_kiln 'local n = 0
for _, v in ipairs(IDLE_LOG) do if v == "start" then n = n + 1 end end
return n'; }
last() { eval_kiln 'return IDLE_LOG[#IDLE_LOG] or ""'; }

# The rc under test (foreign-test.sh shape): one tag per screen tiling the stock
# defaults, plus a recorder that appends each idle fact to IDLE_LOG for readback.
# The config never mentions the C timer beyond arming it; delivery is kiln.on.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
end)
IDLE_LOG = {}
kiln.on("idle::start", function() IDLE_LOG[#IDLE_LOG + 1] = "start" end)
kiln.on("idle::stop", function() IDLE_LOG[#IDLE_LOG + 1] = "stop" end)
kiln.on("idle::inhibit", function(on)
	IDLE_LOG[#IDLE_LOG + 1] = "inhibit:" .. tostring(on)
end)
EOF

Xvfb "$disp" -screen 0 1280x800x24 >"$work/xvfb.log" 2>&1 &
xvfb_pid=$!
sleep 2

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=x11 DISPLAY="$disp" KILN_RC="$rc" KILN_SOCK="$sock" \
	./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 3

# --- leg 1: boot.
check "the compositor booted" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"

nest=$(DISPLAY="$disp" xdotool search "" 2>/dev/null | tail -1)
DISPLAY="$disp" xdotool windowfocus "$nest"
# Kiln's own wayland socket, so the inhibitor fixture reaches the same compositor
# (shared XDG_RUNTIME_DIR). The IPC eval socket is separate.
wl="$(sed -n 's/.*WAYLAND_DISPLAY=\([^ ]*\).*/\1/p' "$log" | head -n1)"
check "the manager is advertised" "idle_inhibit=yes" \
	"$(WAYLAND_DISPLAY="$wl" "$repo/build/wl-inhibit" globals)"

# --- leg 2: arm, then idle with no input.
eval_kiln 'require("kiln").set_idle_timeout(1000)' >/dev/null
sleep 1.6
check "idle::start fires after the timeout with no input" "start" "$(last)"

# --- leg 3: first activity leaves idle.
DISPLAY="$disp" xdotool mousemove --window "$nest" 300 300
sleep 0.5
check "the first activity emits idle::stop" "stop" "$(last)"

# --- leg 4: activity keeps re-arming; no idle while it flows, idle once it stops.
s0=$(starts)
i=0
while [ "$i" -lt 5 ]; do
	DISPLAY="$disp" xdotool mousemove_relative -- 7 7
	sleep 0.4
	DISPLAY="$disp" xdotool mousemove_relative -- -7 -7
	i=$((i + 1))
done
s1=$(starts)
check "no idle::start while activity flows (timer re-arms)" "$s0" "$s1"
sleep 1.6
s2=$(starts)
if [ "$s2" -gt "$s1" ]; then
	printf 'ok   idle::start returns once activity stops (%s -> %s)\n' "$s1" "$s2"
else
	printf 'FAIL idle::start did not return after activity stopped\n'
	fail=1
fi

# --- leg 5: a visible inhibitor flips idle::inhibit, and the timer STILL fires
# through it (C never combines the two).
WAYLAND_DISPLAY="$wl" "$repo/build/wl-inhibit" >"$work/inhib.log" 2>&1 &
inhib_pid=$!
sleep 2
check "a visible inhibitor flips idle::inhibit true" "inhibit:true" "$(last)"
s3=$(starts)
# Re-arm through the live inhibitor (the reset rule emits stop first), then wait:
# the wall-time timer owes nothing to the notifier the inhibitor holds off.
eval_kiln 'require("kiln").set_idle_timeout(1000)' >/dev/null
sleep 1.6
s4=$(starts)
if [ "$s4" -gt "$s3" ]; then
	printf 'ok   idle::start fires even under a live inhibitor (%s -> %s)\n' \
		"$s3" "$s4"
else
	printf 'FAIL the inhibitor suppressed the auto-lock timer (never-combine)\n'
	fail=1
fi

# --- leg 6: dropping the inhibitor flips idle::inhibit back (exact pid, no pkill).
kill "$inhib_pid" 2>/dev/null || true
inhib_pid=""
sleep 2
check "dropping the inhibitor flips idle::inhibit false" "inhibit:false" "$(last)"

# --- leg 7: disarm, then no idle at all.
eval_kiln 'require("kiln").set_idle_timeout(nil) IDLE_LOG = {}' >/dev/null
sleep 1.6
check "a disarmed timer never fires" "0" "$(starts)"

# --- leg 8: no noise, clean exit.
#
# The pattern is "error in '", not "bus error in": init.lua's on_error
# override is what prints, and it subsumes the old "error in .idle" alternative
# that only ever caught idle:: signals. KILN_BUS_PROBE=1 raises one real error
# through bus.lua's pcall, so this leg MUST go red under it.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

check "no bus errors in the log" "0" \
	"$(grep -cE "error in '" "$log" || true)"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
[ "$fail" = 0 ] && echo PASS || { echo FAIL; exit 1; }
