#!/bin/sh
# The notifications battery: org.freedesktop.Notifications answered in C, and
# every decision about a notification made in Lua.
#
#   scripts/notify-test.sh
#
# Pure headless, and the DBus half is REAL: a private session bus is started
# under $work, kiln is booted onto it, and the notifications arrive the way any
# app's would, over the wire from gdbus. The signals coming back out are read off
# a `gdbus monitor` running against the same bus. Nothing about the DBus leg is
# simulated; the id in the reply is the id the compositor minted.
#
# PRESSES ARE RESTATED, NOT DRIVEN. Headless has no pointer
# (WLR_LIBINPUT_NO_DEVICES=1), so a press on an action button is dispatched by
# looking its handler up in the press table the declare just built, the discipline
# menu-test.sh and rc-test.sh use. What that proves is the ROUTING (the button
# registered under an id the hit test can reach) and, through the signal that
# comes back over the bus, the DISPATCH. It does not claim a mouse moved.
#
# EXISTENCE IS ASSERTED THROUGH core.hits, NEVER core.box. Clay's element hashmap
# is persistent, so core.box keeps answering with the last box an id ever had,
# long after it stops being declared. A notification that appears and then expires
# is exactly the case that bites, so `live` probes the hit instead.
#
# MANUAL, not claimed passed: a real notify-send with an icon and actions on a
# live session, a real mouse press on the button, and the app seeing its
# ActionInvoked. That leg needs a seat, so it is run by hand and never asserted
# here.
#
# Needs: dbus-daemon, gdbus.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-notify-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
buslog="$work/bus.log"
rc="$work/rc.lua"
kiln_pid=""
bus_pid=""
mon_pid=""

cleanup() {
	[ -n "$mon_pid" ] && kill "$mon_pid" 2>/dev/null || true
	[ -n "$kiln_pid" ] && kill "$kiln_pid" 2>/dev/null || true
	[ -n "$bus_pid" ] && kill "$bus_pid" 2>/dev/null || true
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

notify() { # app replaces icon summary body actions hints timeout
	gdbus call --session \
		--dest org.freedesktop.Notifications \
		--object-path /org/freedesktop/Notifications \
		--method org.freedesktop.Notifications.Notify \
		"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

# The rc under test: one tag per screen and nothing else. The notification display
# is the SHIPPED DEFAULT (kiln.defaults.notify_display), declared by the runtime;
# this config does not mention notifications at all, which is the point.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
end)
EOF

# A private session bus, so the battery never touches the developer's own and a
# real notification daemon on the box cannot steal the name.
addr=$(dbus-daemon --session --print-address --fork --print-pid=3 3>"$work/bus.pid")
bus_pid=$(cat "$work/bus.pid")
export DBUS_SESSION_BUS_ADDRESS="$addr"

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

# Everything the compositor says back to the bus lands here.
gdbus monitor --session --dest org.freedesktop.Notifications > "$buslog" 2>&1 &
mon_pid=$!
sleep 0.5

sname=$(eval_kiln 'return screen.all()[1].name')

echo "== the service"
check "kiln owns the name" \
	"('kiln', 'kiln', '0.1', '1.2')" \
	"$(gdbus call --session --dest org.freedesktop.Notifications \
		--object-path /org/freedesktop/Notifications \
		--method org.freedesktop.Notifications.GetServerInformation)"
check "capabilities are static" \
	"(['body', 'actions', 'icon-static'],)" \
	"$(gdbus call --session --dest org.freedesktop.Notifications \
		--object-path /org/freedesktop/Notifications \
		--method org.freedesktop.Notifications.GetCapabilities)"

echo "== a notification with actions"
# expire_timeout 0 is the client refusing to expire, so this one stays put until
# the battery closes it: no sleep race anywhere below.
id1=$(notify "build" 0 "" "Build finished" "3 warnings" \
	'["open", "Open log", "rerun", "Rerun"]' '{}' 0)
check "Notify replies with a minted id" "(uint32 1,)" "$id1"
sleep 0.6
check "one live notification" "1" "$(eval_kiln 'return #notification.all()')"
check "summary and body are the title and message" \
	"Build finished	3 warnings" \
	"$(eval_kiln 'local n = notification.all()[1]; return n.title, n.message')"
check "both actions round-tripped, in order" \
	"2	open	Open log	rerun	Rerun" \
	"$(eval_kiln 'local a = notification.all()[1].actions
	return #a, a[1].key, a[1].label, a[2].key, a[2].label')"

# The box is on screen: hit-tested at its own center, not read out of a stale
# element map.
live() { # id -> live | absent
	eval_kiln "local b = core.box('$1')
	if b == nil then return 'absent' end
	local hits = core.hits('$sname', b.x + b.width / 2, b.y + b.height / 2)
	for _, h in ipairs(hits) do
		if h.name == '$1' then return 'live' end
	end
	return 'absent'"
}
check "the popup is declared and hittable" "live" "$(live notification:1)"

echo "== the action button dispatches ActionInvoked"
# Restated, not clicked: the handler the declare registered, called by the id the
# hit test would have found. The DBus round trip after it is real.
eval_kiln "local st = require('kiln.state')
local p = st.screen_presses['$sname'] or {}
local h = p['on_press:notification:1:action#1']
if h ~= nil then h() end" >/dev/null
sleep 0.6
check "ActionInvoked went out with the pressed key" "1" \
	"$(grep -c 'ActionInvoked (uint32 1, .open.)' "$buslog" || true)"
# Invoking an action closes the notification (policy, in Lua): reason 2.
check "and it closed as dismissed (reason 2)" "1" \
	"$(grep -c 'NotificationClosed (uint32 1, uint32 2)' "$buslog" || true)"
check "nothing live after the action" "0" \
	"$(eval_kiln 'return #notification.all()')"
check "and the popup is gone from the scene" "absent" "$(live notification:1)"

echo "== replaces_id updates in place"
id2=$(notify "volume" 0 "" "Volume" "40%" '[]' '{"value": <int32 40>}' 0)
check "a fresh id" "(uint32 2,)" "$id2"
sleep 0.6
back=$(notify "volume" 2 "" "Volume" "42%" '[]' '{"value": <int32 42>}' 0)
check "replacing answers with the same id" "(uint32 2,)" "$back"
sleep 0.6
check "still ONE notification, not two" "1" "$(eval_kiln 'return #notification.all()')"
check "and its body updated" "42%" "$(eval_kiln 'return notification.all()[1].message')"

echo "== the value hint drives a progress fill"
check "value passed through as a scalar" "42" \
	"$(eval_kiln 'return notification.all()[1].value')"
# The fill is 42% of the bar, solved by Clay. Read both boxes back and compare the
# ratio, which is what "drives the fill" means: no magic pixel constant.
check "the fill solves to 42% of the bar" "42" \
	"$(eval_kiln 'local bar = core.box("notification:2:bar")
	local fill = core.box("notification:2:fill")
	if bar == nil or fill == nil then return "no bar" end
	return math.floor(fill.width / bar.width * 100 + 0.5)')"

echo "== CloseNotification"
gdbus call --session --dest org.freedesktop.Notifications \
	--object-path /org/freedesktop/Notifications \
	--method org.freedesktop.Notifications.CloseNotification 2 >/dev/null
sleep 0.6
check "the client's close dismissed it" "0" "$(eval_kiln 'return #notification.all()')"
check "NotificationClosed reason 3 (closed by call)" "1" \
	"$(grep -c 'NotificationClosed (uint32 2, uint32 3)' "$buslog" || true)"

echo "== the timeout expires it, in Lua"
notify "slow" 0 "" "Expiring" "gone in a second" '[]' '{}' 1000 >/dev/null
sleep 0.6
check "live before its timeout" "1" "$(eval_kiln 'return #notification.all()')"
sleep 1.2
check "gone after it" "0" "$(eval_kiln 'return #notification.all()')"
check "NotificationClosed reason 1 (expired)" "1" \
	"$(grep -c 'NotificationClosed (uint32 3, uint32 1)' "$buslog" || true)"

echo "== critical ignores the timeout"
notify "urgent" 0 "" "Critical" "stays" '[]' '{"urgency": <byte 2>}' 1000 >/dev/null
sleep 1.5
check "still there after its timeout passed" "1" \
	"$(eval_kiln 'return #notification.all()')"
check "and it knows it is critical" "critical" \
	"$(eval_kiln 'return notification.all()[1].urgency')"
eval_kiln 'notification.all()[1]:dismiss("user")' >/dev/null
sleep 0.3

echo "== suspension queues instead of showing"
eval_kiln 'notification.suspended = true' >/dev/null
notify "quiet" 0 "" "Held" "while suspended" '[]' '{}' 0 >/dev/null
sleep 0.6
check "nothing visible" "0" "$(eval_kiln 'return #notification.all()')"
check "one pending" "1" "$(eval_kiln 'return #notification.pending')"
check "and nothing was declared" "absent" "$(live notification:5)"
eval_kiln 'notification.suspended = false' >/dev/null
sleep 0.6
check "unsuspending shows the queue" "1" "$(eval_kiln 'return #notification.all()')"
check "pending is empty again" "0" "$(eval_kiln 'return #notification.pending')"
check "and the popup is on screen" "live" "$(live notification:5)"

echo "== the image-data hint: pixels to the cache, a key on the event"
eval_kiln 'notification.all()[1]:dismiss("user")' >/dev/null
sleep 0.3
# A 2x2 RGBA image, sent inline the way an app with no icon file on disk does.
# The pixels never reach Lua: C decodes them into the image cache and the event
# carries the key, which the display hands to ui.image like any path.
notify "pixels" 0 "" "Inline icon" "2x2" '[]' \
	'{"image-data": <(2, 2, 8, true, 8, 4, @ay [255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255])>}' 0 >/dev/null
sleep 0.6
check "the icon is a cache key, not pixels" "notify:6" \
	"$(eval_kiln 'return notification.all()[1].icon')"
check "and the image leaf is on screen" "live" "$(live notification:6:icon)"

# The client's own numbers say 64x64 but it sent four bytes. Reading that buffer
# is reading off the end of it, so the hint is refused: no icon, no crash, and
# the notification still arrives.
notify "liar" 0 "" "Bad pixels" "short buffer" '[]' \
	'{"image-data": <(64, 64, 256, true, 8, 4, @ay [1,2,3,4])>}' 0 >/dev/null
sleep 0.6
check "a short image-data buffer is refused, not read" "nil" \
	"$(eval_kiln 'return tostring(notification.all()[2].icon)')"
check "and the notification still arrived" "Bad pixels" \
	"$(eval_kiln 'return notification.all()[2].title')"

# image-path is not typed and needs no code: it is a scalar, so it rides the
# passthrough table and the display ranks it below inline pixels.
notify "path" 0 "" "Path icon" "" '[]' \
	'{"image-path": <"/nonexistent/icon.png">}' 0 >/dev/null
sleep 0.6
check "image-path passes through and is chosen" "/nonexistent/icon.png" \
	"$(eval_kiln 'return notification.all()[3].icon')"
eval_kiln 'for _, n in ipairs({ notification.all()[1], notification.all()[2],
	notification.all()[3] }) do n:dismiss("user") end' >/dev/null
sleep 0.3

echo "== a notification raised in the compositor never touches the bus"
before=$(grep -c 'NotificationClosed' "$buslog" || true)
eval_kiln 'local kiln = require("kiln")
local n = kiln.notify { title = "local", message = "no dbus", timeout = 0 }
n:dismiss("user")' >/dev/null
sleep 0.6
check "no id, so no signal" "$before" "$(grep -c 'NotificationClosed' "$buslog" || true)"

echo "== the log is clean"
# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's
# pcall, so this leg MUST go red under it.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

noise=$(grep -cE "error in '|tree==scene:|DUPLICATE" "$log" || true)
check "no bus errors, no tree/scene divergence" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
[ "$fail" = 0 ] && echo PASS || { echo FAIL; exit 1; }
