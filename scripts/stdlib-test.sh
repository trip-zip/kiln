#!/bin/sh
# The stdlib slice battery: the two motions of the slice, proved on the public
# API.
#
#   scripts/stdlib-test.sh
#
#   1. widgets.taglist / widgets.tasklist / widgets.layoutbox take a HANDLER
#      TABLE (cfg.on), so a config adds gestures instead of forking the whole
#      widget. The contract under test is preempt-and-decline: a handler
#      returning truthy owns the gesture, a handler returning nothing lets the
#      stdlib default run.
#   2. The hotkeys popup is stdlib (kiln.hotkeys / ui.hotkeys), fed by the
#      key_specs registry, dismissed from the keyboard, and honest about what it
#      advertises.
#
# THE PAIRED CONTROL IS THE POINT. Every fix lives in lua/kiln, never in the rc
# below, so this same script runs on the pre-fix build and the fixed one. The rc is written to LOAD on both arms (it guards the one
# name that does not exist before the fix, kiln.hotkeys), because a config that
# fails to load turns the controls red too and a red arm has to stay
# attributable. Controls are marked and must be GREEN ON BOTH ARMS.
#
# PRESSES ARE RESTATED, NOT DRIVEN (the menu-test.sh discipline). Headless has no
# input device, so a chrome press walks core.hits innermost-first and fires the
# first id carrying a handler, against the press table the declare just built,
# now WITH a synthetic ev (the same press payload a chrome handler receives).
# That proves ROUTING, and it fails loudly for a widget that registers a handler
# under an id nothing hits. Keys go through grab.route_key, which is what
# init.lua calls for every queued key.
#
# EXISTENCE IS ASSERTED THROUGH core.hits, NEVER core.box, except where a box is
# read as GEOMETRY on an id already known live: Clay's element hashmap is
# persistent, so core.box answers with the last box an id ever had.
#
# Needs: foot (the tasklist legs need one real client), rsvg-convert (one real
# PNG for the layout glyph leg).
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-stdlib-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
rc="$work/rc.lua"
kiln_pid=""
client_pid=""

cleanup() {
	[ -n "$client_pid" ] && kill "$client_pid" 2>/dev/null || true
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

# A real PNG for the th.layout_icons leg. Generated rather than committed, the
# assets-test.sh way: what is under test is that the theme key routes an image
# into the layoutbox, not what the pixels are.
printf '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16">' \
	> "$work/glyph.svg"
printf '<rect width="16" height="16" fill="#ffffff"/></svg>' >> "$work/glyph.svg"
rsvg-convert -w 16 -h 16 -o "$work/glyph.png" "$work/glyph.svg"

# The rc under test. Every handler records into a global the battery reads back,
# so "the handler ran" is a fact and not an inference from a side effect the
# stdlib default would also have produced.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
local ui, th, key = kiln.ui, kiln.theme, kiln.key
local widgets = kiln.widgets

TAG_LOG, TASK_LOG, BOX_LOG = {}, {}, {}
TAG_SCROLLS, TASK_SCROLLS = 0, 0

-- Right button: handled, and the tag is TOGGLED into the selection rather than
-- viewed alone. Anything else: declined, so the stdlib default (view) runs. One
-- handler covers both halves of the contract.
local function tag_press(t, ev)
	TAG_LOG[#TAG_LOG + 1] = t.name .. ":" .. tostring(ev and ev.button)
	if ev ~= nil and ev.button == 3 then
		t:toggle()
		return true
	end
end

local function tag_scroll(ev)
	TAG_SCROLLS = TAG_SCROLLS + 1
	TAG_SCROLL_DY = ev ~= nil and ev.dy or nil
end

-- Right button: handled, and MINIMIZES, which is the observable that separates
-- the two arms without needing a pre-state. The stdlib default unminimizes and
-- focuses, so a default that also ran would undo this.
local function task_press(c, ev)
	TASK_LOG[#TASK_LOG + 1] = tostring(c.handle) .. ":" .. tostring(ev and ev.button)
	if ev ~= nil and ev.button == 3 then
		c.minimized = true
		return true
	end
end

local function task_scroll()
	TASK_SCROLLS = TASK_SCROLLS + 1
end

local function box_press(t, ev)
	BOX_LOG[#BOX_LOG + 1] = t.name .. ":" .. tostring(ev and ev.button)
	if ev ~= nil and ev.button == 3 then
		return true
	end
end

-- The layout glyph as a theme key, the th.menu_submenu_icon precedent: family
-- name to image path. Only tile is named, so the fallback text label is still
-- exercised by every other layout.
th.layout_icons = { tile = os.getenv("KILN_TEST_GLYPH") }

screen.on("added", function(s)
	tag.new { name = "term", screen = s, layout = kiln.layout.tile }
	tag.new { name = "web", screen = s, layout = kiln.layout.tile }
	tag.new { name = "chat", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()

	ui.bar(s, { edge = "top", h = 28, color = th.bg }, function()
		widgets.taglist(s, { on = { press = tag_press, scroll = tag_scroll } })
		widgets.layoutbox(s, { on = { press = box_press } })
		widgets.tasklist(s, { on = { press = task_press, scroll = task_scroll } })
	end)
end)

-- The popup's toggle is a config binding reading a stdlib verb, which is the
-- whole of the promotion: the registry entry stays the config's, the sheet is
-- kiln's. Guarded so this rc still loads on the pre-fix arm.
local hotkeys = kiln.hotkeys or {}
key { mods = { "mod" }, key = "s", desc = "show keys", group = "demo",
	press = function()
		if hotkeys.toggle ~= nil then hotkeys.toggle() end
	end }

-- A per-frame declare hook owned by the config, which is chrome without a bar:
-- no strut, no reserved edge, just a float declared every frame. Guarded so
-- this rc still loads on the pre-fix arm, where the name does not exist.
if kiln.on_declare ~= nil then
	-- passthrough, and one offset per hook. Existence here is asserted through
	-- core.hits, and a capturing overlay float is opaque to it: three of them
	-- stacked on the root origin would answer as one, and an overlay sitting
	-- over the bar would hide the taglist's own chrome from every other leg in
	-- this battery. A passthrough float stays in the hit list without blocking,
	-- which is what a probe wants and what a wallpaper wants for the same
	-- reason.
	kiln.on_declare(function(s)
		ui.box({
			id = "rchook",
			float = { to = "root", band = "overlay", passthrough = true },
			w = 20, h = 20, color = "#ff00ffff",
		})
	end)
end
key { mods = { "mod" }, key = "Return", desc = "spawn a terminal",
	group = "demo", press = function() end }
key { mods = { "mod" }, key = "1-9", desc = "view tag", group = "tag",
	press = function() end }
EOF

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	KILN_TEST_GLYPH="$work/glyph.png" \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

sname=$(eval_kiln 'return screen.all()[1].name')
wl=$(sed -n 's/.*WAYLAND_DISPLAY=\([^ ]*\).*/\1/p' "$log" | head -1)

# --- the readbacks.

set_lua() {
	eval_kiln "$1
core.dirty()" >/dev/null
	sleep 0.6
}

# live: is this id declared RIGHT NOW? core.hits names only what the last solve
# put under a point, so an element that stopped being declared stops being
# named, stale box or not.
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

# press: the dispatch path, restated, with an ev. init.lua's on_button walks the
# hits innermost-first and fires the FIRST one carrying a handler (no bubbling);
# it has to, because the innermost hit is usually an unnamed leaf. Returns the id
# whose handler actually ran, so a widget registering a handler under an id
# nothing hits fails here rather than passing vacuously.
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

# scroll: the same walk for the wheel edge. A widget's list-level gesture lives
# on the row it wraps its items in, so this is the honest test of whether that
# row exists AND carries the handler.
scroll() { # lua-id-expr ev-lua
	eval_kiln "
local st = require('kiln.state')
local s = screen.all()[1]
local id = $1
local b = core.box(id)
if b == nil then return 'no-box' end
local presses = st.screen_presses[s.name] or {}
for _, h in ipairs(core.hits(s.name, b.x + b.width / 2, b.y + b.height / 2)) do
  local fn = presses['on_scroll:' .. h.name .. '#' .. h.index]
  if fn ~= nil then
    fn($2)
    core.dirty()
    return h.name
  end
end
return 'no-handler'"
	sleep 0.6
}

# press_at: the same walk at a POINT rather than at an id's centre. The sheet's
# scrim needs it: the scrim's own box centre is where the sheet sits, and the
# sheet captures, so the scrim is only reachable where the sheet is not. That IS
# the scrim's contract ("a press outside dismisses"), so pressing it anywhere
# else would prove the wrong thing.
press_at() { # x y
	eval_kiln "
local st = require('kiln.state')
local s = screen.all()[1]
local presses = st.screen_presses[s.name] or {}
for _, h in ipairs(core.hits(s.name, $1, $2)) do
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

# rkey: one key through the mechanism init.lua uses for every queued key. Returns
# whether a grab claim consumed it, which IS the modal claim under test.
rkey() { # keyname
	eval_kiln "return tostring(require('kiln.grab').route_key
  { pressed = true, key = '$1' })"
	sleep 0.6
}

selected() {
	eval_kiln 'local o = {}
for _, t in ipairs(screen.all()[1].tags) do
  if t.selected then o[#o+1] = t.name end
end
return table.concat(o, " ")'
}

# =====================================================================
# Motion 1, the taglist. Its handler table carries the two kilnrc gestures the
# stdlib widget could not express, and the decline path is asserted separately
# from the handled path.

check "CONTROL: the taglist declares a cell per tag" "live" "$(live '{ "tag", 2 }')"
check "CONTROL: the first tag is the viewed one" "term" "$(selected)"

# A declined press: the handler sees the tag and the ev, returns nothing, and the
# stdlib default views. Both halves are asserted, because a handler that ran and
# a default that ran are two different claims.
check "a left press routes to the config handler" "tag" \
	"$(press '{ "tag", 2 }' '{ button = 1, mods = {} }')"
check "the handler saw the tag and the button" "web:1" \
	"$(eval_kiln 'return table.concat(TAG_LOG, " ")')"
check "declining kept the stdlib default (the tag was viewed)" "web" "$(selected)"

# A handled press: the handler toggles instead, returns true, and view must NOT
# run, which shows as two tags selected rather than one.
check "a right press routes to the same handler" "tag" \
	"$(press '{ "tag", 3 }' '{ button = 3, mods = {} }')"
check "returning true suppressed the default (toggled, not viewed)" "web chat" \
	"$(selected)"

# The list-level wheel, on the row the widget wraps its cells in.
check "the wheel routes to the list handler" "taglist:$sname" \
	"$(scroll "\"taglist:$sname\"" '{ dy = 1 }')"
check "the scroll handler ran once with its ev" "1 1" \
	"$(eval_kiln 'return TAG_SCROLLS .. " " .. tostring(TAG_SCROLL_DY)')"

# =====================================================================
# The occupancy square, which rides the widget because a config cannot float a
# child into a cell it does not declare.

set_lua 'screen.all()[1].tags[1]:view()'
check "an empty tag has no occupancy square" "absent" \
	"$(live '{ "tagsquare", 2 }')"

WAYLAND_DISPLAY="$wl" foot >/dev/null 2>&1 &
client_pid=$!
sleep 2
h1=$(eval_kiln 'local cs = screen.all()[1].tags[1].clients
return cs[1] ~= nil and cs[1].handle or "none"')
check "CONTROL: one client mapped onto tag 1" "true" \
	"$(eval_kiln 'return tostring(#screen.all()[1].tags[1].clients == 1)')"
check "the occupied tag declares its square" "live" \
	"$(live '{ "tagsquare", 1 }')"

# =====================================================================
# The tasklist handler table. Same contract, and the suppressed default is
# visible as focus NOT moving.

check "CONTROL: the tasklist declares a row for the client" "live" \
	"$(live "\"task:$h1\"")"
check "a right press routes to the config handler" "task:$h1" \
	"$(press "\"task:$h1\"" '{ button = 3, mods = {} }')"
check "the handler saw the client and the button" "$h1:3" \
	"$(eval_kiln 'return table.concat(TASK_LOG, " ")')"
check "returning true suppressed the unminimize/focus default" "true" \
	"$(eval_kiln 'return tostring(screen.all()[1].tags[1].clients[1].minimized)')"
check "a left press declines and the default runs" "task:$h1" \
	"$(press "\"task:$h1\"" '{ button = 1, mods = {} }')"
check "the default unminimized and focused the client" "false $h1" \
	"$(eval_kiln 'local c = screen.all()[1].tags[1].clients[1]
return tostring(c.minimized) .. " " ..
  (client.focus ~= nil and client.focus.handle or "none")')"
check "the tasklist wheel routes to the list handler" "tasklist:$sname" \
	"$(scroll "\"tasklist:$sname\"" '{ dy = -1 }')"
check "the tasklist scroll handler ran" "1" \
	"$(eval_kiln 'return TASK_SCROLLS')"

# =====================================================================
# The layoutbox: the same table, plus the glyph as a theme key.

check "CONTROL: the layoutbox is declared" "live" "$(live "\"layoutbox:$sname\"")"
check "th.layout_icons routes an image into the box" "live" \
	"$(live "\"layoutbox:glyph:$sname\"")"
before=$(eval_kiln 'return require("kiln").layout.name(
  screen.all()[1].selected_tag.layout)')
check "a right press routes to the config handler" "layoutbox:$sname" \
	"$(press "\"layoutbox:$sname\"" '{ button = 3, mods = {} }')"
check "returning true suppressed the cycle default" "$before" \
	"$(eval_kiln 'return require("kiln").layout.name(
  screen.all()[1].selected_tag.layout)')"
press "\"layoutbox:$sname\"" '{ button = 1, mods = {} }' >/dev/null
check "a left press declines and the default cycles" "true" \
	"$(eval_kiln "return tostring(require('kiln').layout.name(
  screen.all()[1].selected_tag.layout) ~= '$before')")"
check "the handler saw both presses" "term:3 term:1" \
	"$(eval_kiln 'return table.concat(BOX_LOG, " ")')"

# =====================================================================
# Motion 2, the hotkeys popup as stdlib. The toggle is the config's key{} entry
# calling a stdlib verb.

check "CONTROL: the sheet is nothing while closed" "absent" "$(live '"hotkeys"')"
set_lua "local b = require('kiln.state').keys['alt+s']
if b ~= nil and b.press ~= nil then b.press() end"
check "the toggle declared the sheet" "live" "$(live '"hotkeys"')"
check "a group header from the registry is declared" "live" "$(live '"hkgroup:demo"')"
check "the toggle's own chord is listed" "live" "$(live '"hkkey:alt+s"')"
check "a range reads back as its range, not as nine rows" "live" \
	"$(live '"hkkey:alt+1-9"')"
check "core.box finds the sheet's first column" "true" \
	"$(eval_kiln 'return tostring(core.box("hotkeys:col:1") ~= nil)')"

# The keyboard claim: the sheet outranks every binding while it is up, and Esc
# is the way out.
check "the open sheet holds the keyboard claim" "true" "$(rkey Escape)"
check "Escape closed the sheet" "absent" "$(live '"hotkeys"')"
check "the claim is released with the sheet" "false" "$(rkey Escape)"

set_lua "local b = require('kiln.state').keys['alt+s']
if b ~= nil and b.press ~= nil then b.press() end"
check "an unmapped key is swallowed by the sheet" "true" "$(rkey x)"
check "and dismisses it, the way a cheat sheet dismisses" "absent" \
	"$(live '"hotkeys"')"

set_lua "local b = require('kiln.state').keys['alt+s']
if b ~= nil and b.press ~= nil then b.press() end"
corner=$(eval_kiln 'return screen.all()[1].height - 5')
check "a press outside the sheet reaches its scrim" "hotkeys:scrim" \
	"$(press_at 5 "$corner")"
check "and the sheet is gone" "absent" "$(live '"hotkeys"')"

# =====================================================================
# Registry honesty: the registry the sheet reads must not advertise what cannot
# fire. Registered over IPC, not from the rc, because refusing a bad chord is an
# ERROR at bind time and an rc that fails to load would take the whole arm with
# it.

n0=$(eval_kiln 'return #require("kiln").key.all()')
set_lua 'local S = require("kiln")
S.key { mods = { "mod" }, key = "F1", desc = "first", group = "demo",
  press = function() end }
S.key { mods = { "mod" }, key = "F1", desc = "second", group = "demo",
  press = function() end }'
check "a rebound chord adds ONE registry row, not two" "$((n0 + 1))" \
	"$(eval_kiln 'return #require("kiln").key.all()')"
check "and the row that survives is the one that dispatches" "second" \
	"$(eval_kiln 'for _, k in ipairs(require("kiln").key.all()) do
  if k.key == "F1" then return tostring(k.desc) end
end
return "missing"')"

# Corrected by measurement: "1-10" is NOT accepted silently on the pre-fix
# build. C rejects the unknown key name, so the call raises. What it does
# silently is leave the wreckage: a state.keys entry that can never fire (C never
# got the binding) and a key_specs row the sheet would advertise. So the
# discriminating legs are the residue, not the raise.
n1=$(eval_kiln 'return #require("kiln").key.all()')
check "CONTROL: a range that is not key names is refused either way" "false" \
	"$(eval_kiln 'local S = require("kiln")
return tostring((pcall(S.key, { mods = { "mod" }, key = "1-10",
  press = function() end })))')"
check "the refusal left no dead chord behind" "true" \
	"$(eval_kiln 'return tostring(require("kiln.state").keys["alt+1-10"] == nil)')"
check "and advertised nothing in the registry" "$n1" \
	"$(eval_kiln 'return #require("kiln").key.all()')"
check "CONTROL: a good range still expands per key" "true" \
	"$(eval_kiln 'local ks = require("kiln.state").keys
return tostring(ks["alt+1"] ~= nil and ks["alt+9"] ~= nil)')"

# A chord that overlaps a range only PARTLY is not a registry row at all, so it
# is reported rather than silently mis-advertised.
set_lua 'BUS_ERRS = 0
local B = require("kiln.bus")
local prev = B.on_error
B.on_error = function(sig, err) BUS_ERRS = BUS_ERRS + 1; return prev(sig, err) end'
set_lua 'require("kiln").key { mods = { "mod" }, key = "3",
  desc = "partial", group = "demo", press = function() end }'
check "a partial overlap with a range is reported, not swallowed" "1" \
	"$(eval_kiln 'return BUS_ERRS')"

# =====================================================================
# Motion 3, the declare-hook registry. A bar was the only per-frame declare a
# config could own, and a bar reserves an edge, so chrome that is not a bar had
# to be smuggled through one. kiln.on_declare is that slot without the strut.
# It runs where the stdlib's own chrome runs, so a hook may attach a float to
# anything already declared this frame.

check "an rc hook declares its chrome" "live" "$(live '"rchook"')"

set_lua 'HOOK_RAN = 0
IPC_HOOK = require("kiln").on_declare(function(s)
  HOOK_RAN = HOOK_RAN + 1
  require("kiln.ui").box({ id = "ipchook",
    float = { to = "root", band = "overlay", passthrough = true,
      offset = { x = 40, y = 0 } },
    w = 20, h = 20, color = "#00ffffff" })
end)'
check "a hook registered at runtime declares too" "live" "$(live '"ipchook"')"
check "and it is the hook that ran, not a coincidence" "true" \
	"$(eval_kiln 'return tostring(HOOK_RAN > 0)')"

# Error isolation. One bad hook must take neither the hooks around it nor the
# frame: C rebalances Clay's open stack after a failed declare, so the cost is
# one frame of misnesting and never an abort.
set_lua 'BAD_ERRS = 0
local B = require("kiln.bus")
local prev = B.on_error
B.on_error = function(sig, err) BAD_ERRS = BAD_ERRS + 1; return prev(sig, err) end
local S = require("kiln")
S.on_declare(function() error("boom") end)
S.on_declare(function(s)
  require("kiln.ui").box({ id = "afterbad",
    float = { to = "root", band = "overlay", passthrough = true,
      offset = { x = 80, y = 0 } },
    w = 20, h = 20, color = "#ffff00ff" })
end)'
check "an erroring hook is reported, not swallowed" "true" \
	"$(eval_kiln 'return tostring(BAD_ERRS > 0)')"
check "the compositor is still answering" "1" "$(eval_kiln 'return 1')"
check "a hook registered BEFORE the bad one still declares" "live" \
	"$(live '"ipchook"')"
check "and one registered AFTER it declares too" "live" "$(live '"afterbad"')"

set_lua 'require("kiln").off_declare(IPC_HOOK)'
check "off_declare drops the hook" "absent" "$(live '"ipchook"')"
check "and leaves the others alone" "live" "$(live '"rchook"')"

# The reload tiers. A hook is config state: the rc re-runs and registers again,
# while one registered at runtime is simply gone, which is the bus mark/reset
# discipline applied to declares.
set_lua 'require("kiln").reload()'
sleep 1
eval_kiln 'core.dirty()' >/dev/null
sleep 0.6
check "reload re-runs the rc, so the rc's hook is back" "live" \
	"$(live '"rchook"')"
check "but a hook registered at runtime is dropped" "absent" \
	"$(live '"afterbad"')"

# =====================================================================
printf '\n'
if [ "$fail" -eq 0 ]; then
	printf 'PASS\n'
else
	printf 'FAIL\n'
fi
exit "$fail"
