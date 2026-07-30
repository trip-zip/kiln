#!/bin/sh
# The form-widget battery: the four leaves a bar is built out of that were not
# leaves yet.
#
#   scripts/widget-test.sh
#
# widgets.progress, widgets.separator, widgets.toggle and widgets.slider are
# compositions in the public API, so what is under test is that each one SOLVES
# rather than computes: a fill is a Clay percent of its track, a knob is an
# alignment, and a slider's value is the pointer read against the box Clay
# solved. Every assertion below reads boxes back and compares them to each
# other, never to a pixel constant, because a constant would pass on a build
# that laid the widget out wrongly and consistently.
#
# The slider also proves the claim it takes: a drag is a mousegrabber, which is
# the same door the interactive move/resize drag uses, so the leg that matters
# is that the claim is held for the drag and released at the button up.
#
# PRESSES ARE RESTATED, NOT DRIVEN (the menu-test.sh discipline). Pointer events
# go through grab.route_pointer, which is what init.lua calls for every queued
# motion and button while a claim holds.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-widget-test.XXXXXX)"
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

cat >"$rc" <<'EOF'
local kiln = require("kiln")
local ui, th = kiln.ui, kiln.theme
local widgets = kiln.widgets

PROG = 0.5
TOG = false
SLIDE = 0.25
SLIDE_LOG = {}

screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()

	ui.bar(s, { edge = "top", h = 40, color = th.bg }, function()
		-- A fixed track width, so the fill's own width is the only thing the
		-- value can be read out of.
		widgets.progress { id = "prog", fill_id = "prog:fill", value = PROG,
			w = 200, h = 8 }
		widgets.separator { id = "sep", vertical = true, length = 20 }
		widgets.toggle { id = "tog", on = TOG,
			press = function() TOG = not TOG; kiln.dirty(s.name) end }
		widgets.slider { id = "slide", value = SLIDE, w = 100, h = 16,
			changed = function(v)
				SLIDE = v
				SLIDE_LOG[#SLIDE_LOG + 1] = v
				kiln.dirty(s.name)
			end }
	end)
end)
EOF

cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

set_lua() {
	eval_kiln "$1
core.dirty()" >/dev/null
	sleep 0.6
}

live() { # lua-id-expr
	eval_kiln "
local s = screen.all()[1]
local id = $1
local b = core.box(id)
if b == nil then return 'absent' end
for _, h in ipairs(core.hits(s.name, b.x + b.width / 2, b.y + b.height / 2)) do
  local want = type(id) == 'table' and id[1] or id
  if h.name == want then return 'live' end
end
return 'absent'"
}

# The fill as a percentage of its track, which is what "the value drives the
# fill" means when Clay is the one solving it.
fill_pct() {
	eval_kiln 'local t = core.box("prog")
local f = core.box("prog:fill")
if t == nil or f == nil then return "no box" end
return math.floor(f.width / t.width * 100 + 0.5)'
}

press() { # lua-id-expr [ev-lua]
	eval_kiln "
local st = require('kiln.state')
local s = screen.all()[1]
local id = $1
local b = core.box(id)
if b == nil then return 'no-box' end
local presses = st.screen_presses[s.name] or {}
for _, h in ipairs(core.hits(s.name, b.x + b.width / 2, b.y + b.height / 2)) do
  local fn = presses['on_press:' .. h.name .. '#' .. h.index]
  if fn ~= nil then
    fn(${2:-})
    core.dirty()
    return h.name
  end
end
return 'no-handler'"
	sleep 0.6
}

# =====================================================================
# 1. widgets.progress. The fill is a percent of the track, so the ratio of the two
# solved boxes IS the value, at any track width.

check "the track is declared" "live" "$(live '"prog"')"
check "a half value fills half the track" "50" "$(fill_pct)"
set_lua 'PROG = 0.25'
check "and a quarter fills a quarter" "25" "$(fill_pct)"
set_lua 'PROG = 0'
check "zero fills nothing" "0" "$(fill_pct)"
set_lua 'PROG = 1'
check "one fills it all" "100" "$(fill_pct)"
# Out of range is clamped rather than solved into an overflow, because a hint
# from a client is not a promise about its range.
set_lua 'PROG = 1.7'
check "over one is clamped, not overflowed" "100" "$(fill_pct)"
set_lua 'PROG = -0.5'
check "and under zero too" "0" "$(fill_pct)"
set_lua 'PROG = 0.5'

# =====================================================================
# 2. widgets.separator. A rule with no other job: it is declared, and it is thin on
# exactly one axis.

check "the separator is declared" "live" "$(live '"sep"')"
check "a vertical rule is thin across and long down" "true" \
	"$(eval_kiln 'local b = core.box("sep")
if b == nil then return "no box" end
return tostring(b.width < b.height)')"

# =====================================================================
# 3. widgets.toggle. Controlled: the caller owns the boolean, the widget owns where
# the knob sits, and Clay is what puts it there.

check "the toggle is declared" "live" "$(live '"tog"')"
knob_left() {
	eval_kiln 'local t = core.box("tog")
local k = core.box("tog:knob")
if t == nil or k == nil then return "no box" end
return tostring(k.x + k.width / 2 < t.x + t.width / 2)'
}
check "off puts the knob in the left half" "true" "$(knob_left)"
check "pressing it runs the caller's press" "tog" "$(press '"tog"')"
check "which flipped the caller's own boolean" "true" \
	"$(eval_kiln 'return tostring(TOG)')"
check "and the knob moved to the right half" "false" "$(knob_left)"

# =====================================================================
# 4. widgets.slider. The value is the pointer read against the solved track, so a
# press lands where it was pressed rather than stepping by a constant.

check "the slider is declared" "live" "$(live '"slide"')"
check "CONTROL: no pointer claim before the press" "false" \
	"$(eval_kiln 'return tostring(require("kiln.grab").route_pointer
  { name = "motion", x = 0, y = 0 })')"

# Press at the track's three-quarter point: the value should BE three quarters,
# which is press-to-jump falling out of reading the box rather than a feature
# written on top of it.
set_lua 'local b = core.box("slide")
local st = require("kiln.state")
local s = screen.all()[1]
local presses = st.screen_presses[s.name] or {}
local x = b.x + b.width * 0.75
local y = b.y + b.height / 2
for _, h in ipairs(core.hits(s.name, x, y)) do
  local fn = presses["on_press:" .. h.name .. "#" .. h.index]
  if fn ~= nil then fn({ x = x, y = y, button = 1, screen = s.name }) break end
end'
check "a press jumps the value to where it landed" "75" \
	"$(eval_kiln 'return math.floor(SLIDE * 100 + 0.5)')"
check "and the drag holds the pointer claim" "true" \
	"$(eval_kiln 'return tostring(require("kiln.grab").route_pointer
  { name = "motion", x = 0, y = 0 })')"

# Motion is the same read at a new x. Driven through route_pointer, which is the
# door init.lua uses for every queued motion while a claim holds.
set_lua 'local b = core.box("slide")
local g = require("kiln.grab")
g.route_pointer { name = "motion", x = b.x + b.width * 0.25,
  y = b.y + b.height / 2, screen = screen.all()[1].name }'
check "a motion moves the value with the pointer" "25" \
	"$(eval_kiln 'return math.floor(SLIDE * 100 + 0.5)')"

# Past either end there is nowhere further to go, and a slider that reported
# 1.4 would hand its caller a value it never offered.
set_lua 'local b = core.box("slide")
local g = require("kiln.grab")
g.route_pointer { name = "motion", x = b.x + b.width * 3,
  y = b.y + b.height / 2, screen = screen.all()[1].name }'
check "dragging past the end clamps at one" "100" \
	"$(eval_kiln 'return math.floor(SLIDE * 100 + 0.5)')"
set_lua 'local b = core.box("slide")
local g = require("kiln.grab")
g.route_pointer { name = "motion", x = b.x - b.width,
  y = b.y + b.height / 2, screen = screen.all()[1].name }'
check "and past the other end at zero" "0" \
	"$(eval_kiln 'return math.floor(SLIDE * 100 + 0.5)')"

# The release ends the drag, through the same door the move/resize drag uses.
set_lua 'require("kiln.grab").route_pointer
  { name = "button", pressed = false, button = 1 }'
check "the button up released the claim" "false" \
	"$(eval_kiln 'return tostring(require("kiln.grab").route_pointer
  { name = "motion", x = 0, y = 0 })')"
check "and a motion after it moves nothing" "0" \
	"$(eval_kiln 'return math.floor(SLIDE * 100 + 0.5)')"

# The fill follows the value, so the widget reflects by re-declaring and has no
# update path of its own.
check "the slider's own fill followed the value down" "true" \
	"$(eval_kiln 'local t = core.box("slide")
local f = core.box("slide:fill")
if t == nil or f == nil then return "no box" end
return tostring(f.width < t.width / 4)')"

# =====================================================================
printf '\n'
if [ "$fail" -eq 0 ]; then
	printf 'PASS\n'
else
	printf 'FAIL\n'
fi
exit "$fail"
