#!/bin/sh
# The systray battery: org.kde.StatusNotifierWatcher owned in C, each item
# proxied, and every decision about what the tray shows made in Lua.
#
#   scripts/tray-test.sh
#
# Pure headless, and the DBus half is REAL. A private session bus is started
# under $work, kiln is booted onto it, and a scripted StatusNotifierItem
# (scripts/sni-item.py) registers the way nm-applet's would, over the wire. The
# watcher reads the item's properties BACK off the bus (this is the one service
# that is also a client), so the fixture has to be a real exported object, not a
# gdbus one-liner. The signals kiln emits are read off a `gdbus monitor` on the
# same bus.
#
# PRESSES ARE RESTATED, NOT DRIVEN. Headless has no pointer, so a press on a tray
# cell is dispatched by looking its handler up in the press table the declare
# built (the state.screen_presses idiom notify-test and menu-test use). What that
# proves is the ROUTING (the cell registered under an id the hit test reaches)
# and, through the real method call that lands at the fixture, the DISPATCH. It
# does not claim a mouse moved.
#
# EXISTENCE IS ASSERTED THROUGH core.hits, NEVER core.box: Clay's element hashmap
# is persistent, so core.box keeps answering with the last box an id ever had. A
# tray icon that appears and then leaves is exactly the case that bites.
#
# MANUAL, not claimed passed: nm-applet on a live session sits in the bar, its
# icon renders, a real click activates it, and it leaves the tray when the applet
# quits. That leg needs a seat, so it is run by hand and never asserted here.
#
# Needs: dbus-daemon, gdbus, python3 with gi (PyGObject).
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-tray-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
buslog="$work/bus.log"
rc="$work/rc.lua"
mpix="$work/marker-pix"
mname="$work/marker-name"
: >"$mpix"
: >"$mname"
kiln_pid=""
bus_pid=""
mon_pid=""
pix_pid=""
name_pid=""

cleanup() {
	[ -n "$pix_pid" ] && kill "$pix_pid" 2>/dev/null || true
	[ -n "$name_pid" ] && kill "$name_pid" 2>/dev/null || true
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

wget_prop() { # property -> the watcher property, verbatim
	gdbus call --session --dest org.kde.StatusNotifierWatcher \
		--object-path /StatusNotifierWatcher \
		--method org.freedesktop.DBus.Properties.Get \
		org.kde.StatusNotifierWatcher "$1"
}

# The rc under test: one tag and a top bar carrying widgets.systray, and nothing
# else. widgets.systray is a PLACED widget (unlike the notification display,
# which floats itself), so a tray needs a bar to sit in, and this is the
# smallest one.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
local ui = kiln.ui
local widgets = kiln.widgets
local th = kiln.theme
screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
	ui.bar(s, { edge = "top", h = 28, color = th.bg }, function()
		widgets.systray()
		ui.spacer()
	end)
end)
EOF

# A private session bus, so the battery never touches the developer's own and a
# real tray host on the box cannot steal the name.
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

# Everything the watcher says back to the bus lands here.
gdbus monitor --session --dest org.kde.StatusNotifierWatcher > "$buslog" 2>&1 &
mon_pid=$!
sleep 0.5

sname=$(eval_kiln 'return screen.all()[1].name')

# The registry, by service. Returns the field asked for, or "absent".
field() { # service field
	eval_kiln "for _, it in ipairs(require('kiln.systray').items()) do
		if it.service == '$1' then return it.$2 end
	end
	return 'absent'"
}
count() { eval_kiln 'return #require("kiln.systray").items()'; }
# The cell is on screen: hit-tested at its own center, not read from a stale map.
live() { # id -> live | absent
	eval_kiln "local b = core.box('$1')
	if b == nil then return 'absent' end
	local hits = core.hits('$sname', b.x + b.width / 2, b.y + b.height / 2)
	for _, h in ipairs(hits) do
		if h.name == '$1' then return 'live' end
	end
	return 'absent'"
}

echo "== the watcher"
check "a host is registered (clients gate on this)" "(<true>,)" \
	"$(wget_prop IsStatusNotifierHostRegistered)"
check "no items yet" "0" "$(count)"

echo "== a pixmap item registers, pixels to the cache"
python3 "$repo/scripts/sni-item.py" org.ktest.Pixmap pixmap "$mpix" \
	>"$work/pix.log" 2>&1 &
pix_pid=$!
sleep 1
check "the watcher lists it" "1" \
	"$(wget_prop RegisteredStatusNotifierItems | grep -c 'org.ktest.Pixmap' || true)"
check "one item in the registry" "1" "$(count)"
check "its id is the item's own" "test-item" "$(field org.ktest.Pixmap id)"
check "its status came through" "Active" "$(field org.ktest.Pixmap status)"
# The pixmap became a cache key, not a name: the pixels stopped in C.
check "its icon is a cache key" "tray:org.ktest.Pixmap" \
	"$(field org.ktest.Pixmap icon)"
check "and its cell is on screen" "live" "$(live tray:org.ktest.Pixmap)"

echo "== a name item registers, the name passes through"
python3 "$repo/scripts/sni-item.py" org.ktest.Named name "$mname" \
	>"$work/name.log" 2>&1 &
name_pid=$!
sleep 1
check "two items now" "2" "$(count)"
# No pixmap, so the IconName is the icon fact, verbatim; the theme lookup over it
# is Lua's, and is the missing step this cell renders around.
check "its icon is the passed-through name" "network-wireless" \
	"$(field org.ktest.Named icon)"
check "and its cell is on screen" "live" "$(live tray:org.ktest.Named)"

echo "== NewStatus updates the item in place"
gdbus call --session --dest org.ktest.Pixmap --object-path /Control \
	--method test.Fixture.SetStatus "NeedsAttention" >/dev/null
sleep 0.6
check "still two items, not three" "2" "$(count)"
check "the status updated in place" "NeedsAttention" \
	"$(field org.ktest.Pixmap status)"

echo "== a press forwards Activate to the item"
# Restated, not clicked: the handler the declare registered, called by the id the
# hit test would have found. The method call after it is real, over the bus.
eval_kiln "local st = require('kiln.state')
local p = st.screen_presses['$sname'] or {}
local h = p['on_press:tray:org.ktest.Pixmap#0']
if h ~= nil then h() end" >/dev/null
sleep 0.6
check "the item received a real Activate" "1" \
	"$(grep -c '^Activate' "$mpix" || true)"

echo "== a scroll forwards Scroll to the item"
eval_kiln "local st = require('kiln.state')
local p = st.screen_presses['$sname'] or {}
local h = p['on_scroll:tray:org.ktest.Pixmap#0']
if h ~= nil then h({ dx = 0, dy = 15, mods = {} }) end" >/dev/null
sleep 0.6
check "the item received a real Scroll" "1" \
	"$(grep -c '^Scroll' "$mpix" || true)"

echo "== the item leaves when its name vanishes"
kill "$pix_pid" 2>/dev/null || true
pix_pid=""
sleep 0.8
check "one item left" "1" "$(count)"
check "the pixmap item is gone from the registry" "absent" \
	"$(field org.ktest.Pixmap icon)"
check "and its cell is off screen" "absent" "$(live tray:org.ktest.Pixmap)"
check "StatusNotifierItemUnregistered went out" "1" \
	"$(grep -c 'StatusNotifierItemUnregistered.*org.ktest.Pixmap' "$buslog" || true)"

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

noise=$(grep -cE "error in '|tree==scene:|DUPLICATE|dbus: process failed" "$log" || true)
check "no bus errors, no tree/scene divergence" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
[ "$fail" = 0 ] && echo PASS || { echo FAIL; exit 1; }
