#!/bin/sh
# The chrome battery: ui.menu, widgets.tasklist, widgets.layoutbox, all three declared
# from a bar in a real rc and asserted against what Clay solved.
#
#   scripts/menu-test.sh
#
# Pure headless: a menu is declaration, a press is a lookup in the press table
# the declare just built, and a tasklist is a function of the client list. None
# of that needs an input device, so the harness stays on the headless backend
# (no Xvfb, no xdotool).
#
# A press is dispatched the way init.lua's on_button dispatches one, restated
# here rather than called: take the element's solved box, hit its center with
# core.hits, and invoke the handler registered under the innermost id. That is
# an independent restatement of the dispatch path (the discipline layout-test.sh
# uses for geometry), so a widget that declares the wrong id, or registers a
# handler under an id nothing hits, fails here instead of passing.
#
# The pointer-HOVER legs (submenu opens on hover, no click) are not automated:
# a hover needs a real pointer device, so they stay a TTY manual leg. Everything
# below is the press path, which is what a headless run can honestly prove.
#
# Keyboard navigation is here for the same reason it is verbs: menu.nav
# IS the mechanism and the key map is a thin layer over it, so a chain walks
# with no input device anywhere. Two things stay outside this file. Real key
# delivery through C's queue is prompt-test.sh's leg (it boots kiln on the X11
# backend inside Xvfb, which gives it a seat). And which PIXEL is lit is TTY
# manual, because Clay answers boxes, not colors: the position claims below read
# the one field the declare lights from (menu.lua's lv.hover), and every other
# claim is a consequence a headless run can see, what enter ran and what stayed
# declared.
#
# Needs: foot.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-menu-test.XXXXXX)"
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

# The rc under test: a bar carrying the three widgets, two tags, and a menu with
# one submenu. Written against the public API only, the same constraint any real
# config lives under.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
local ui = kiln.ui
local widgets = kiln.widgets
local th = kiln.theme

-- What a pressed item did, read back over IPC. The only test scaffolding here.
FIRED = "none"
MENU = {
	{ "term", function() FIRED = "term" end },
	{ "apps", {
		{ "editor", function() FIRED = "editor" end },
		{ "browser", function() FIRED = "browser" end },
	} },
	{ "quit", function() FIRED = "quit" end },
}
-- nil means widgets.tasklist's own default (currenttags).
FILTER = nil

screen.on("added", function(s)
	for _, name in ipairs({ "one", "two" }) do
		tag.new { name = name, screen = s, layout = kiln.layout.tile }
	end
	s.tags[1]:view()
	ui.bar(s, { edge = "top", h = 28, color = th.bg }, function()
		widgets.taglist(s)
		widgets.layoutbox(s)
		widgets.tasklist(s, { filter = FILTER })
		ui.spacer()
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

wl_disp=$(sed -n 's/.*Running Wayland compositor on WAYLAND_DISPLAY=//p' "$log" | head -1)
# Client 1 gets a title far longer than a row is allowed to be, which is what the
# row-width leg below reads. It runs sleep rather than a shell, because a shell
# sets its own title over the escape sequence and the flag would not stick. The
# other two keep foot's default.
long_title="Handgloves and quartz and rather more besides than ever fits a row"
for i in 1 2 3; do
	if [ "$i" = 1 ]; then
		WAYLAND_DISPLAY="$wl_disp" foot -T "$long_title" sleep 300 \
			>"$work/foot$i.log" 2>&1 &
	else
		WAYLAND_DISPLAY="$wl_disp" foot >"$work/foot$i.log" 2>&1 &
	fi
done
sleep 4

# --- the readbacks.
#
# box: an element's solved box. NOT an existence test: Clay's element hashmap is
# persistent and its lookup never checks generation, so Clay_GetElementData --
# and therefore core.box -- keeps answering with the LAST box an id ever had,
# long after it stops being declared. core.box's own doc claims the opposite;
# believe the behavior. So box() is only ever used below for geometry that is
# known to be live.
box() {
	eval_kiln "
local b = core.box(\"$1\")
return b == nil and '-' or
  string.format('%d,%d %dx%d', b.x, b.y, b.width, b.height)"
}

# live: is this id declared RIGHT NOW? core.hits is the honest existence test:
# it names what the last solve actually put under a point, so an element that
# stopped being declared stops being named, stale box or not. Probing the id's
# own box center and asking whether the id comes back is therefore "is it still
# there", and it is a stronger claim than a box: it says the thing is hittable
# where it says it is, which is what a menu row has to be to be a menu row.
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

# press: the dispatch path, restated. init.lua's on_button walks the hits
# innermost-first and fires the FIRST one carrying a handler (no bubbling); it
# has to, because the innermost hit is usually an unnamed leaf (a text run, a
# spacer) that carries nothing. This is that walk, against the same press table
# the declare just built. Returns the id whose handler actually ran, so a widget
# that registers a handler under an id nothing hits fails here.
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

# tasks: the ids ui.each keyed the rows by, in tag order, counting only the rows
# actually declared this frame (live, per above).
tasks() {
	eval_kiln '
local s = screen.all()[1]
local o = {}
for _, t in ipairs(s.tags) do
  for _, c in ipairs(t.clients) do
    local id = "task:" .. c.handle
    local b = core.box(id)
    if b ~= nil then
      for _, h in ipairs(core.hits(s.name, b.x + b.width / 2,
          b.y + b.height / 2)) do
        if h.name == id then o[#o+1] = id break end
      end
    end
  end
end
return table.concat(o, " ")'
}

set_lua() {
	eval_kiln "$1
core.dirty()" >/dev/null
	sleep 0.6
}

# nav: one keyboard verb, through the public mechanism. Returns whether the verb
# was handled.
nav() {
	eval_kiln "return tostring(require('kiln').menu.nav('$1'))"
	sleep 0.6
}

# sel: the path of the row the DEEPEST open level has selected, which is the row
# a verb would act on. The highlight itself is a fill color and Clay answers no
# colors, so this reads the field the declare lights from; the drawn pixel is the
# TTY manual leg named in the header.
sel() {
	eval_kiln 'local m = require("kiln").menu.open
if m == nil then return "closed" end
local lv = m.levels[#m.levels]
return lv.hover or "none"'
}

# key: the key dispatch, restated the way press() restates the button dispatch.
# init.lua hands EVERY queued key to grabber.route_key before any binding runs
# (a grab outranks every binding), and route_key returns whether a claim took it.
# So one leg here proves three things at once: that a menu holds the keyboard,
# that the key map resolved the keysym, and that the verb ran.
key() {
	eval_kiln "return tostring(require('kiln.grab').route_key {
  pressed = true, key = '$1', mods = {} })"
	sleep 0.6
}

check "three clients mapped" "3" \
	"$(eval_kiln 'return #screen.all()[1].selected_tag.clients')"

# --- the menu: closed is not declared. Not hidden, not zero-sized: absent.
check "menu: nothing declared while closed" "absent" "$(live menu:box)"

set_lua 'require("kiln").ui.menu {
  items = MENU, screen = screen.all()[1], x = 100, y = 100 }'
check "menu: opens at its point" "live" "$(live menu:box)"
# Restated from the theme, not hardcoded: the column is the theme width, and a
# fit height of one row per item plus the padding it is declared with.
check "menu: is the theme width, one row per item tall" \
	"$(eval_kiln 'local th = require("kiln").theme
return string.format("100,100 %dx%d", th.menu_width,
  #MENU * th.menu_height + 2 * 4)')" \
	"$(box menu:box)"
check "menu: the scrim covers the screen" \
	"$(eval_kiln 'local s = screen.all()[1]
return string.format("0,0 %dx%d", s.width, s.height)')" \
	"$(box menu:scrim)"

# --- nesting: pressing a submenu row declares the submenu, attached by Clay to
# the row. The expectation is restated from the two boxes, never hardcoded: the
# submenu's LEFT edge sits on the row's RIGHT edge, and its top on the row's top
# (the two attach points differing is the whole of submenu placement).
check "menu: pressing a submenu row dispatches to that row" "menu:/2" \
	"$(press menu:/2)"
check "menu: the submenu is declared" "live" "$(live menu:box/2)"
check "menu: the submenu opens beside its row, not over it" "true" \
	"$(eval_kiln '
local row = core.box("menu:/2")
local sub = core.box("menu:box/2")
if row == nil or sub == nil then return "no-box" end
return tostring(sub.x == row.x + row.width and sub.y == row.y)')"
check "menu: the root stays open under it" "live" "$(live menu:box)"

# --- dispatch: a leaf runs its action and closes the whole chain, submenu and
# all. FIRED is written by the item itself, in the rc, through the public API.
check "menu: pressing a submenu leaf dispatches to it" "menu:/2/1" \
	"$(press menu:/2/1)"
check "menu: the leaf's action ran" "editor" "$(eval_kiln 'return FIRED')"
check "menu: dispatching closed the chain" "absent absent" \
	"$(live menu:box) $(live menu:box/2)"

# --- dismissal: a press that lands outside every row hits the scrim and closes
# the menu, running no action. This is what stops a click on a client from
# leaving the menu up (dispatch is innermost-first with no bubbling, so the
# scrim only ever sees the presses no row took).
set_lua 'FIRED = "none"
require("kiln").ui.menu {
  items = MENU, screen = screen.all()[1], x = 100, y = 100 }'
check "menu: reopened" "live" "$(live menu:box)"
check "menu: a press outside the rows dispatches to the scrim" "menu:scrim" \
	"$(press menu:scrim)"
check "menu: the scrim closed it, and ran nothing" "absent none" \
	"$(live menu:box) $(eval_kiln 'return FIRED')"

# --- keyboard navigation. Every leg leaves the chain CLOSED behind it:
# an open menu leaves its capturing scrim up, and the next section's presses
# would all land on the scrim.
check "nav: a verb with no menu open is not handled" "false" "$(nav down)"

set_lua 'FIRED = "none"
require("kiln").ui.menu {
  items = MENU, screen = screen.all()[1], x = 100, y = 100 }'
check "nav: a fresh chain has nothing selected" "none" "$(sel)"
check "nav: down is handled" "true" "$(nav down)"
check "nav: and it selects the first row" "/1" "$(sel)"
nav down >/dev/null
check "nav: down again walks to the next row" "/2" "$(sel)"
# Walking is not descending: row 2 is the submenu row, and moving onto it must
# not open it, or the chain would deepen under the next verb.
check "nav: walking onto a submenu row does not open it" "absent" \
	"$(live menu:box/2)"

check "nav: enter descends into the submenu" "true" "$(nav enter)"
check "nav: the submenu is declared, the root stays open" "live live" \
	"$(live menu:box/2) $(live menu:box)"
check "nav: a keyboard descent selects the submenu's first row" "/2/1" "$(sel)"

# back closes exactly one level, and leaves the selection on the row that led
# there (the row is lit either way while its submenu is up, menu.lua's sub test).
check "nav: back closes one level" "true" "$(nav back)"
check "nav: the submenu is gone, the root is not" "absent live" \
	"$(live menu:box/2) $(live menu:box)"
check "nav: and the selection is back on the row that opened it" "/2" "$(sel)"

# At the root there is no level below, so back closes the chain. That is the
# whole of "esc at the root closes the chain": Escape maps to back.
nav back >/dev/null
check "nav: back at the root closes the chain" "absent closed" \
	"$(live menu:box) $(sel)"

# Wrap, both directions, from the same rule: up from nothing is the last row.
set_lua 'require("kiln").ui.menu {
  items = MENU, screen = screen.all()[1], x = 100, y = 100 }'
nav up >/dev/null
check "nav: up from nothing selects the last row" "/3" "$(sel)"
nav down >/dev/null
check "nav: down from the last row wraps to the first" "/1" "$(sel)"

# enter on a leaf is the press path, reached by keyboard: it runs the action and
# closes the whole chain.
check "nav: enter on a leaf is handled" "true" "$(nav enter)"
check "nav: the leaf's action ran and the chain closed" "term absent" \
	"$(eval_kiln 'return FIRED') $(live menu:box)"

# A leaf inside a submenu, walked to entirely by keyboard: two downs, an enter,
# a down, an enter. This is the whole verb set in one sequence.
set_lua 'FIRED = "none"
require("kiln").ui.menu {
  items = MENU, screen = screen.all()[1], x = 100, y = 100 }'
nav down >/dev/null
nav down >/dev/null
nav enter >/dev/null
nav down >/dev/null
check "nav: a submenu leaf is reachable by keyboard alone" "/2/2" "$(sel)"
nav enter >/dev/null
check "nav: and running it fired the submenu's action" "browser" \
	"$(eval_kiln 'return FIRED')"
check "nav: the whole chain closed behind it" "absent absent" \
	"$(live menu:box) $(live menu:box/2)"

# --- the claim: the chain holds the keyboard for its lifetime, and the key map
# is what turns a keysym into a verb. route_key is the call init.lua makes for
# every queued key, so these legs are the real rank.
check "claim: no menu, no claim on the keyboard" "false" "$(key Down)"
set_lua 'require("kiln").ui.menu {
  items = MENU, screen = screen.all()[1], x = 100, y = 100 }'
check "claim: an open menu takes the key" "true" "$(key Down)"
check "claim: and the map turned it into the verb" "/1" "$(sel)"
# A grab is a claim on the device, not a filter on some of its events: a key the
# map does not know is consumed too, and no binding sees it.
check "claim: an unmapped key is swallowed, not passed to bindings" "true" \
	"$(key F5)"
check "claim: Escape is the same back verb the map spells" "true" "$(key Escape)"
check "claim: the chain closed and released the keyboard" "closed false" \
	"$(sel) $(key Down)"

# One keyboard, one claim (grab.lua): a menu opening over a running prompt stops
# the prompt's grabber, and the prompt's own stopped callback drops it.
set_lua 'P = require("kiln").prompt.run { label = "x" }'
check "claim: the prompt holds the keyboard" "true" \
	"$(eval_kiln 'return tostring(require("kiln").prompt.active ~= nil)')"
set_lua 'require("kiln").ui.menu {
  items = MENU, screen = screen.all()[1], x = 100, y = 100 }'
check "claim: a menu over a prompt takes the claim, and the prompt drops" "nil" \
	"$(eval_kiln 'return tostring(require("kiln").prompt.active)')"
# The claim moved, not just "someone holds it": the key has to land in the MENU,
# which is what the selection moving says.
check "claim: the menu is the one holding it now" "true /1" "$(key Down) $(sel)"
nav close >/dev/null
check "nav: close ends the chain" "absent" "$(live menu:box)"

# Belt and braces before the sections that press: whatever the legs above left
# behind, no chain is open past this line, so no scrim eats a press.
set_lua 'require("kiln").menu.close()'

# --- the tasklist: one row per client, keyed by handle. The ids ARE the claim:
# an index-keyed list would renumber every row after a removal, moving a row's
# press handler and its box onto its neighbour.
before=$(tasks)
check "tasklist: one row per mapped client" "3" \
	"$(echo "$before" | wc -w | tr -d ' ')"

# A title longer than a row may be does not make the row longer, and does not
# make it taller either. This is the declaration-level statement that the label
# is no longer cut to a character count before it is declared: the row is bounded
# by the max it declared, and its clip is what keeps an overflowing title on one
# line instead of wrapping onto a second one the bar has no height for.
#
# Bounded AND widest, because either alone is passable by a broken row: a row
# that collapsed would also be under the bound. Not pinned to the bound exactly,
# because this bar carries enough other chrome to compress the list, which is the
# solver's business and not this leg's.
check "tasklist: an over-long title fills its row to the bound and no further" \
	"bounded" "$(eval_kiln '
local s = screen.all()[1]
local wide, other = nil, 0
for _, t in ipairs(s.tags) do
  for _, c in ipairs(t.clients) do
    local b = core.box("task:" .. c.handle)
    if b ~= nil then
      if (c.title or ""):find("Handgloves") then wide = b.width
      elseif b.width > other then other = b.width end
    end
  end
end
if wide == nil then return "no long-titled row" end
if wide > 180 then return "over the bound: " .. wide end
if wide <= other then return "not the widest: " .. wide .. "/" .. other end
return "bounded"')"
check "tasklist: and every row is the same one-line height" "1" \
	"$(eval_kiln '
local s = screen.all()[1]
local seen = {}
for _, t in ipairs(s.tags) do
  for _, c in ipairs(t.clients) do
    local b = core.box("task:" .. c.handle)
    if b ~= nil then seen[math.floor(b.height)] = true end
  end
end
local n = 0
for _ in pairs(seen) do n = n + 1 end
return n')"

# The label's clip is keyed by ROW POSITION while the row itself is keyed by
# handle, and that split is what keeps the list inside Clay's scroll-container
# budget: Clay makes every clipping element a scroll container, keeps ten of them
# per context, and frees a slot only inside the helper this project prohibits. A
# clip id that varied per client would therefore spend one of the ten per window
# ever mapped, and the eleventh window ever would abort the compositor.
#
# Position four is asserted ABSENT rather than reading the count off the list,
# because the absence is the claim: a set that grew instead of being reused would
# leave a fourth position behind after the swap below, and a clip keyed by handle
# again would leave no position ids at all.
scr=$(eval_kiln 'return screen.all()[1].name')
check "tasklist: one clip per row position, not per client" \
	"live live live absent" \
	"$(live "taskclip:$scr:1") $(live "taskclip:$scr:2") \
$(live "taskclip:$scr:3") $(live "taskclip:$scr:4")"

# Kill the FIRST client: an index-keyed list would shift rows 2 and 3 down into
# ids 1 and 2. Keyed by handle, the survivors keep the exact ids they had.
set_lua 'screen.all()[1].selected_tag.clients[1]:kill()'
sleep 2
eval_kiln 'core.dirty()' >/dev/null
sleep 0.6
after=$(tasks)
check "tasklist: the killed client's row is gone" "2" \
	"$(echo "$after" | wc -w | tr -d ' ')"
check "tasklist: the survivors keep their ids (keyed, not indexed)" \
	"$(echo "$before" | cut -d' ' -f2-3)" "$after"
# And the clip ids went the other way: two rows means positions one and two, with
# three retired rather than retained. Row ids are history, clip ids are inventory.
check "tasklist: a closed window returns its clip position" "live live absent" \
	"$(live "taskclip:$scr:1") $(live "taskclip:$scr:2") $(live "taskclip:$scr:3")"

# --- the filter is a predicate, nothing more.
set_lua 'screen.all()[1].selected_tag.clients[1]:focus()
FILTER = function(c) return c == client.focus end'
check "tasklist: a predicate filter leaves only what it admits" "1" \
	"$(tasks | wc -w | tr -d ' ')"
check "tasklist: and it is the focused client's row" "live" \
	"$(live "task:$(eval_kiln 'return client.focus.handle')")"

# --- a tag switch empties the default filter, because currenttags is a fact
# about the client, read at declare.
set_lua 'FILTER = nil
screen.all()[1].tags[2]:view()'
check "tasklist: switching to an empty tag empties the list" "" "$(tasks)"
set_lua 'screen.all()[1].tags[1]:view()'
check "tasklist: switching back brings the rows back" "2" \
	"$(tasks | wc -w | tr -d ' ')"

# --- the layoutbox reflects t.layout, and pressing it cycles. The name comes
# from layout.name, and the expectation is restated from layout.list here, so a
# box showing a stale or wrong name fails.
check "layoutbox: reflects the tag's layout" "tile" \
	"$(eval_kiln 'local L = require("kiln.layout")
return L.name(screen.all()[1].selected_tag.layout)')"
check "layoutbox: is declared in the bar" "live" \
	"$(live "layoutbox:$(eval_kiln 'return screen.all()[1].name')")"

# A direct property write: the box follows the tag, with no update path.
set_lua 'screen.all()[1].selected_tag.layout = require("kiln.layout").max'
check "layoutbox: a property write is the whole verb" "max" \
	"$(eval_kiln 'local L = require("kiln.layout")
return L.name(screen.all()[1].selected_tag.layout)')"

# And pressing it advances to the next entry in layout.list, whatever that is.
expected=$(eval_kiln 'local L = require("kiln.layout")
local t = screen.all()[1].selected_tag
return L.name(L.next(t.layout))')
check "layoutbox: pressing it hits the box" \
	"layoutbox:$(eval_kiln 'return screen.all()[1].name')" \
	"$(press "layoutbox:$(eval_kiln 'return screen.all()[1].name')")"
check "layoutbox: the press cycled to the next layout" "$expected" \
	"$(eval_kiln 'local L = require("kiln.layout")
return L.name(screen.all()[1].selected_tag.layout)')"

# The compositor stayed clean throughout: no Lua errors on the bus, no
# tree-vs-scene divergence from the always-on reconciler checks. Every menu
# open, nest, and dismiss above went through the reconcile this proves survived.
#
# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's pcall,
# so this leg MUST go red under it, which is what proves the grep can see a
# failure at all.
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
