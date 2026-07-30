#!/bin/sh
# The layouts battery: every layout in the built-in set declared over four real
# clients, asserted against the boxes Clay solved.
#
#   scripts/layout-test.sh
#
# Pure headless: a layout is declaration, and switching one is a property write,
# so nothing here needs a real input device and the harness stays on the headless
# backend (no Xvfb, no xdotool). Four foot clients map onto the first tag, the
# layout is switched over IPC, and core.box({"client", handle}) reads back the
# cell each client was solved into.
#
# The expected geometry is computed in the script from the workarea box and the
# tag params, never hardcoded, and never by calling the layout: it is an
# independent restatement of what each layout's declaration means, so a wrong
# declaration cannot agree with it. Clay's percent rule (clay.h: percent is taken
# of the parent minus its padding and child gaps) is restated once, in pct().
#
# Needs: foot.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-layout-test.XXXXXX)"
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

wl_disp=$(sed -n 's/.*Running Wayland compositor on WAYLAND_DISPLAY=//p' "$log" | head -1)
for i in 1 2 3 4; do
	WAYLAND_DISPLAY="$wl_disp" foot >"$work/foot$i.log" 2>&1 &
done
sleep 4

# --- the two halves of every assertion.
#
# boxes: the solved composite cell of each client on the tag, in tag (map) order.
# The composite is what a layout declares (border + titlebar + surface), so this
# is the layout's own output, not the client's surface size.
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

# expect: run a Lua expression with the workarea, the gap, and the box helpers in
# scope, and print the expected line. x0/y0/W/H are the inner area a layout is
# handed: the workarea box inset by the gap the runtime pads it with.
expect() {
	eval_kiln "
local wa = screen.all()[1].workarea
-- Read the gap the runtime is actually padding with rather than restating it:
-- these checks are about the layout math, not about what the theme's default
-- gap happens to be, which has changed.
local g = require('kiln.state').theme.gap
local x0, y0 = wa.x + g, wa.y + g
local W, H = wa.width - 2 * g, wa.height - 2 * g
local function r(v) return math.floor(v + 0.5) end
local function b(x, y, w, h)
  return string.format('%d,%d %dx%d', r(x), r(y), r(w), r(h))
end
-- Clay's percent: of the parent minus its padding and child gaps (clay.h).
local function pct(size, f, gaps) return (size - gaps * g) * f end
-- n grow cells sharing a size, and the offset of the i-th (1-based).
local function cell(size, n) return (size - (n - 1) * g) / n end
local function at(start, size, i) return start + (i - 1) * (size + g) end
$1"
}

set_tag() {
	eval_kiln "local L = require(\"kiln.layout\")
local t = screen.all()[1].selected_tag
$1
core.dirty()" >/dev/null
	sleep 0.6
}

check "four clients mapped and tiled" "4" \
	"$(eval_kiln 'return #screen.all()[1].selected_tag.clients')"

# --- tile: a master column at master_width_factor, the rest stacked beside it.
set_tag 't.layout = L.tile'
exp=$(expect '
local m = pct(W, 0.5, 1)
local s = W - g - m
local c = cell(H, 3)
return table.concat({
  b(x0, y0, m, H),
  b(x0 + m + g, at(y0, c, 1), s, c),
  b(x0 + m + g, at(y0, c, 2), s, c),
  b(x0 + m + g, at(y0, c, 3), s, c),
}, " ; ")')
check "tile: one master column, three stacked" "$exp" "$(boxes)"

# --- master_width_factor: one property write, no re-arrange pass.
set_tag 't.master_width_factor = 0.7'
exp=$(expect '
local m = pct(W, 0.7, 1)
local s = W - g - m
local c = cell(H, 3)
return table.concat({
  b(x0, y0, m, H),
  b(x0 + m + g, at(y0, c, 1), s, c),
  b(x0 + m + g, at(y0, c, 2), s, c),
  b(x0 + m + g, at(y0, c, 3), s, c),
}, " ; ")')
check "tile: master_width_factor widens the master" "$exp" "$(boxes)"

# --- master_count: the second client joins the master column.
set_tag 't.master_width_factor = 0.5 t.master_count = 2'
exp=$(expect '
local m = pct(W, 0.5, 1)
local s = W - g - m
local c = cell(H, 2)
return table.concat({
  b(x0, at(y0, c, 1), m, c),
  b(x0, at(y0, c, 2), m, c),
  b(x0 + m + g, at(y0, c, 1), s, c),
  b(x0 + m + g, at(y0, c, 2), s, c),
}, " ; ")')
check "tile: master_count moves a client into the master" "$exp" "$(boxes)"

# --- column_count: the stack splits into N columns beside the master, the
# clients spread over them with fair's take formula (earlier columns take the
# ceil). Two columns over three stack clients: the first column takes 2, the
# second takes 1.
set_tag 't.master_count = 1 t.column_count = 2'
exp=$(expect '
local m = pct(W, 0.5, 1)
local s = W - g - m
local cw = cell(s, 2)
local ch = cell(H, 2)
local sx = x0 + m + g
return table.concat({
  b(x0, y0, m, H),
  b(at(sx, cw, 1), at(y0, ch, 1), cw, ch),
  b(at(sx, cw, 1), at(y0, ch, 2), cw, ch),
  b(at(sx, cw, 2), y0, cw, H),
}, " ; ")')
check "tile: column_count splits the stack into two columns" "$exp" "$(boxes)"

# --- column_count = 1 is the current single-column stack (regression guard),
# and it resets the param for the cases that follow.
set_tag 't.column_count = 1'
exp=$(expect '
local m = pct(W, 0.5, 1)
local s = W - g - m
local c = cell(H, 3)
return table.concat({
  b(x0, y0, m, H),
  b(x0 + m + g, at(y0, c, 1), s, c),
  b(x0 + m + g, at(y0, c, 2), s, c),
  b(x0 + m + g, at(y0, c, 3), s, c),
}, " ; ")')
check "tile: column_count = 1 restores the single stacked column" "$exp" "$(boxes)"

# --- the flips: the same shape, the master on the other side. tile.left names
# where the STACK goes, so the master lands on the right.
set_tag 't.master_count = 1 t.layout = L.tile.left'
exp=$(expect '
local m = pct(W, 0.5, 1)
local s = W - g - m
local c = cell(H, 3)
return table.concat({
  b(x0 + s + g, y0, m, H),
  b(x0, at(y0, c, 1), s, c),
  b(x0, at(y0, c, 2), s, c),
  b(x0, at(y0, c, 3), s, c),
}, " ; ")')
check "tile.left: master on the right" "$exp" "$(boxes)"

set_tag 't.layout = L.tile.bottom'
exp=$(expect '
local m = pct(H, 0.5, 1)
local s = H - g - m
local c = cell(W, 3)
return table.concat({
  b(x0, y0, W, m),
  b(at(x0, c, 1), y0 + m + g, c, s),
  b(at(x0, c, 2), y0 + m + g, c, s),
  b(at(x0, c, 3), y0 + m + g, c, s),
}, " ; ")')
check "tile.bottom: master on top, stack across the bottom" "$exp" "$(boxes)"

# --- fair: a 2x2 grid of equal cells at four clients.
set_tag 't.layout = L.fair'
exp=$(expect '
local cw, ch = cell(W, 2), cell(H, 2)
return table.concat({
  b(at(x0, cw, 1), at(y0, ch, 1), cw, ch),
  b(at(x0, cw, 1), at(y0, ch, 2), cw, ch),
  b(at(x0, cw, 2), at(y0, ch, 1), cw, ch),
  b(at(x0, cw, 2), at(y0, ch, 2), cw, ch),
}, " ; ")')
check "fair: four clients form a 2x2 grid" "$exp" "$(boxes)"

# --- dwindle: each client halves what is left, the axis alternating.
set_tag 't.layout = L.dwindle'
exp=$(expect '
local w1, h1 = cell(W, 2), H
local h2 = cell(H, 2)
local w3 = cell(w1, 2)
local x2 = x0 + w1 + g
local y2 = y0 + h2 + g
return table.concat({
  b(x0, y0, w1, h1),
  b(x2, y0, w1, h2),
  b(x2, y2, w3, h2),
  b(x2 + w3 + g, y2, w3, h2),
}, " ; ")')
check "dwindle: each client halves the remainder" "$exp" "$(boxes)"

# --- spiral: the same halving, but every other pair of levels leads with the
# remainder instead of the client, which is what winds the cells inward. At four
# clients that shows up as the third split being mirrored against dwindle's.
set_tag 't.layout = L.spiral'
exp=$(expect '
local w1 = cell(W, 2)
local h2 = cell(H, 2)
local w3 = cell(w1, 2)
local x2 = x0 + w1 + g
local y2 = y0 + h2 + g
return table.concat({
  b(x0, y0, w1, H),
  b(x2, y0, w1, h2),
  b(x2 + w3 + g, y2, w3, h2),
  b(x2, y2, w3, h2),
}, " ; ")')
check "spiral: the third split winds inward, mirroring dwindle" "$exp" "$(boxes)"

# --- corner: the master fills the corner, the rest alternate between a stack
# down the far side (clients 2 and 4) and one across the foot (client 3).
set_tag 't.layout = L.corner.nw'
exp=$(expect '
local band = pct(H, 0.5, 1)
local foot = H - g - band
local m = pct(W, 0.5, 1)
local side = W - g - m
local sc = cell(band, 2)
return table.concat({
  b(x0, y0, m, band),
  b(x0 + m + g, at(y0, sc, 1), side, sc),
  b(x0, y0 + band + g, W, foot),
  b(x0 + m + g, at(y0, sc, 2), side, sc),
}, " ; ")')
check "corner.nw: master in the corner, a stack down each far edge" "$exp" \
	"$(boxes)"

# --- magnifier: the focused client is a centered float at the master factor.
set_tag 't.layout = L.magnifier t.clients[1]:focus()'
exp=$(expect '
local w, h = math.floor(W * 0.5), math.floor(H * 0.5)
return b(wa.x + (wa.width - w) / 2, wa.y + (wa.height - h) / 2, w, h)')
check "magnifier: the focused client is a centered float" "$exp" \
	"$(eval_kiln '
local b = core.box({ "client", client.focus.handle })
return b == nil and "-" or
  string.format("%d,%d %dx%d", b.x, b.y, b.width, b.height)')"

# --- carousel: a clip row of fixed-width columns on one strip, scrolled by
# childOffset so the focused column is centered. Focus is the offset's only
# input, so focusing along the strip IS the scroll, and the solved boxes are
# where it lands. The first column at rest sits at the strip origin (the offset
# clamps at 0); focusing the last client pulls the strip left, which is the
# childOffset moving, read back through the solve.
set_tag 't.layout = L.carousel t.clients[1]:focus()'
first=$(boxes)
exp=$(expect '
local col = math.floor(W * 0.5)
local c = cell(H, 1)
-- offset clamped to 0: the focused column is already the leftmost.
return table.concat({
  b(x0, y0, col, H),
  b(x0 + col + g, y0, col, H),
  b(x0 + 2 * (col + g), y0, col, H),
  b(x0 + 3 * (col + g), y0, col, H),
}, " ; ")')
check "carousel: at rest the strip starts at the viewport" "$exp" "$first"

set_tag 't.clients[4]:focus()'
last=$(boxes)
exp=$(expect '
local col = math.floor(W * 0.5)
local strip = 4 * col + 3 * g
-- centering the last column overruns the strip end, so the clamp pins it there.
local off = math.min(0, W - strip)
return table.concat({
  b(x0 + off, y0, col, H),
  b(x0 + off + col + g, y0, col, H),
  b(x0 + off + 2 * (col + g), y0, col, H),
  b(x0 + off + 3 * (col + g), y0, col, H),
}, " ; ")')
check "carousel: focusing the last client scrolls the strip" "$exp" "$last"
if [ "$first" = "$last" ]; then
	printf 'FAIL carousel: childOffset never moved\n'
	fail=1
else
	printf 'ok   carousel: childOffset moved the whole strip\n'
fi

# --- max and floating still hold, and the gap is a tag param.
set_tag 't.layout = L.max t.clients[1]:focus()'
exp=$(expect 'return b(x0, y0, W, H)')
check "max: the focused client fills the workarea" "$exp" \
	"$(eval_kiln '
local b = core.box({ "client", client.focus.handle })
return b == nil and "-" or
  string.format("%d,%d %dx%d", b.x, b.y, b.width, b.height)')"

# --- degradation: a layout whose stack is empty grows the master into it. An
# empty run must declare NOTHING, because an empty grow container is not empty to
# Clay, it is a sibling that takes its share. First with every client in the
# master, then with a corner down to one client, which is the shape that would
# hand half its band to a hole.
set_tag 't.layout = L.tile t.master_count = 4'
exp=$(expect 'local c = cell(H, 4)
return table.concat({
  b(x0, at(y0, c, 1), W, c),
  b(x0, at(y0, c, 2), W, c),
  b(x0, at(y0, c, 3), W, c),
  b(x0, at(y0, c, 4), W, c),
}, " ; ")')
check "tile: an empty stack grows the master to the whole area" "$exp" "$(boxes)"

set_tag 't.layout = L.corner.nw t.master_count = 1
for i = #t.clients, 2, -1 do t.clients[i]:kill() end'
sleep 2
eval_kiln 'core.dirty()' >/dev/null
sleep 0.6
exp=$(expect 'return b(x0, y0, W, H)')
check "corner: one client, no stacks, fills the area" "$exp" "$(boxes)"

set_tag 't.layout = L.tile t.gap = 20'
check "gap: a tag param, applied to the workarea inset and the cells" \
	"$(eval_kiln '
local wa = screen.all()[1].workarea
return string.format("%d,%d", wa.x + 20, wa.y + 20)')" \
	"$(eval_kiln '
local b = core.box({ "client", screen.all()[1].selected_tag.clients[1].handle })
return b == nil and "-" or string.format("%d,%d", b.x, b.y)')"

# The compositor stayed clean throughout: no Lua errors on the bus, no
# tree-vs-scene divergence from the always-on reconciler checks. The verifier
# runs every frame, so this also proves the reconcile survived every tree above,
# the clipped carousel strip included.
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

noise=$(grep -cE "error in '|tree==scene:" "$log" || true)
check "no bus errors, no tree/scene divergence" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
