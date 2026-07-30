#!/bin/sh
# The foreign-toplevel battery: kiln advertises
# wlr_foreign_toplevel_management_v1, one write-only handle per mapped client fed
# from the hint sites that already exist, and the manager's minimize/activate
# requests ride the SAME request events the xdg/xwl asks do (no second dispatch
# path). The PROTOCOL half is REAL: scripts/wl-toplevel (a tree fixture, the
# foreign-toplevel analog of wl-activate) binds the manager and actually lists
# and drives, so the round trips are proven, not restated.
#
#   scripts/foreign-test.sh
#
# The observed window is `wl-toplevel open`: a plain xdg toplevel with a known
# title/app_id that stays mapped. `wl-toplevel list` reads back what the manager
# advertises; `wl-toplevel minimize`/`activate` send a taskbar's request. All run
# against kiln's WAYLAND_DISPLAY (grabbed from the log), while state readbacks go
# over the IPC eval socket.
#
# THE NAMED QUESTION: a foreign activate carries the client's seat, so C derives
# valid=true from it (seat != NULL), unlike an X11 activate which arrives
# valid=false. This battery asserts valid=true, answering it.
#
# Needs: nothing beyond the build (wl-toplevel is a tree fixture).
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-foreign-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
rc="$work/rc.lua"
kiln_pid=""
probe_pid=""

cleanup() {
	[ -n "$probe_pid" ] && kill "$probe_pid" 2>/dev/null || true
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

# The rc under test: one tag per screen, the STOCK kiln.defaults left in place
# (this config never mentions foreign-toplevel, which is the point), plus a
# recorder that keeps the last request::activate's facts for readback. The
# recorder runs ALONGSIDE the default, it does not replace it.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
end)
client.on("request::activate", function(c, ctx)
	LAST_ACTIVATE = { valid = ctx.valid, app = c.app_id }
end)
EOF

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

check "the compositor booted" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"

# The Wayland socket kiln opened, so the fixture connects to the same compositor
# (shared XDG_RUNTIME_DIR). The IPC eval socket ($sock) is separate.
wl="$(sed -n 's/.*WAYLAND_DISPLAY=\([^ ]*\).*/\1/p' "$log" | head -n1)"
check "kiln announced a wayland socket" "yes" \
	"$([ -n "$wl" ] && echo yes || echo no)"

ft() { WAYLAND_DISPLAY="$wl" "$repo/build/wl-toplevel" "$@"; }
prop() { # app_id lua-expr-over-c
	eval_kiln "for _, c in ipairs(client.all()) do
	  if c.app_id == '$1' then return tostring($2) end
	end
	return 'no-client'"
}
last() { eval_kiln "return LAST_ACTIVATE and tostring(LAST_ACTIVATE.$1) or 'nil'"; }
# The manager line for a given app_id: "title|app_id|state", or "-" if absent.
ft_line() { ft list | awk -F'|' -v a="$1" '$2 == a { print; found=1 } END { if (!found) print "-" }'; }

# =====================================================================
echo "== the observed window maps and the manager advertises it"
WAYLAND_DISPLAY="$wl" "$repo/build/wl-toplevel" open kiln.ft.probe "kiln ft probe" &
probe_pid=$!
sleep 2

check "the probe mapped in kiln" "true" "$(prop kiln.ft.probe 'c.mapped ~= false')"
# The manager, fed from the map site, shows the right title and app_id. State is
# "activated" because focus-on-open ran set_activated, and that verb mirrors to
# the foreign handle (the write-only feed at the hint site).
check "the manager lists the probe title and app_id, activated" \
	"kiln ft probe|kiln.ft.probe|activated" "$(ft_line kiln.ft.probe)"

# =====================================================================
echo "== a foreign activate is seat-backed (the named question)"
ft activate kiln.ft.probe
sleep 1
# valid=true, from event->seat != NULL: a real taskbar activate carries the seat,
# so it arrives user-initiated, UNLIKE an X11 activate, which is valid=false.
check "C derived valid=true from the foreign activate's seat" "true" "$(last valid)"
check "the request rode the existing request::activate (right client)" \
	"kiln.ft.probe" "$(last app)"

# =====================================================================
echo "== a foreign minimize round-trips as the existing request event"
ft minimize kiln.ft.probe
sleep 1
# set_minimized -> ft_request_minimize -> queue_client_request_minimize ->
# request::minimize -> kiln.defaults.minimize -> c.minimized = true. The single
# dispatch path, proven by the property landing.
check "the minimize round-tripped to c.minimized" "true" \
	"$(prop kiln.ft.probe 'c.minimized == true')"
# And the mirror pushed it back out: the manager now advertises minimized (the
# new set_minimized_hint verb via property::minimized).
check "the manager now advertises the probe minimized" "yes" \
	"$(ft_line kiln.ft.probe | grep -q minimized && echo yes || echo no)"

# =====================================================================
# No bus error, no duplicate-tree watchdog line snuck through.
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

check "no bus errors, no tree/scene divergence, no duplicate ids" "0" \
	"$(grep -cE "error in '|tree==scene:|DUPLICATE" "$log" || true)"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
[ "$fail" = 0 ] && echo PASS || { echo FAIL; exit 1; }
