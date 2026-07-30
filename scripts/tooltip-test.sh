#!/bin/sh
# The tooltip + placement battery: ui.tooltip declared as a float off the hovered
# element, and the placement helpers as arithmetic over screen.workarea.
#
#   scripts/tooltip-test.sh
#
# Pure headless. A tooltip is declaration (open means declared, closed means not
# declared at all), and a placement helper is one write of c.float. Neither needs
# an input device.
#
# HOVER IS RESTATED, NOT DRIVEN. Headless has no pointer (WLR_LIBINPUT_NO_DEVICES=1),
# so this battery re-implements what init.lua's on_hover does with a motion event --
# walk core.hits innermost-first, take the first element carrying an on_hover
# handler, and fire the transition against the previous one -- and runs that walk
# against the same press table the declare just built. It is an independent
# restatement of the dispatch path (the discipline menu-test.sh uses for presses),
# so a tooltip that registers under an id nothing hits, or that never learns it was
# left, fails here instead of passing. What it proves is the ROUTING and the
# GEOMETRY. It does not claim a pointer moved.
#
# The real dispatcher's "pointer is over a client" case (ev.client ~= nil) and its
# "pointer is over bare chrome" case both reduce to the same fact -- no element
# under the pointer carries a hover handler -- and that is exactly the fact the
# leave legs below drive.
#
# MANUAL, not claimed passed: a real pointer is required, and the steps are these.
# Rest the pointer on the bar widget and watch the tooltip appear under it. Move the
# pointer onto a client and watch the tooltip go. Then place a floating client with
# placement.under_mouse and watch it land centered on the actual cursor, not on the
# last point this script wrote into state.
#
# Needs: foot.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-tooltip-test.XXXXXX)"
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

# The rc under test: two bars (the second one exists to put a widget in the bottom
# half of the screen, which is what forces the tooltip to flip above it), each
# carrying one tooltipped box, and a rule that places a floating client through the
# rule's own `on` callback. Public API only.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
local ui, rule = kiln.ui, kiln.rule
local widgets = kiln.widgets
local th = kiln.theme

-- The tooltip text as a function: it is read at declare, so the box is live with
-- no widget object and no update path. The only test scaffolding here.
TIP = "cpu 42%"

screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
	ui.bar(s, { edge = "top", h = 28, color = th.bg }, function()
		widgets.taglist(s)
		ui.box({
			id = "cpu", w = 60, h = 20, color = th.accent,
			on_hover = ui.tooltip(function() return TIP end),
		}, function() ui.text("cpu", { size = 12 }) end)
		ui.spacer()
	end)
	ui.bar(s, { edge = "bottom", h = 28, color = th.bg }, function()
		ui.box({
			id = "down", w = 60, h = 20, color = th.accent,
			on_hover = ui.tooltip("from the bottom"),
		}, function() ui.text("dn", { size = 12 }) end)
		ui.spacer()
	end)
end)

-- The rule path: `on` is a callback a rule already carries, so a placement
-- helper needs nothing new to be a rule prop.
rule {
	match_any = { app = { "foot" } },
	props = { floating = true },
	on = kiln.placement.centered,
}
EOF

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

wl_disp=$(sed -n 's/.*Running Wayland compositor on WAYLAND_DISPLAY=//p' "$log" | head -1)
WAYLAND_DISPLAY="$wl_disp" foot >"$work/foot.log" 2>&1 &
sleep 4

# --- the readbacks.
#
# box: an element's solved box. NOT an existence test: Clay's element hashmap is
# persistent and its lookup never checks generation, so core.box keeps answering
# with the LAST box an id ever had, long after it stops being declared. A tooltip
# is where that bites hardest -- a hidden tooltip still has a box forever -- so
# absence below is ALWAYS asserted through core.hits, never through this.
box() {
	eval_kiln "
local b = core.box(\"$1\")
return b == nil and '-' or
  string.format('%d,%d %dx%d', b.x, b.y, b.width, b.height)"
}

# live: is this id declared RIGHT NOW? core.hits names what the last solve actually
# put under a point, so an element that stopped being declared stops being named.
# A PASSTHROUGH float is still named (Clay adds it to the pointer-over ids; the
# capture mode only decides whether the walk stops there), which is what lets a
# passthrough tooltip be existence-tested at all.
live() {
	eval_kiln "
local s = screen.all()[1]
local b = core.box(\"$1\")
if b == nil then return 'absent' end
for _, h in ipairs(core.hits(s.name, b.x + b.width / 2, b.y + b.height / 2)) do
  if h.name == \"$1\" then return 'live' end
end
return 'absent'"
}

# hover: init.lua's on_hover, restated. Walk the hits innermost-first, take the
# first element carrying a hover handler (the innermost hit is usually an unnamed
# leaf -- a text run -- carrying nothing), and dispatch the TRANSITION: the element
# we were on is told it was left before the new one is told it was entered. HOVERED
# is this restatement's own memory, not the runtime's.
hover_at() { # x y
	eval_kiln "
local st = require('kiln.state')
local s = screen.all()[1]
local presses = st.screen_presses[s.name] or {}
local hit, fn
for _, h in ipairs(core.hits(s.name, $1, $2)) do
  local f = presses['on_hover:' .. h.name .. '#' .. h.index]
  if f ~= nil then h.screen = s.name hit, fn = h, f break end
end
local key = hit ~= nil and (hit.name .. '#' .. hit.index) or nil
if HOVERED ~= nil and HOVERED.key ~= key then
  HOVERED.fn(false, HOVERED.hit)
  HOVERED = nil
end
if fn == nil then
  core.dirty()
  return 'no-handler'
end
HOVERED = { key = key, fn = fn, hit = hit }
fn(true, hit)
core.dirty()
return hit.name"
	sleep 0.6
}

# hover: the same, aimed at an element's own box center.
hover() { # id
	eval_kiln "
local b = core.box(\"$1\")
if b == nil then return 'no-box' end
return string.format('%d %d', b.x + b.width / 2, b.y + b.height / 2)" \
	| { read -r x y; hover_at "$x" "$y"; }
}

set_lua() {
	eval_kiln "$1
core.dirty()" >/dev/null
	sleep 0.6
}

# The one floating client, and the workarea every placement assert is restated
# against. Two facts have to hold before any of it means anything: the client is
# floating (so c.float is what the layout reads), and the workarea is genuinely
# inset by both bars (so "centered" below means centered in what is left after
# chrome, not centered on the output).
c="local c = screen.all()[1].selected_tag.clients[1]"
check "one floating client" "true" \
	"$(eval_kiln "$c
return tostring(c ~= nil and c.floating == true)")"
check "the workarea is inset by both bars" "true" \
	"$(eval_kiln 'local s = screen.all()[1]
local wa = s.workarea
return tostring(wa.y >= 28 and wa.y + wa.height <= s.height - 28)')"

# --- the rule path, which ran at map before any of this: `on = placement.centered`
# placed the client, and the expectation is restated from the workarea and the
# float box the helper actually wrote (not from a size this script assumes, because
# the size at map time is the client's own).
check "rule: on = placement.centered placed the client at map" "true" \
	"$(eval_kiln "$c
local wa = c.screen.workarea
local f = c.float
return tostring(
  f.x == wa.x + math.floor((wa.width - f.width) / 2) and
  f.y == wa.y + math.floor((wa.height - f.height) / 2))")"

# --- placement: a known float box in, one write out. Every expectation below is
# restated arithmetic over the workarea, never a number this script hardcodes and
# never a value obtained by calling the helper under test.
place() { # helper
	eval_kiln "$c
c.float = { x = 0, y = 0, width = 200, height = 100 }
require('kiln.placement').$1(c)
local f = c.float
return string.format('%d,%d %dx%d', f.x, f.y, f.width, f.height)"
}
expect() { # expr-for-x expr-for-y
	eval_kiln "$c
local wa = c.screen.workarea
local w, h = 200, 100
return string.format('%d,%d %dx%d', $1, $2, w, h)"
}

check "placement: centered" \
	"$(expect 'wa.x + math.floor((wa.width - w) / 2)' \
		'wa.y + math.floor((wa.height - h) / 2)')" \
	"$(place centered)"
check "placement: center_horizontal keeps y" \
	"$(expect 'wa.x + math.floor((wa.width - w) / 2)' '0')" \
	"$(place center_horizontal)"
check "placement: center_vertical keeps x" \
	"$(expect '0' 'wa.y + math.floor((wa.height - h) / 2)')" \
	"$(place center_vertical)"
check "placement: top_left is the workarea origin, not the output's" \
	"$(expect 'wa.x' 'wa.y')" "$(place top_left)"
check "placement: top_right" \
	"$(expect 'wa.x + wa.width - w' 'wa.y')" "$(place top_right)"
check "placement: bottom_left" \
	"$(expect 'wa.x' 'wa.y + wa.height - h')" "$(place bottom_left)"
check "placement: bottom_right" \
	"$(expect 'wa.x + wa.width - w' 'wa.y + wa.height - h')" "$(place bottom_right)"
# The four edges are edge-centered on the other axis: `left` is the left edge,
# vertically centered, not the top-left corner.
check "placement: left is edge-centered on the other axis" \
	"$(expect 'wa.x' 'wa.y + math.floor((wa.height - h) / 2)')" "$(place left)"
check "placement: right" \
	"$(expect 'wa.x + wa.width - w' 'wa.y + math.floor((wa.height - h) / 2)')" \
	"$(place right)"
check "placement: top" \
	"$(expect 'wa.x + math.floor((wa.width - w) / 2)' 'wa.y')" "$(place top)"
check "placement: bottom" \
	"$(expect 'wa.x + math.floor((wa.width - w) / 2)' 'wa.y + wa.height - h')" \
	"$(place bottom)"

# no_offscreen: pushed past each edge in turn, it comes back to the edge. The
# helper never moves a box that is already inside, which is the other half of the
# claim (a placement that always clamped would pass the four legs above by luck).
off() { # x-expr y-expr
	eval_kiln "$c
local wa = c.screen.workarea
local w, h = 200, 100
c.float = { x = $1, y = $2, width = w, height = h }
require('kiln.placement').no_offscreen(c)
local f = c.float
return string.format('%d,%d %dx%d', f.x, f.y, f.width, f.height)"
}
check "no_offscreen: past the left edge comes back to it" \
	"$(expect 'wa.x' 'wa.y')" "$(off 'wa.x - 500' 'wa.y')"
check "no_offscreen: past the top edge comes back to it" \
	"$(expect 'wa.x' 'wa.y')" "$(off 'wa.x' 'wa.y - 500')"
check "no_offscreen: past the right edge comes back to it" \
	"$(expect 'wa.x + wa.width - w' 'wa.y')" "$(off 'wa.x + wa.width + 500' 'wa.y')"
check "no_offscreen: past the bottom edge comes back to it" \
	"$(expect 'wa.x' 'wa.y + wa.height - h')" \
	"$(off 'wa.x' 'wa.y + wa.height + 500')"
check "no_offscreen: a box already inside is not moved" \
	"$(expect 'wa.x + 30' 'wa.y + 40')" "$(off 'wa.x + 30' 'wa.y + 40')"
# Bigger than the workarea: there is no placement that fits, so it pins to the
# origin rather than clamping to a negative offset off the other side.
check "no_offscreen: a client larger than the workarea pins to its origin" "true" \
	"$(eval_kiln "$c
local wa = c.screen.workarea
c.float = { x = -300, y = -300, width = wa.width + 400, height = wa.height + 400 }
require('kiln.placement').no_offscreen(c)
local f = c.float
return tostring(f.x == wa.x and f.y == wa.y)")"

# under_mouse: the pointer is a fact the motion event leaves in state, and headless
# never delivers one, so the fact is written directly here. This proves the
# ARITHMETIC (centered on the point, clamped into the workarea); that a real pointer
# writes that fact is the TTY manual leg.
check "under_mouse: centers the box on the pointer" "true" \
	"$(eval_kiln "$c
local st = require('kiln.state')
local wa = c.screen.workarea
local px = wa.x + math.floor(wa.width / 2)
local py = wa.y + math.floor(wa.height / 2)
st.pointer = { x = px, y = py, screen = c.screen.name }
c.float = { x = 0, y = 0, width = 200, height = 100 }
require('kiln.placement').under_mouse(c)
local f = c.float
return tostring(f.x == px - 100 and f.y == py - 50)")"
check "under_mouse: a pointer at the corner still lands on screen" "true" \
	"$(eval_kiln "$c
local st = require('kiln.state')
local wa = c.screen.workarea
st.pointer = { x = wa.x, y = wa.y, screen = c.screen.name }
c.float = { x = 0, y = 0, width = 200, height = 100 }
require('kiln.placement').under_mouse(c)
local f = c.float
return tostring(f.x == wa.x and f.y == wa.y)")"

# --- the tooltip. Closed is not declared: not hidden, not zero-sized, absent.
check "tooltip: nothing declared while nothing is hovered" "absent" "$(live tooltip)"

check "tooltip: hovering the widget dispatches to it" "cpu" "$(hover cpu)"
check "tooltip: the hover declared it" "live" "$(live tooltip)"
check "tooltip: it carries the text the widget gave it" "true" \
	"$(eval_kiln 'local b = core.box("tooltip")
return tostring(b ~= nil and b.width > 0 and b.height > 0)')"

# Placement, restated from the two solved boxes: the tooltip hangs 4px under the
# widget it describes, centered on it. Clay attaches it (the two attach points are
# center_bottom on the parent, center_top on the tooltip), so there is no
# arithmetic in the tooltip to get wrong -- which is exactly what this asserts.
check "tooltip: hangs under the widget, centered on it" "true" \
	"$(eval_kiln 'local w = core.box("cpu")
local t = core.box("tooltip")
if w == nil or t == nil then return "no-box" end
return tostring(t.y == w.y + w.height + 4 and
  math.abs((t.x + t.width / 2) - (w.x + w.width / 2)) <= 1)')"

# Passthrough: the tooltip is in the hit list at its own box (it is a real node),
# and so is whatever is under it. A capturing tooltip would swallow the press on
# the thing it describes; Clay only breaks the root walk on CAPTURE.
check "tooltip: does not swallow what is under it (passthrough)" "true" \
	"$(eval_kiln 'local s = screen.all()[1]
local t = core.box("tooltip")
local names = {}
for _, h in ipairs(core.hits(s.name, t.x + t.width / 2, t.y + t.height / 2)) do
  names[#names+1] = h.name
end
local me, under = false, false
for _, n in ipairs(names) do
  if n == "tooltip" then me = true else under = true end
end
return tostring(me and under)')"

# The text is read at declare, so a live tooltip needs no update path: change the
# source, re-declare, and the box changes with it.
w_before=$(eval_kiln 'return core.box("tooltip").width')
set_lua 'TIP = "cpu 42% -- a much longer line than before"'
check "tooltip: the text is read at declare, so it is live" "true" \
	"$(eval_kiln "return tostring(core.box('tooltip').width > $w_before)")"

# --- leave. This is the leg the shipped on_hover could not do at all: it fired on
# enter and never told an element it had been left, so a tooltip would have stayed
# up forever. A point carrying no hover handler is the same fact the runtime sees
# when the pointer crosses onto a client (ev.client) or onto bare chrome.
check "tooltip: the pointer moves to a point that handles no hover" "no-handler" \
	"$(hover_at 5 5)"
check "tooltip: leaving takes it down" "absent" "$(live tooltip)"

# Onto the client itself, which is the case the old early-return dropped.
check "tooltip: hovering the widget again brings it back" "cpu" "$(hover cpu)"
check "tooltip: back up" "live" "$(live tooltip)"
cx=$(eval_kiln "$c
local f = c.float
return string.format('%d %d', f.x + f.width / 2, f.y + f.height / 2)")
# shellcheck disable=SC2086
check "tooltip: moving onto a client handles no hover either" "no-handler" \
	"$(hover_at $cx)"
check "tooltip: and the client took it down too" "absent" "$(live tooltip)"

# --- the edge flip. Clay does not flip a float, so a tooltip declared under a
# bottom-bar widget would hang off the screen. The tooltip reads its target's box
# and swaps the attach pair when the target sits in the lower half: the assert is
# that the box lands ABOVE its widget, restated from the two boxes.
check "tooltip: hovering the bottom-bar widget dispatches to it" "down" \
	"$(hover down)"
check "tooltip: on a bottom widget it flips above, not off the screen" "true" \
	"$(eval_kiln 'local w = core.box("down")
local t = core.box("tooltip")
if w == nil or t == nil then return "no-box" end
local s = screen.all()[1]
return tostring(t.y + t.height == w.y - 4 and t.y >= 0 and
  t.y + t.height <= s.height)')"

# --- the cursor leg the transition change touches: a hover handler that acts on
# leave would fight the cursor. The resize handles now only set their cursor when
# entered, and the no-handler fallthrough is what resets it. Restated: the handle's
# handler is still registered and still reachable, which is what cursor-test.sh then
# drives with a REAL pointer (that is the automated proof, not this line).
check "hover: the resize handles still register a hover handler" "true" \
	"$(eval_kiln "$c
local st = require('kiln.state')
local s = screen.all()[1]
local presses = st.screen_presses[s.name] or {}
return tostring(presses['on_hover:resize_n#' .. c.handle] ~= nil)")"

# The compositor stayed clean throughout: no Lua errors on the bus, no tree-vs-scene
# divergence from the always-on reconciler checks. Every hover, leave, flip, and
# placement write above went through the reconcile this proves survived.
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

noise=$(grep -cE "error in '|tree==scene:" "$log" || true)
check "no bus errors, no tree/scene divergence" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
