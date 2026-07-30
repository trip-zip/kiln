#!/bin/sh
# The kilnrc.lua parity battery. It boots the REAL kilnrc.lua headless and proves
# that a config declaring a whole desktop (bar, tags, 65 key entries, rules,
# prompts, menus, notifications) stands on kiln's PUBLIC API alone:
#
#   scripts/parity-test.sh
#
# The static half proves it by grep: kilnrc reaches for no compositor primitive
# (grep -c 'core\.' is 0), requires only the one public module, and carries no
# emdashes (house style). The live half boots the config and reads the declared
# scene and registries back over IPC.
#
# PRESSES ARE RESTATED, NOT DRIVEN. Headless has no input device
# (WLR_LIBINPUT_NO_DEVICES=1), so a chrome press is dispatched the way init.lua's
# on_button does: look the handler up in the press table the declare built and call
# it, now WITH a synthetic ev, because chrome handlers are invoked as
# pcall(fn, ev). A key goes through the bound-chord table. A green run proves
# ROUTING, DECLARATION and the registry shape; it does not claim a pointer or key
# was physically actuated.
#
# EXISTENCE IS ASSERTED THROUGH core.hits, NEVER core.box: Clay's element hashmap
# is persistent, so core.box keeps answering with the last box an id had after it
# stops being declared, while core.hits names only what the last solve put under a
# point.
#
# BUS ERRORS ARE COUNTED IN-PROCESS, because the log grep alone is vacuous here:
# the error-path section below fires a real bus error on purpose. A Bus.on_error
# wrapper counts every error the dispatcher pcall-caught, and the clean gate
# asserts it stayed zero across the whole run.
#
# OUT OF HEADLESS SCOPE, named here rather than papered over: the wlroots-routing
# rule is asserted by registry shape only (a nested compositor spawn needs a real
# session); audio/brightness/screenshot bindings are asserted present, not fired
# (they shell out to wpctl/brightnessctl/grim); multi-output screen focus is a
# single-output no-op.
#
# Needs: foot.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
rc="$repo/kilnrc.lua"
work="$(mktemp -d /tmp/kiln-parity-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
# Isolate the theme file the switch_theme leg writes: XDG_CONFIG_HOME under the
# workdir, so the reload test never touches the user's real ~/.config/kiln.
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

# =====================================================================
# The static half: the greps that prove the public-API-only claim. Run before the
# boot, because a config that fails them proves nothing live.

check "kilnrc reaches for no compositor primitive" "0" \
	"$(grep -c 'core\.' "$rc")"
check "kilnrc requires exactly one module" "1" \
	"$(grep -c 'require(' "$rc")"
check "and that module is kiln" "kiln" \
	"$(sed -n 's/.*require("\([^"]*\)").*/\1/p' "$rc" | head -1)"
check "no emdashes (house style)" "0" \
	"$(grep -cP '\x{2014}' "$rc" || true)"

# =====================================================================
# Boot the real kilnrc.lua on the headless backend. KILN_WALLPAPER unset so the
# backdrop is the solid fallback; XDG_CONFIG_HOME isolated for the theme leg.

unset KILN_WALLPAPER || true
# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln \
	> "$log" 2>&1 &
kiln_pid=$!
sleep 2

check "the compositor booted" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"

wl_disp=$(sed -n 's/.*Running Wayland compositor on WAYLAND_DISPLAY=//p' "$log" | head -1)
for i in 1 2 3; do
	WAYLAND_DISPLAY="$wl_disp" foot >"$work/foot$i.log" 2>&1 &
done
sleep 4

set_lua() {
	eval_kiln "$1
core.dirty()" >/dev/null
	sleep 0.6
}

sname=$(eval_kiln 'return screen.all()[1].name')

# live: is this id declared RIGHT NOW? (rc-test.sh's helper.)
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

# fire a chrome handler by its press-table key, optionally with a synthetic ev.
fire() { # press-key [ev-lua]
	set_lua "local st = require('kiln.state')
local p = st.screen_presses['$sname'] or {}
local h = p['$1']
if h ~= nil then h(${2:-}) end"
}

# fire a bound key chord's press (model-test.sh's convention).
key_fire() { # chord
	set_lua "local b = require('kiln.state').keys['$1']
if b ~= nil and b.press ~= nil then b.press() end"
}

# The in-process bus-error counter, since a log grep alone is vacuous here.
# Installed after boot, so a clean gate late in the run can assert nothing errored
# through the dispatcher.
set_lua "local B = require('kiln.bus')
PARITY_BUS_ERRORS = 0
if not PARITY_WRAPPED then
  PARITY_WRAPPED = true
  local orig = B.on_error
  B.on_error = function(...) PARITY_BUS_ERRORS = (PARITY_BUS_ERRORS or 0) + 1
    return orig(...) end
end"

# =====================================================================
# The bar and its static chrome: launcher, taglist, tasklist, layoutbox, clock,
# plus the root backdrop the wallpaper substitution carries.

# Probe the bar's own paint at its top edge (no widget reaches y=2, the
# leaves are align-center).
check "the bar is declared" "true" \
	"$(eval_kiln 'local s = screen.all()[1]
for _, h in ipairs(core.hits(s.name, 2, 2)) do
  if h.name == "bar" then return "true" end
end
return "false"')"
check "the launcher glyph is declared (SUBSTITUTION 2)" "live" "$(live '"launcher"')"
check "the backdrop is declared (SUBSTITUTION 1, KILN_WALLPAPER unset)" "live" \
	"$(live '"backdrop"')"
check "the layoutbox is declared for this screen" "live" \
	"$(live "\"layoutbox:$sname\"")"
check "the clock is declared" "live" "$(live '"clock"')"
# The clock is centered IN FLOW: the bar's three regions are percent thirds,
# which the solver sizes unconditionally (third_party/clay.h:2292-2297), so
# the middle third's center is the bar's center even with this battery's real
# clients filling the tasklist. Geometry, not existence, so core.box is the
# sound probe here; the stale-box trap needs an id that STOPPED being
# declared, and the live leg above just proved this one has not.
check "the clock's center is the bar's center (within a pixel)" "true" \
	"$(eval_kiln 'local c = core.box("clock")
local b = core.box({ "bar", 1 })
if c == nil or b == nil then return "no box" end
return tostring(math.abs(
  (c.x + c.width / 2) - (b.x + b.width / 2)) <= 1)')"
check "a taglist cell is declared" "live" "$(live '{ "tag", 1 }')"

# =====================================================================
# Tags: five named dev/web/chat/files/media, tags[1] selected, all tile.

check "the config declared five named tags" "dev web chat files media" \
	"$(eval_kiln 'local o = {}
for _, t in ipairs(screen.all()[1].tags) do o[#o+1] = t.name end
return table.concat(o, " ")')"
check "tags[1] is the selected tag" "dev" \
	"$(eval_kiln 'return screen.all()[1].selected_tag.name')"
check "every tag runs the tile layout" "true" \
	"$(eval_kiln 'local S = require("kiln")
for _, t in ipairs(screen.all()[1].tags) do
  if S.layout.name(t.layout) ~= "tile" then return "false" end
end
return "true"')"

# The parity layout cycle, minus a fullscreen-only layout: kiln has no such
# layout, a deliberate omission.
check "the layout cycle has the parity set (13 entries)" "13" \
	"$(eval_kiln 'return #require("kiln").layout.list')"

# =====================================================================
# The key registry (kiln.key.all(): one entry per key{} CALL, not per expanded
# chord). The parity binding set is 64 calls: numrow is 4 "1-9" ranges (one entry
# each), numpad is nine explicit KP_n calls, because kiln has no keygroup mechanism
# to fold them. Plus one kiln-only chord, mod+shift+i, the Clay inspector toggle:
# 65 total.

check "the registry has 64 parity + 1 inspector key{} entries" "65" \
	"$(eval_kiln 'return #require("kiln").key.all()')"
check "the group set matches kilnrc's" \
	"audio brightness client kiln launcher layout screen screenshot tag" \
	"$(eval_kiln 'local S = require("kiln")
local seen, order = {}, {}
for _, k in ipairs(S.key.all()) do
  local g = k.group or "?"
  if not seen[g] then seen[g] = true; order[#order+1] = g end
end
table.sort(order)
return table.concat(order, " ")')"
check "the numrow reads back as a single 1-9 range row" "true" \
	"$(eval_kiln 'for _, k in ipairs(require("kiln").key.all()) do
  if k.key == "1-9" then return "true" end
end
return "false"')"
check "spot chords are bound (super+Return, XF86, Print, super+KP_1)" "true" \
	"$(eval_kiln 'local ks = require("kiln.state").keys
return tostring(ks["super+Return"] ~= nil and ks["XF86AudioRaiseVolume"] ~= nil
  and ks["Print"] ~= nil and ks["super+KP_1"] ~= nil)')"

# =====================================================================
# Key behaviors, fired through the bound-chord table.

# view/toggle a tag (super+2 view, ctrl+super+3 toggle -> two selected).
key_fire "super+2"
check "super+2 views tag 2" "web" \
	"$(eval_kiln 'return screen.all()[1].selected_tag.name')"
key_fire "ctrl+super+3"
check "ctrl+super+3 toggles a second tag into view" "2" \
	"$(eval_kiln 'return #screen.all()[1].selected_tags')"
key_fire "super+1"

# focus a client, move it to a tag, follow it there (shift+super+2).
set_lua 'local c = screen.all()[1].tags[1].clients[1]
if c ~= nil then c:focus() end'
moved=$(eval_kiln 'return client.focus and client.focus.handle or "-"')
key_fire "shift+super+2"
check "shift+super+2 moves the focused client to tag 2" "true" \
	"$(eval_kiln "local t = screen.all()[1].tags[2]
for _, c in ipairs(t.clients) do if c.handle == $moved then return 'true' end end
return 'false'")"
# toggle the same client on tag 3 (ctrl+shift+super+3): now on two tags.
set_lua "for _, t in ipairs(screen.all()[1].tags) do
  for _, c in ipairs(t.clients) do if c.handle == $moved then c:focus() end end
end"
key_fire "ctrl+shift+super+3"
check "ctrl+shift+super+3 toggles the client onto a second tag" "true" \
	"$(eval_kiln "for _, c in ipairs(client.all()) do
  if c.handle == $moved then return tostring(#c.tags == 2) end
end
return 'false'")"
# put it back on tag 1 alone for the tests that follow.
set_lua "for _, c in ipairs(client.all()) do
  if c.handle == $moved then c.tags = { screen.all()[1].tags[1] } end
end
screen.all()[1].tags[1]:view()"

# focus by index cycles the visible clients (super+j).
set_lua 'screen.all()[1].tags[1].clients[1]:focus()'
first=$(eval_kiln 'return client.focus.handle')
key_fire "super+j"
check "super+j focuses the next client by index" "true" \
	"$(eval_kiln "return tostring(client.focus ~= nil and client.focus.handle ~= $first)")"

# mwfact, master_count, column_count writes (super+l, shift+super+h, ctrl+super+h).
key_fire "super+l"
check "super+l bumps master_width_factor toward 0.55" "true" \
	"$(eval_kiln 'local m = screen.all()[1].selected_tag.master_width_factor
return tostring(m ~= nil and math.abs(m - 0.55) < 0.001)')"
key_fire "shift+super+h"
check "shift+super+h bumps master_count to 2" "2" \
	"$(eval_kiln 'return tostring(screen.all()[1].selected_tag.master_count)')"
key_fire "ctrl+super+h"
check "ctrl+super+h bumps column_count to 2" "2" \
	"$(eval_kiln 'return tostring(screen.all()[1].selected_tag.column_count)')"

# layout next then prev round-trips (super+space / shift+super+space).
before_l=$(eval_kiln 'return require("kiln").layout.name(screen.all()[1].selected_tag.layout)')
key_fire "super+space"
key_fire "shift+super+space"
check "super+space then shift+super+space round-trips the layout" "$before_l" \
	"$(eval_kiln 'return require("kiln").layout.name(screen.all()[1].selected_tag.layout)')"

# KP_2 picks list[2] directly (super+KP_2).
key_fire "super+KP_2"
check "super+KP_2 selects layout.list[2]" "true" \
	"$(eval_kiln 'local S = require("kiln")
return tostring(screen.all()[1].selected_tag.layout == S.layout.list[2])')"
# put tag 1 back on tile for the chrome-gesture tests.
set_lua 'screen.all()[1].selected_tag.layout = require("kiln").layout.tile'

# sticky and ontop read back (super+comma sticky, super+t ontop).
set_lua 'screen.all()[1].tags[1].clients[1]:focus()'
key_fire "super+comma"
check "super+comma toggles the focused client sticky" "true" \
	"$(eval_kiln 'return tostring(client.focus.sticky == true)')"
key_fire "super+comma"
key_fire "super+t"
check "super+t toggles the focused client ontop" "true" \
	"$(eval_kiln 'return tostring(client.focus.ontop == true)')"
key_fire "super+t"

# minimize then restore-minimized (super+n minimizes, ctrl+super+n restores).
set_lua 'screen.all()[1].tags[1].clients[1]:focus()'
mini=$(eval_kiln 'return client.focus.handle')
key_fire "super+n"
check "super+n minimizes the focused client" "true" \
	"$(eval_kiln "for _, c in ipairs(client.all()) do
  if c.handle == $mini then return tostring(c.minimized == true) end
end
return 'false'")"
key_fire "ctrl+super+n"
check "ctrl+super+n restores a minimized client" "false" \
	"$(eval_kiln "for _, c in ipairs(client.all()) do
  if c.handle == $mini then return tostring(c.minimized == true) end
end
return 'false'")"

# tag history restore toggles the last two selections (super+Escape).
set_lua 'screen.all()[1].tags[3]:view()'
key_fire "super+Escape"
check "super+Escape (tag history) returns to the previous selection" "dev" \
	"$(eval_kiln 'return screen.all()[1].selected_tag.name')"
set_lua 'screen.all()[1].tags[1]:view()'

# =====================================================================
# Chrome gestures, fired through the press table with a synthetic ev: chrome
# handlers are invoked as pcall(fn, ev), which is what makes ev.button and ev.mods
# reachable.

# taglist plain right-click toggles the tag into the selection.
fire 'on_press:tag#3' '{ button = 3, mods = {} }'
check "taglist right-click toggles a tag into view" "2" \
	"$(eval_kiln 'return #screen.all()[1].selected_tags')"
set_lua 'screen.all()[1].tags[1]:view()'

# taglist mod+left-click moves the focused client to that tag.
set_lua 'screen.all()[1].tags[1].clients[1]:focus()'
tgt=$(eval_kiln 'return client.focus.handle')
fire 'on_press:tag#2' '{ button = 1, mods = { super = true } }'
check "taglist mod+left-click moves the focused client to the tag" "true" \
	"$(eval_kiln "local t = screen.all()[1].tags[2]
for _, c in ipairs(t.clients) do if c.handle == $tgt then return 'true' end end
return 'false'")"
set_lua "for _, c in ipairs(client.all()) do
  if c.handle == $tgt then c.tags = { screen.all()[1].tags[1] } end
end
screen.all()[1].tags[1]:view()"

# backdrop scroll changes the tag (the root wheel binding rides the backdrop).
set_lua 'screen.all()[1].tags[1]:view()'
fire 'on_scroll:backdrop#0' "{ dy = 1, screen = '$sname' }"
check "backdrop scroll advances the tag (root wheel binding)" "web" \
	"$(eval_kiln 'return screen.all()[1].selected_tag.name')"
set_lua 'screen.all()[1].tags[1]:view()'

# layoutbox right-click steps the layout backwards.
set_lua 'screen.all()[1].selected_tag.layout = require("kiln").layout.list[2]'
fire 'on_press:layoutbox:'"$sname"'#0' '{ button = 3 }'
check "layoutbox right-click steps the layout backwards" "true" \
	"$(eval_kiln 'local S = require("kiln")
return tostring(screen.all()[1].selected_tag.layout == S.layout.list[1])')"
set_lua 'screen.all()[1].selected_tag.layout = require("kiln").layout.tile'

# tasklist right-click opens the client-list menu.
th1=$(eval_kiln 'return screen.all()[1].tags[1].clients[1].handle')
fire "on_press:task:$th1#0" '{ button = 3 }'
check "tasklist right-click opens the client-list menu" "true" \
	"$(eval_kiln 'local m = require("kiln.menu").open
return tostring(m ~= nil and #m.levels == 1)')"
check "the client-list menu has one row per mapped client" "true" \
	"$(eval_kiln 'local m = require("kiln.menu").open
local n = 0
for _, c in ipairs(client.all()) do if c.mapped then n = n + 1 end end
return tostring(m ~= nil and #m.levels[1].items == n)')"
set_lua 'require("kiln.menu").close()'

# tasklist plain left-click toggles minimization of its client (focused ->
# minimized). Focus it first so the toggle takes the minimize branch.
set_lua "for _, c in ipairs(client.all()) do
  if c.handle == $th1 then c:focus() end
end"
fire "on_press:task:$th1#0" '{ button = 1, mods = {} }'
check "tasklist left-click toggles its client (focused -> minimized)" "true" \
	"$(eval_kiln "for _, c in ipairs(client.all()) do
  if c.handle == $th1 then return tostring(c.minimized == true) end
end
return 'false'")"
set_lua "for _, c in ipairs(client.all()) do
  if c.handle == $th1 then c.minimized = false end
end"

# =====================================================================
# Rules and the titlebar override. Three rule{} calls (global placement, floating
# apps, wlroots routing); no titlebar rule, because titlebars on is kiln's default
# posture.

check "the rule registry has three entries" "3" \
	"$(eval_kiln 'return #require("kiln.state").rules')"
check "the wlroots-routing rule carries tag=media and focus=false" "true" \
	"$(eval_kiln 'for _, r in ipairs(require("kiln.state").rules) do
  local p = r.props or {}
  if p.tag == "media" and p.focus == false then return "true" end
end
return "false"')"

# the titlebar override: icon/title/float/max/close, plus the added float button.
# These run BEFORE the floating Gpick spawns below: `live` is a hit test, and a
# floating client parked over a tiled client's titlebar covers its buttons, so
# probing them with a window on top asserts stacking, not declaration.
tb=$(eval_kiln 'return screen.all()[1].tags[1].clients[1].handle')
check "the titlebar override is declared for a client" "live" \
	"$(live "{ \"titlebar\", $tb }")"
check "the titlebar carries the added float button" "live" \
	"$(live "{ \"float\", $tb }")"
check "the titlebar carries the maximize button" "live" \
	"$(live "{ \"maximize\", $tb }")"
check "the titlebar carries the close button" "live" \
	"$(live "{ \"close\", $tb }")"
# the float button toggles floating.
was_float=$(eval_kiln "for _, c in ipairs(client.all()) do
  if c.handle == $tb then return tostring(c.floating == true) end
end
return 'false'")
fire "on_press:float#$tb"
check "the titlebar float button toggles floating" "true" \
	"$(eval_kiln "for _, c in ipairs(client.all()) do
  if c.handle == $tb then return tostring((c.floating == true) ~= ($was_float)) end
end
return 'false'")"
# the close button drops the client.
before_n=$(eval_kiln 'return #client.all()')
fire "on_press:close#$tb"
sleep 1
check "the titlebar close button drops the client count" "true" \
	"$(eval_kiln "return tostring(#client.all() < $before_n)")"

# a floating-rule app floats on map (foot --app-id=Gpick).
WAYLAND_DISPLAY="$wl_disp" foot --app-id=Gpick >"$work/gpick.log" 2>&1 &
sleep 3
set_lua 'core.dirty()'
check "a floating-rule app (Gpick) floats on map" "true" \
	"$(eval_kiln 'for _, c in ipairs(client.all()) do
  if c.app_id == "Gpick" then return tostring(c.floating == true) end
end
return "false"')"

# =====================================================================
# Prompts: the run prompt, the lua-eval prompt, the rename prompt.

# the run prompt opens on super+r and carries a completion (mod+r).
key_fire "super+r"
check "super+r opens the run prompt with a completion wired" "true" \
	"$(eval_kiln 'local p = require("kiln").prompt.active
return tostring(p ~= nil and p.spec.completion ~= nil)')"
set_lua 'require("kiln").prompt.active:on_key { pressed = true, key = "Escape" }'
check "Escape closes the run prompt" "nil" \
	"$(eval_kiln 'return tostring(require("kiln").prompt.active)')"

# the lua-eval prompt runs code (super+x). "return parity_probe = 42" is a syntax
# error, so it falls back to loadstring(s), which sets the global.
key_fire "super+x"
set_lua 'local p = require("kiln").prompt.active
p.text = "parity_probe = 42"
p:on_key { pressed = true, key = "Return" }'
check "the lua-eval prompt executed the typed code" "42" \
	"$(eval_kiln 'return tostring(parity_probe)')"

# the rename prompt prefills the tag name and renames it (shift+super+r).
set_lua 'screen.all()[1].tags[1]:view()'
key_fire "shift+super+r"
check "the rename prompt prefills the current tag name" "dev" \
	"$(eval_kiln 'return require("kiln").prompt.active.text')"
set_lua 'local p = require("kiln").prompt.active
p.text = "renamed"
p:on_key { pressed = true, key = "Return" }'
check "the rename prompt renamed the tag" "renamed" \
	"$(eval_kiln 'return screen.all()[1].tags[1].name')"

# =====================================================================
# Do-not-disturb (shift+super+d): the ordering trick. Enabling notifies THEN
# suspends, so the confirmation shows; a later arrival queues; disabling
# unsuspends THEN notifies, flushing the queue and confirming.

key_fire "shift+super+d"
check "shift+super+d enables do-not-disturb" "true" \
	"$(eval_kiln 'return tostring(notification.suspended == true)')"
check "the enable confirmation showed (notified before suspending)" "true" \
	"$(eval_kiln 'for _, n in ipairs(notification.all()) do
  if n.message == "Do Not Disturb" then return "true" end
end
return "false"')"
set_lua 'require("kiln").notify { title = "queued", message = "while suspended" }'
check "an arrival while suspended queues in pending" "true" \
	"$(eval_kiln 'return tostring(#notification.pending >= 1)')"
key_fire "shift+super+d"
check "shift+super+d disables do-not-disturb" "false" \
	"$(eval_kiln 'return tostring(notification.suspended == true)')"
check "disabling flushed the pending queue" "0" \
	"$(eval_kiln 'return #notification.pending')"
check "the resume confirmation showed" "true" \
	"$(eval_kiln 'for _, n in ipairs(notification.all()) do
  if n.message == "Resumed" then return "true" end
end
return "false"')"

# =====================================================================
# The hotkeys sheet is the stdlib's, not the config's: the config supplies only
# the key{} entries the sheet reads and the binding that toggles it, so this
# section asserts library behavior. super+s toggles it; a press outside closes it.
# The scrim id is the stdlib's "hotkeys:scrim", the menu:scrim spelling.

check "the hotkeys sheet is nothing while closed" "absent" "$(live '"hotkeys"')"
key_fire "super+s"
check "super+s declares the stdlib sheet" "live" "$(live '"hotkeys"')"
check "a group header from the registry is declared" "live" \
	"$(live '"hkgroup:client"')"
check "the toggle's own chord is listed" "live" "$(live '"hkkey:super+s"')"
check "the numrow range reads back as one row" "live" "$(live '"hkkey:super+1-9"')"
fire 'on_press:hotkeys:scrim#0'
check "a press on the scrim closes the sheet" "absent" "$(live '"hotkeys"')"

# =====================================================================
# The menubar: super+p opens the launcher, a prompt plus a filtered result list,
# tolerant of an empty desktop-entry set headless (the list then declares its
# "no match" row, which is still a declared list).

key_fire "super+p"
check "super+p opens the launcher prompt" "true" \
	"$(eval_kiln 'return tostring(require("kiln.prompt").active ~= nil)')"
check "the launcher declares its result list" "live" "$(live '"launcher-list"')"
set_lua 'require("kiln.prompt").active:stop()'
check "stopping the prompt retires the list" "absent" "$(live '"launcher-list"')"

# =====================================================================
# The application menu, the theme submenu, and the switch_theme reload leg. The
# glyph opens the menu; navigating kiln -> theme -> gruvbox calls switch_theme,
# which writes the theme file and kiln.reload()s. After the reload the accent is
# gruvbox's, and the config is fully rebuilt (five tags, 65 keys). It picks
# gruvbox, not catppuccin: catppuccin is the default palette, so picking it would
# switch nothing and the accent check could not fail.

cat_accent=$(eval_kiln 'return require("kiln").theme.accent')
fire 'on_press:launcher#0'
check "the launcher glyph opens the application menu" "true" \
	"$(eval_kiln 'return tostring(require("kiln.menu").open ~= nil)')"
fire 'on_press:menu:/1#0'
check "the kiln submenu opened (theme row live)" "live" "$(live '"menu:/1/3"')"
fire 'on_press:menu:/1/3#0'
check "the theme submenu opened (a palette row live)" "live" "$(live '"menu:/1/3/1"')"
fire 'on_press:menu:/1/3/1#0'
sleep 1
check "picking gruvbox switched the accent (switch_theme + reload)" "true" \
	"$(eval_kiln "return tostring(require('kiln').theme.accent ~= '$cat_accent')")"
check "the reload rebuilt the five tags" "5" \
	"$(eval_kiln 'return #screen.all()[1].tags')"
check "the reload rebuilt the 65-key registry" "65" \
	"$(eval_kiln 'return #require("kiln").key.all()')"

# =====================================================================
# The clean gate: nothing errored through the dispatcher across the whole run,
# including the reload. Asserted BEFORE the deliberate error-path test below.

check "no bus error fired through the whole run (in-process count)" "0" \
	"$(eval_kiln 'return tostring(PARITY_BUS_ERRORS)')"

# =====================================================================
# Focus policy and the error handler. Sloppy focus is mouse::enter -> focus; the
# error handler raises a critical notification.

set_lua 'local cs = client.all()
for _, c in ipairs(cs) do if c ~= client.focus and c.mapped then c:emit("mouse::enter"); break end end'
check "mouse::enter moves focus (sloppy focus)" "true" \
	"$(eval_kiln 'return tostring(client.focus ~= nil)')"

# a deliberately failing binding surfaces as a critical notification. Restated the
# way on_key dispatches: pcall the handler, and on failure route through
# Bus.on_error, the same door the real key path uses (a bare press() would let the
# error escape to the eval's own pcall instead of the config's error handler).
set_lua 'require("kiln").key { mods = { "mod" }, key = "F14", desc = "boom",
  group = "probe", press = function() error("boom") end }'
set_lua 'local b = require("kiln.state").keys["super+F14"]
local ok, err = pcall(b.press)
if not ok then require("kiln.bus").on_error("key super+F14", err) end'
check "a failing handler raised a critical notification" "true" \
	"$(eval_kiln 'for _, n in ipairs(notification.all()) do
  if n.urgency == "critical" then return "true" end
end
return "false"')"
check "and the error was counted in-process" "true" \
	"$(eval_kiln 'return tostring(PARITY_BUS_ERRORS >= 1)')"

# =====================================================================
# Scene integrity: no tree/scene divergence and no duplicate id from any of the
# floats the desktop stacks (the in-process count above is the bus-error gate).
#
# NO bus-error pattern here, deliberately, and it must stay that way: the
# error-path section above FIRES a real bus error on purpose, so a log grep for
# one would be 1 on every green run. This battery gates bus errors through the
# PARITY_BUS_ERRORS counter, which can be read at a chosen point rather than
# accumulating over the whole log. rc-test.sh, which raises no error of its own,
# is where the log pattern belongs.

noise=$(grep -cE 'tree==scene:|DUPLICATE|clay error' "$log" || true)
check "no tree/scene divergence, no duplicate ids, no clay error" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
