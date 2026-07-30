#!/bin/sh
# The edge-aware float battery: a menu chain and a tooltip opened hard against the
# right and bottom edges, asserted to sit inside the workarea.
#
#   scripts/float-test.sh
#
# Pure headless. A float's placement is declaration plus one solve, and every
# assertion below is core.box arithmetic, so none of it needs an input device.
# Hover is RESTATED the way tooltip-test.sh restates it (walk core.hits
# innermost-first, fire the first handler): what that proves is routing and
# geometry, not that a pointer moved.
#
# THE PAIRED CONTROL IS THE POINT. The same script runs on the pre-fix build and
# the fixed one, because `fit` lives in menu.lua and tooltip.lua rather than in
# the rc below. Legs 1-5 must go RED before the fix and green after. Legs 6-8 are
# controls and must be GREEN ON BOTH ARMS:
# without them, a helper that shoved every float around would pass 1-5 and look
# correct. Geometry here is deterministic, so a red is a red; a pre-fix arm that
# will not go red means the probe is wrong.
#
# THE SETTLE FRAME IS REAL, and named. The fit is arithmetic over the last
# solve's boxes, so a float that has never been declared has no size yet and
# lands uncorrected for exactly one frame. It marks its screen for the frame
# that corrects it; settle() below is that frame, waited for explicitly rather
# than hidden inside the open.
#
# Needs: nothing but the compositor. No clients are mapped.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-float-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
rc="$work/rc.lua"
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

# The rc under test: two bars, four glyphs, one menu with one submenu. The
# glyphs are placed by ui.spacer() rather than by coordinate, so where the edges
# are is the compositor's answer and not this script's assumption.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
local ui, th = kiln.ui, kiln.theme

MENU = {
	{ "one", function() end },
	{ "apps", {
		{ "editor", function() end },
		{ "browser", function() end },
		{ "files", function() end },
	} },
	{ "three", function() end },
}

screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
	ui.bar(s, { edge = "top", h = 28, color = th.bg }, function()
		ui.box({ id = "leftglyph", w = 20, h = 20, color = th.accent })
		ui.spacer()
		-- Long on purpose: centered on a glyph 18px from the right edge, this
		-- text cannot fit, and no mirror can save it (a center attach point
		-- mirrors to itself). It is the leg that isolates the clamp.
		ui.box({ id = "rightglyph", w = 20, h = 20, color = th.accent,
			on_hover = ui.tooltip(
				"a tooltip long enough to overhang the right edge") })
	end)
	ui.bar(s, { edge = "bottom", h = 28, color = th.bg }, function()
		ui.box({ id = "downglyph", w = 20, h = 20, color = th.accent,
			on_hover = ui.tooltip("from the bottom") })
		ui.spacer()
		ui.box({ id = "cornerglyph", w = 20, h = 20, color = th.accent })
	end)
end)
EOF

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

# --- the readbacks.

# box: an element's solved box, "x,y wxh". Clay's element hashmap is persistent
# and core.box answers with the LAST box an id ever had, so this is geometry only
# and never an existence test. Every id read below is known live.
box() {
	eval_kiln "
local b = core.box(\"$1\")
return b == nil and '-' or
  string.format('%d,%d %dx%d', b.x, b.y, b.width, b.height)"
}

# inside: is this box wholly within the screen's workarea? THE claim, in one
# predicate, restated from screen.workarea rather than from any number this
# script knows.
inside() { # id
	eval_kiln "
local s = screen.all()[1]
local wa = s.workarea
local b = core.box(\"$1\")
if b == nil then return 'no-box' end
if wa == nil then return 'no-workarea' end
return tostring(b.x >= wa.x and b.y >= wa.y
  and b.x + b.width <= wa.x + wa.width
  and b.y + b.height <= wa.y + wa.height)"
}

# press: init.lua's on_button dispatch, restated -- walk core.hits
# innermost-first and fire the first handler found (menu-test.sh's discipline).
press() {
	eval_kiln "
local st = require('kiln.state')
local s = screen.all()[1]
local b = core.box(\"$1\")
if b == nil then return 'no-box' end
local presses = st.screen_presses[s.name] or {}
for _, h in ipairs(core.hits(s.name, b.x + b.width / 2, b.y + b.height / 2)) do
  local fn = presses['on_press:' .. h.name .. '#' .. h.index]
  if fn ~= nil then
    fn()
    core.dirty()
    return h.name
  end
end
return 'no-handler'"
	sleep 0.6
}

# hover: init.lua's on_hover, restated (tooltip-test.sh's helper, verbatim).
hover() { # id
	eval_kiln "
local st = require('kiln.state')
local s = screen.all()[1]
local b = core.box(\"$1\")
if b == nil then return 'no-box' end
local x, y = b.x + b.width / 2, b.y + b.height / 2
local presses = st.screen_presses[s.name] or {}
local hit, fn
for _, h in ipairs(core.hits(s.name, x, y)) do
  local f = presses['on_hover:' .. h.name .. '#' .. h.index]
  if f ~= nil then h.screen = s.name hit, fn = h, f break end
end
if fn == nil then core.dirty() return 'no-handler' end
if HOVERED ~= nil then HOVERED.fn(false, HOVERED.hit) end
HOVERED = { fn = fn, hit = hit }
fn(true, hit)
core.dirty()
return hit.name"
	sleep 0.6
}

set_lua() {
	eval_kiln "$1
core.dirty()" >/dev/null
	sleep 0.6
}

# The settle frame, waited for explicitly: a float declared for the first time
# has no size to fit against and corrects on the frame after. The helper marks
# its own screen, so this is a wait, not a nudge.
settle() {
	sleep 0.6
}

open_menu() { # lua-expr-for-cfg-fields
	set_lua "local s = screen.all()[1]
local wa, th = s.workarea, require('kiln').theme
require('kiln').ui.menu { items = MENU, screen = s, $1 }"
	settle
}

# Two facts everything below rests on.
check "the workarea is inset by both bars" "true" \
	"$(eval_kiln 'local s = screen.all()[1]
local wa = s.workarea
return tostring(wa ~= nil and wa.y >= 28
  and wa.y + wa.height <= s.height - 28)')"
check "the right-edge glyph really is at the right edge" "true" \
	"$(eval_kiln 'local s = screen.all()[1]
local g = core.box("rightglyph")
return tostring(g ~= nil and g.x + g.width >= s.width - 16)')"

# --- 1. a root menu dropped at the bottom-right corner. Clay puts a root float
# exactly at its offset and asks nothing; the corner is 20px from two edges and
# the column is menu_width wide and one row per item tall, so pre-fix this hangs
# off both.
open_menu "x = s.width - 20, y = s.height - 20"
check "1. a menu at the bottom-right corner sits inside the workarea" "true" \
	"$(inside menu:box)"

# --- 2. a menu dropped from a bar glyph at the right edge. Both corrections fire
# and they are asserted separately, because "inside" alone cannot tell a mirror
# from a slide: the MIRROR is what puts the right edges flush (the menu opens
# leftward off the glyph), and the CLAMP is what puts its top on the workarea top.
#
# That clamp is also what moved the menu's top edge: it used to start at the
# glyph's bottom edge, 4px up inside the bar, and now starts below the bar. Not a
# coincidence to hide -- the bar is not workarea, so a float clamped to the
# workarea cannot overlap it.
open_menu "under = 'rightglyph'"
check "2. a menu under a right-edge glyph sits inside the workarea" "true" \
	"$(inside menu:box)"
check "2. the mirror put its right edge on the glyph's right edge" "true" \
	"$(eval_kiln 'local g, m = core.box("rightglyph"), core.box("menu:box")
if g == nil or m == nil then return "no-box" end
return tostring(m.x + m.width == g.x + g.width)')"
check "2. the clamp put its top on the workarea top, below the bar" "true" \
	"$(eval_kiln 'local wa = screen.all()[1].workarea
local m = core.box("menu:box")
if m == nil or wa == nil then return "no-box" end
return tostring(m.y == wa.y)')"

# --- 3. the chain. The ROOT is opened flush with the workarea's right edge so it
# fits exactly and only the SUBMENU overflows: that keeps the row pressable on
# both arms, so a red here is the submenu's box and nothing else.
open_menu "x = wa.x + wa.width - th.menu_width, y = wa.y"
check "3. the root, placed to fit exactly, is inside and unmoved" "true" \
	"$(eval_kiln 'local s = screen.all()[1]
local wa, m = s.workarea, core.box("menu:box")
local th = require("kiln").theme
if m == nil then return "no-box" end
return tostring(m.x == wa.x + wa.width - th.menu_width and m.y == wa.y)')"
check "3. pressing the submenu row dispatches to it" "menu:/2" "$(press menu:/2)"
settle
check "3. the submenu is inside the workarea" "true" "$(inside menu:box/2)"
check "3. and it opened to the LEFT of its row, not off the edge" "true" \
	"$(eval_kiln 'local row, sub = core.box("menu:/2"), core.box("menu:box/2")
if row == nil or sub == nil then return "no-box" end
return tostring(sub.x + sub.width == row.x and sub.y == row.y)')"

# --- 4. the other corner: a menu under a glyph in the BOTTOM bar at the right
# edge. Both axes mirror -- right edges flush, and the column grows upward off
# the glyph's top instead of downward off its bottom -- then the clamp seats its
# bottom on the workarea's.
open_menu "under = 'cornerglyph'"
check "4. a menu under a bottom-right glyph sits inside the workarea" "true" \
	"$(inside menu:box)"
check "4. it mirrored on both axes: right edges flush, opening upward" "true" \
	"$(eval_kiln 'local wa = screen.all()[1].workarea
local g, m = core.box("cornerglyph"), core.box("menu:box")
if g == nil or m == nil then return "no-box" end
return tostring(m.x + m.width == g.x + g.width
  and m.y + m.height == wa.y + wa.height)')"
# The menu's scrim covers the screen and captures every hit, so it has to come
# down before a hover leg can reach a bar glyph at all.
set_lua 'require("kiln.menu").close()'

# --- 5. the clamp where no mirror can help. A tooltip attaches center-to-center
# on its x axis, and a center attach point mirrors to itself, so the overhang
# off a right-edge glyph has exactly one answer: slide it back inside. This is
# the leg that would still be red if the fix were a flip and nothing else.
check "5. hovering the right-edge glyph raises its tooltip" "rightglyph" \
	"$(hover rightglyph)"
settle
check "5. the tooltip is inside the workarea" "true" "$(inside tooltip)"
check "5. the clamp seated its right edge on the workarea's, off-center" "true" \
	"$(eval_kiln 'local wa = screen.all()[1].workarea
local g, t = core.box("rightglyph"), core.box("tooltip")
if g == nil or t == nil then return "no-box" end
return tostring(t.x + t.width == wa.x + wa.width
  and (t.x + t.width / 2) ~= (g.x + g.width / 2))')"

# --- 6. CONTROL, green on both arms. A float with room around it is not touched.
# Without this leg a helper that dragged every float to the workarea origin would
# pass every assertion above.
open_menu "x = 100, y = 100"
check "6. control: a menu with room around it is not moved at all" "100,100" \
	"$(eval_kiln 'local m = core.box("menu:box")
if m == nil then return "no-box" end
return string.format("%d,%d", m.x, m.y)')"

# --- 7. The vertical flip tooltip.lua once hand-rolled, now the helper's mirror:
# a tooltip on a bottom-bar widget opens ABOVE it. Restated from the two boxes, so
# it holds whichever code does it, and it is a CONTROL: green on both arms, the
# hand-rolled behavior surviving its own deletion.
#
# Its second leg is not a control and is not labelled one. The glyph sits 8px
# from the LEFT edge, so a tooltip centered on it overhangs the other way, and
# only the clamp brings it back. Red pre-fix like 1-5.
set_lua 'require("kiln.menu").close()
require("kiln.tooltip").hide()'
check "7. hovering the bottom-bar glyph raises its tooltip" "downglyph" \
	"$(hover downglyph)"
settle
check "7. control: it opens above its widget, not off the bottom" "true" \
	"$(eval_kiln 'local th = require("kiln").theme
local g, t = core.box("downglyph"), core.box("tooltip")
if g == nil or t == nil then return "no-box" end
return tostring(t.y + t.height == g.y - th.tooltip_gap)')"
check "7b. the same clamp catches the LEFT edge, and is inside" "true" \
	"$(inside tooltip)"

# --- 8. CONTROL, green on both arms. The compositor stayed clean: no Lua errors
# on the bus, no tree-vs-scene divergence from the always-on reconciler checks.
# The pattern is "error in '": init.lua's on_error override is what prints.
# KILN_BUS_PROBE=1 raises one real error through bus.lua's pcall, so this leg
# MUST go red under it, which is what makes the green mean anything.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

noise=$(grep -cE "error in '|tree==scene:" "$log" || true)
check "8. control: no bus errors, no tree/scene divergence" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
