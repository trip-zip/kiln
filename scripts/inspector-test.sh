#!/bin/sh
# The Clay debug inspector battery: the inspector panel narrows, selects, scrolls
# and closes, and the scene stays in agreement with Clay while it is up.
#
#   scripts/inspector-test.sh
#
# Two legs. Leg 1 is headless and mandatory: the inspector is a Clay flag and a
# solve-path pointer feed, so everything about the NARROWING (root, workarea,
# tiled clients), the panel's presence in the live tree, the warnings pane and
# the scroll accumulator is assertable with no input device at all.
#
# Leg 2 needs a real pointer, so it takes pointer-test.sh's harness (kiln on the
# wlroots x11 backend inside a private Xvfb, xdotool driving the nest) and skips
# if the deps are missing. It is where the interactive half lives: selecting a
# row, the consumption invariant, the wheel, the panel's own close button, and
# the KILN_AGREE sweep that proves the scene and Clay still agree over the panel.
#
# Absence is always asserted through core.hits, never core.box: an element's box
# is sticky: core.c keeps the last box an id ever solved to, so a disappeared id
# keeps answering with its final box. hits only names what the live tree put
# under the point.
#
# Needs: foot (leg 1); Xvfb, xdotool (leg 2, skipped without them).
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-inspector-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
sock2="$work/kiln2.sock"
log2="$work/kiln2.log"

# Pin the config, the way prompt-test.sh does. Resolution order puts
# $XDG_CONFIG_HOME/kiln/rc.lua ahead of the repo copy, so an unpinned boot runs
# whatever config the user has installed rather than the one this battery
# asserts against, and the run silently stops testing what it says it tests.
rc="$repo/kilnrc.lua"
cfg="$work/config"
mkdir -p "$cfg"
disp=":96"
kiln_pid=""
kiln2_pid=""
xvfb_pid=""

cleanup() {
	[ -n "$kiln_pid" ] && kill "$kiln_pid" 2>/dev/null || true
	[ -n "$kiln2_pid" ] && kill "$kiln2_pid" 2>/dev/null || true
	[ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

fail=0
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   %s\n     (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s\n     expected %s\n     got      %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

# --- leg 1: headless -------------------------------------------------------

echo "--- leg 1: headless"
eval_kiln() { KILN_SOCK="$sock" "$repo/scripts/kiln-eval" "$1"; }

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
	KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

wl_disp=$(sed -n 's/.*Running Wayland compositor on WAYLAND_DISPLAY=//p' "$log" | head -1)
for i in 1 2; do
	WAYLAND_DISPLAY="$wl_disp" foot >"$work/foot$i.log" 2>&1 &
done
sleep 4

geom=$(eval_kiln 'local o = core.output.list()[1]
return string.format("%s %d %d", o.name, o.width, o.height)')
name=$(printf '%s' "$geom" | cut -d" " -f1)
W=$(printf '%s' "$geom" | cut -d" " -f2)
H=$(printf '%s' "$geom" | cut -d" " -f3)
printf 'screen %s %sx%s\n' "$name" "$W" "$H"

check "two clients mapped and tiled" "2" \
	"$(eval_kiln 'return #screen.all()[1].selected_tag.clients')"

# The panel is 400 wide (Clay__debugViewWidth, clay.h) and Clay_BeginLayout
# subtracts exactly that from the root before the frame handler declares
# anything. Everything downstream of the root is expected to follow.
PW=400

# Two dirties, not one: the workarea readback lags a solve by construction. A
# layout reads s.workarea, which is core.box of the PREVIOUS solve's grow node,
# so solve N narrows the workarea and solve N+1 is the first to place clients
# inside it. That one-solve lag is expected, not a defect, and separate
# evals are required because N mutations in one eval coalesce to one solve.
dirty2() {
	eval_kiln "core.dirty('$name')" >/dev/null
	sleep 0.5
	eval_kiln "core.dirty('$name')" >/dev/null
	sleep 0.5
}

root_width() {
	eval_kiln "local b = core.box('Clay__RootContainer')
return b == nil and -1 or b.width"
}
wa_width() { eval_kiln 'return screen.all()[1].workarea.width'; }

# The solved composite cell of each client on the tag, in tag (map) order: the
# layout-test.sh reader, unchanged.
boxes() {
	eval_kiln '
local o = {}
for _, c in ipairs(screen.all()[1].selected_tag.clients) do
  local b = core.box({ "client", c.handle })
  o[#o+1] = b == nil and "-" or
    string.format("%d,%d %dx%d", b.x, b.y, b.width, b.height)
end
return table.concat(o, " ; ")'
}

# tile with two clients, restated independently from the LIVE workarea: a master
# column at master_width_factor and one stacked cell beside it. Reading the
# workarea back rather than hardcoding it is the point: the same expression is
# correct before and after the narrowing, so agreement proves the clients were
# re-derived from whatever workarea the panel left them.
expect_tile2() {
	eval_kiln '
local wa = screen.all()[1].workarea
local g = require("kiln.state").theme.gap
local x0, y0 = wa.x + g, wa.y + g
local W, H = wa.width - 2 * g, wa.height - 2 * g
local function r(v) return math.floor(v + 0.5) end
local function b(x, y, w, h)
  return string.format("%d,%d %dx%d", r(x), r(y), r(w), r(h))
end
-- Clay percent: of the parent minus its padding and child gaps (clay.h).
local m = (W - g) * 0.5
local s = W - g - m
return table.concat({ b(x0, y0, m, H), b(x0 + m + g, y0, s, H) }, " ; ")'
}

# hits at a layout point, as one space-joined line of element names. Anonymous
# Clay elements carry an empty name and land as empty fields, which is what the
# newline split below wants anyway.
hits() { # x y
	eval_kiln "local o = {}
for _, h in ipairs(core.hits('$name', $1, $2)) do o[#o+1] = h.name end
return table.concat(o, ' ')"
}
has_exact() { printf '%s' "$1" | tr ' ' '\n' | grep -qx -- "$2" && echo yes || echo no; }
has_prefix() { printf '%s' "$1" | tr ' ' '\n' | grep -q -- "^$2" && echo yes || echo no; }

# --- off: the baseline every later assertion is measured against.
check "inspector reports off at boot" "false" "$(eval_kiln "return core.inspector('$name')")"
w_off=$(root_width)
wa_off=$(wa_width)
check "root fills the output while off" "$W" "$w_off"
check "tile is solved into the full workarea while off" "$(expect_tile2)" "$(boxes)"

# --- on: the narrowing, all the way down.
check "enabling reports on" "true" "$(eval_kiln "return core.inspector('$name', true)")"
dirty2
check "root gives up the panel width" "$((W - PW))" "$(root_width)"
check "workarea gives up the panel width" "$((wa_off - PW))" "$(wa_width)"
check "clients re-derive from the narrowed workarea" "$(expect_tile2)" "$(boxes)"

# --- the panel is in the live tree, and only over its own band.
panel=$(hits "$((W - 200))" 10)
check "the panel is under a point in its band" "yes" "$(has_exact "$panel" 'Clay__DebugView')"
user=$(hits 100 "$((H / 2))")
check "the panel is not under a user-area point" "no" "$(has_exact "$user" 'Clay__DebugView')"

# Nothing selected yet, so the bottom 300px pane is the warnings pane.
bottom=$(hits "$((W - 200))" "$((H - 150))")
check "the bottom pane is the warnings pane" "yes" \
	"$(has_prefix "$bottom" 'Clay__DebugViewWarnings')"

# --- the style surface. The colors are Clay globals with no readback, so the
# assertable one is the width: it is the number Clay_BeginLayout subtracts, so a
# restyle that took shows up as a differently narrowed root. The table form also
# carries `enabled`, which is asserted here by NOT passing it: a style-only call
# must leave the toggle where it was.
eval_kiln "core.inspector('$name', { width = 300,
  color1 = { r = 20, g = 20, b = 30 },
  highlight = { r = 0, g = 200, b = 255, a = 90 } })" >/dev/null
dirty2
check "a style call re-widths the panel and leaves it up" "$((W - 300))" \
	"$(root_width)"
check "a style-only call does not toggle" "true" \
	"$(eval_kiln "return core.inspector('$name')")"
eval_kiln "core.inspector('$name', { width = 400 })" >/dev/null
dirty2
check "the width goes back" "$((W - PW))" "$(root_width)"

# --- the wheel. Clay applies a wheel delta to the scroll container under the
# POINTER (Clay_UpdateScrollContainers reads pointerOverIds), and the headless
# backend has no input device to give C a seat position, so the solve-path feed
# stands down and the last core.hits query is what leaves Clay's pointer over
# the tree pane. Seat and scroll in ONE eval: two would be two solves, and the
# accumulator is applied by the first.
eval_kiln "core.hits('$name', $((W - 200)), 100)
core.inspector_scroll('$name', 0, -3)" >/dev/null
sleep 0.5
off=$(eval_kiln "return core.inspector_scroll('$name')")
case "$off" in
	-*) printf 'ok   the wheel scrolls the tree pane\n     (%s)\n' "$off" ;;
	*) printf 'FAIL the wheel scrolls the tree pane\n     expected a negative offset\n     got      %s\n' "$off"; fail=1 ;;
esac

# --- off again: the narrowing is given back and the panel leaves the tree.
check "disabling reports off" "false" "$(eval_kiln "return core.inspector('$name', false)")"
dirty2
check "root takes the panel width back" "$W" "$(root_width)"
check "workarea takes the panel width back" "$wa_off" "$(wa_width)"
check "clients re-derive from the restored workarea" "$(expect_tile2)" "$(boxes)"
gone=$(hits "$((W - 200))" 10)
check "the panel is gone from the live tree" "no" "$(has_exact "$gone" 'Clay__DebugView')"

# The compositor stayed clean throughout: no Lua errors on the bus, no
# tree-vs-scene divergence from the always-on reconciler checks, no Clay error
# (the handler aborts, so a surviving process is most of this already).
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

noise=$(grep -cE "error in '|tree==scene:|clay error" "$log" || true)
check "no bus errors, no tree/scene divergence, no clay error" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
sleep 1
kiln_pid=""

# --- leg 2: a real pointer -------------------------------------------------

echo "--- leg 2: Xvfb + xdotool"
for bin in Xvfb xdotool; do
	command -v "$bin" > /dev/null 2>&1 || {
		echo "SKIP leg 2: $bin not installed"
		[ "$fail" = 0 ] && { echo "PASS (leg 1 only)"; exit 0; }
		echo "FAIL"; exit 1; }
done

eval2() { KILN_SOCK="$sock2" "$repo/scripts/kiln-eval" "$1"; }

Xvfb "$disp" -screen 0 1280x800x24 >"$work/xvfb.log" 2>&1 &
xvfb_pid=$!
sleep 2

# KILN_AGREE on for the whole leg: every motion samples the topmost-plus-clip
# agreement invariant and aborts on divergence, so the sweep at the end is an
# assertion about the panel and the highlight overlay, not a formality.
cd "$repo"
WLR_BACKENDS=x11 DISPLAY="$disp" KILN_SOCK="$sock2" KILN_AGREE=1 \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
	./build/kiln > "$log2" 2>&1 &
kiln2_pid=$!
sleep 3

nest=$(DISPLAY="$disp" xdotool search "" 2>/dev/null | tail -1)
DISPLAY="$disp" xdotool windowfocus "$nest"

geom2=$(eval2 'local o = core.output.list()[1]
return string.format("%s %d %d", o.name, o.width, o.height)')
name2=$(printf '%s' "$geom2" | cut -d" " -f1)
W2=$(printf '%s' "$geom2" | cut -d" " -f2)
H2=$(printf '%s' "$geom2" | cut -d" " -f3)
printf 'nest screen %s %sx%s\n' "$name2" "$W2" "$H2"

# Every name found anywhere along one scanline of the panel. Scanned rather than
# probed at a single x because the panel's rows and its config lines are all
# FIT-width (clay.h Clay__DebugView_ScrollViewItemLayoutConfig sets a height and
# no width), so an element's horizontal extent is its text, indented by its depth
# in the tree: a fixed x samples a different thing on every row.
scan_row() { # y
	eval2 "local seen, o = {}, {}
for x = $((W2 - 388)), $((W2 - 8)), 8 do
  for _, h in ipairs(core.hits('$name2', x, $1)) do
    if h.name ~= '' and not seen[h.name] then
      seen[h.name] = true
      o[#o+1] = h.name
    end
  end
end
return table.concat(o, ' ')"
}
# The row under a point, by the id Clay gives each tree row
# (CLAY_IDI("Clay__DebugView_ElementOuter", <element id>)): the index IS the
# element the row stands for, so it is a stable identity for "which row is here".
row_at() { # y
	eval2 "for x = $((W2 - 388)), $((W2 - 8)), 8 do
  for _, h in ipairs(core.hits('$name2', x, $1)) do
    if h.name == 'Clay__DebugView_ElementOuter' then return h.index end
  end
end
return 'none'"
}
move() { DISPLAY="$disp" xdotool mousemove --window "$nest" "$1" "$2"; }
wheel_down() { # count
	i=0
	while [ "$i" -lt "$1" ]; do
		DISPLAY="$disp" xdotool click 5
		i=$((i + 1))
	done
}

eval2 "core.inspector('$name2', true)" >/dev/null
sleep 0.5
eval2 "core.dirty('$name2')" >/dev/null
sleep 0.5
check "the panel is up on the nest" "$((W2 - 400))" \
	"$(eval2 "local b = core.box('Clay__RootContainer') return b == nil and -1 or b.width")"

# --- selecting a row swaps the warnings pane for the detail pane, which is the
# whole point of the click reaching Clay's own solver. The detail pane's own
# container is anonymous in clay.h, so the claim is made twice: the warnings ids
# leave the pane band, and a Clay__DebugViewElementInfo id appears in it.
#
# The second half needs the pane scrolled first, and that is a fact about the
# panel rather than a workaround: the config lines it lists overflow its fixed
# 300px, and the ids clay.h names sit below the fold. Which is why the contract
# asks for BOTH panes to scroll, and why scrolling this one is asserted here.
move "$((W2 - 200))" 90
sleep 0.5
DISPLAY="$disp" xdotool click 1
sleep 1
pane_names() { # -> every name anywhere in the bottom pane
	y=$((H2 - 290))
	while [ "$y" -lt "$((H2 - 20))" ]; do
		scan_row "$y"
		printf ' '
		y=$((y + 10))
	done
}
bottom=$(pane_names)
warn_gone=$(printf '%s' "$bottom" | tr ' ' '\n' | grep -q '^Clay__DebugViewWarnings' && echo no || echo yes)
check "clicking a row retires the warnings pane" "yes" "$warn_gone"

move "$((W2 - 200))" "$((H2 - 70))"
sleep 0.4
wheel_down 5
sleep 1
bottom=$(pane_names)
info_seen=$(printf '%s' "$bottom" | tr ' ' '\n' | grep -q '^Clay__DebugViewElementInfo' && echo yes || echo no)
check "clicking a row raises the element detail pane, which scrolls" "yes" \
	"$info_seen"

# --- consumption. A press over the panel must never reach a root binding, and
# a press on the empty workarea must still reach it: that pair is the whole
# invariant, and only the pair proves the predicate is neither too narrow nor
# too broad. kiln is a local in rc.lua, so an IPC eval requires it by hand.
eval2 'local kiln = require("kiln")
ROOTCLICKS = 0
kiln.button { mods = {}, button = 1, on = "root",
  press = function() ROOTCLICKS = ROOTCLICKS + 1 end }
return "armed"' >/dev/null
move "$((W2 - 200))" 200
sleep 0.3
DISPLAY="$disp" xdotool click 1
sleep 0.7
check "a click inside the panel reaches no root binding" "0" "$(eval2 'return ROOTCLICKS')"
move 200 "$((H2 / 2))"
sleep 0.3
DISPLAY="$disp" xdotool click 1
sleep 0.7
check "a click on the empty workarea still reaches the root binding" "1" \
	"$(eval2 'return ROOTCLICKS')"

# --- the wheel over the tree pane, end to end this time: C never sees the axis,
# Lua routes it because the hits under the cursor name the panel exactly.
#
# The y is FOUND, not hardcoded: the leg above leaves the element detail pane
# open, and the detail pane's height is a function of the selected element, so
# the tree/detail boundary sits at a different y for every config. Scan down the
# panel for a y that actually carries a row, then hold THAT y fixed across the
# wheel, which is what this leg is about.
row_y=""
y=100
while [ "$y" -lt 500 ]; do
	if [ "$(row_at "$y")" != "none" ]; then
		row_y="$y"
		break
	fi
	y=$((y + 10))
done
if [ -z "$row_y" ]; then
	printf 'FAIL no tree row found anywhere in the panel to wheel under\n'
	fail=1
	row_y=300
fi
move "$((W2 - 200))" "$row_y"
sleep 0.5
before=$(row_at "$row_y")
wheel_down 3
sleep 1
after=$(row_at "$row_y")
if [ "$before" != "none" ] && [ "$after" != "none" ] && [ "$before" != "$after" ]; then
	printf 'ok   the wheel moves the tree under a fixed point\n     (%s -> %s)\n' \
		"$before" "$after"
else
	printf 'FAIL the wheel moves the tree under a fixed point\n     expected two different rows\n     got      %s -> %s\n' "$before" "$after"
	fail=1
fi

# --- the sweep. Every motion here runs the KILN_AGREE sample, which aborts the
# process on a scene-vs-Clay divergence, so surviving it IS the assertion: the
# panel, the hovered-row highlight overlay in the user area, and the boundary
# between them all backmap to ids Clay agrees are under the point.
#
# The whole panel height is swept, not one comfortable scanline. The band below
# the tree pane's clip is where a real divergence lived (the element list is a
# float clipped to the pane it sits in, and kiln was rendering that clip as a
# no-op, so rows drew over the pane below while Clay said they were not there).
# A sweep that only crosses the tree pane cannot see it.
y=40
while [ "$y" -lt "$H2" ]; do
	x=40
	while [ "$x" -lt "$W2" ]; do
		move "$x" "$y"
		x=$((x + 80))
	done
	y=$((y + 40))
done
move "$((W2 - 200))" 120
sleep 0.5
if kill -0 "$kiln2_pid" 2>/dev/null; then
	printf 'ok   KILN_AGREE holds over the whole panel and the user area\n     (swept the full %sx%s at 80x40)\n' "$W2" "$H2"
else
	printf 'FAIL the agreement invariant fired during the sweep\n'
	fail=1
fi

# --- the close button, last: the panel closes itself from inside Clay's own
# solver (clay.h HandleDebugViewCloseButtonInteraction and the id scan at the
# top of Clay__RenderDebugView), so C learns about it only by re-reading the
# flag after EndLayout. The restored root width is that resync, observed.
move "$((W2 - 16))" 15
sleep 0.5
DISPLAY="$disp" xdotool click 1
sleep 1.5
check "the panel's own close button closes it" "false" "$(eval2 "return core.inspector('$name2')")"
check "the root reflows back to full width after a self-close" "$W2" \
	"$(eval2 "local b = core.box('Clay__RootContainer') return b == nil and -1 or b.width")"

# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's
# pcall, so this leg MUST go red under it, or the grep is watching nothing.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval2 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

noise2=$(grep -cE "error in '|tree==scene:|clay error|agreement:" "$log2" || true)
check "the nest stayed clean too" "0" "$noise2"

eval2 'core.quit()' >/dev/null 2>&1 || true
sleep 1
kiln2_pid=""

if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
