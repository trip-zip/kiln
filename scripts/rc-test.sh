#!/bin/sh
# The stdlib-surface battery. It boots the REAL default config headless (not a
# synthetic one, the way the other batteries do) and proves the pieces of the
# public API no other battery owns:
#
#   scripts/rc-test.sh
#
# The static half proves it by grep: the config reaches for no compositor
# primitive (grep -c 'core\.' is 0), requires only the one public module, and every
# widget it declares runs on cfg keys that already exist (a new ui cfg key would be
# a library defect, not a config one). The live half boots it and reads the
# declared scene back over IPC: the bar and its chrome, the stdlib menu opening from
# the launcher, the tasklist tracking real clients, the layout cycle, prompt
# tab-completion, no_overlap placement, and the client-list menu.
#
# WHAT THIS BATTERY NO LONGER IS. It used to boot a second, minimal rc.lua kept
# beside the real config. That file is deleted: kilnrc.lua is the only config,
# installed as rc.lua, and parity-test.sh is what reads its desktop back leg by leg.
# The hotkeys sheet, sticky and tag history moved OUT of here rather than being
# restated against the new ids, because parity-test.sh already asserts all three
# against this same file. The remaining overlap between the two is not yet
# untangled.
#
# XDG_CONFIG_HOME IS ISOLATED: the config picks its palette from a theme file under
# it, so without that this battery reads whatever theme the person running it has
# selected.
#
# PRESSES ARE RESTATED, NOT DRIVEN. Headless has no input device
# (WLR_LIBINPUT_NO_DEVICES=1), so a press is dispatched the way init.lua's
# on_button does: look the handler up in the press table the declare just built and
# call it. The launcher, the layoutbox cycle and the tasklist row are driven that
# way. A green run proves ROUTING and DECLARATION; it does not claim a pointer or a
# key was physically actuated.
#
# EXISTENCE IS ASSERTED THROUGH core.hits, NEVER core.box. Clay's element hashmap
# is persistent, so core.box keeps answering with the last box an
# id ever had long after it stops being declared; core.hits names only what the
# last solve actually put under a point. So an opened/closed popup is tested live,
# not by box presence.
#
# MANUAL, not claimed passed: the pointer and keyboard edges. Hovering
# the clock for its tooltip, clicking the launcher and picking a layout, and the
# tasklist row under the cursor being the one the pointer is over. The routing for
# all of it is covered below; eyes are for whether it looks right.
#
# Needs: foot.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
rc="$repo/kilnrc.lua"
work="$(mktemp -d /tmp/kiln-rc-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
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
# The static half: the three greps that prove the public-API-only claim. Run
# before the boot, because a config that fails them proves nothing live.

check "the config reaches for no compositor primitive" "0" \
	"$(grep -c 'core\.' "$rc")"
check "the config requires exactly one module" "1" \
	"$(grep -c 'require(' "$rc")"
check "and that module is kiln" "kiln" \
	"$(sed -n 's/.*require("\([^"]*\)").*/\1/p' "$rc" | head -1)"
check "no emdashes (house style)" "0" \
	"$(grep -cP '\x{2014}' "$rc" || true)"

# =====================================================================
# Boot the real config on the headless backend and let its screen.on("added")
# build the tags and the bar.

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 XDG_CONFIG_HOME="$work/config" \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

check "the compositor booted" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"

wl_disp=$(sed -n 's/.*Running Wayland compositor on WAYLAND_DISPLAY=//p' "$log" | head -1)
for i in 1 2; do
	WAYLAND_DISPLAY="$wl_disp" foot >"$work/foot$i.log" 2>&1 &
done
sleep 4

set_lua() {
	eval_kiln "$1
core.dirty()" >/dev/null
	sleep 0.6
}

# live: is this id declared RIGHT NOW? core.hits names what the last solve put
# under a point, so an id that stopped being declared stops being named. The id is
# passed as a Lua expression so both string ids ("hotkeys") and table ids
# ({ "hkkey", "super+s" }) work.
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

sname=$(eval_kiln 'return screen.all()[1].name')

# =====================================================================
# The bar and its static chrome.

# Probe the bar's own paint at its top edge: no widget reaches y=2, the
# leaves are align-center.
check "the bar is declared" "true" \
	"$(eval_kiln 'local s = screen.all()[1]
for _, h in ipairs(core.hits(s.name, 2, 2)) do
  if h.name == "bar" then return "true" end
end
return "false"')"
check "the layoutbox is declared for this screen" "live" \
	"$(live "\"layoutbox:$sname\"")"
check "the launcher is declared" "live" "$(live '"launcher"')"
check "the clock is declared" "live" "$(live '"clock"')"

# The clock carries the tooltip handler (the whole of ui.tooltip: an on_hover on
# the element it labels). Restated, the discipline tooltip-test.sh uses.
check "the clock registers a tooltip on_hover handler" "true" \
	"$(eval_kiln "local st = require('kiln.state')
local p = st.screen_presses['$sname'] or {}
return tostring(p['on_hover:clock#0'] ~= nil)")"

# =====================================================================
# The layoutbox press is the same write mod+period does: it cycles t.layout. The
# handler is restated out of the press table the declare built.
before=$(eval_kiln 'return require("kiln").layout.name(screen.all()[1].selected_tag.layout)')
set_lua "local st = require('kiln.state')
local p = st.screen_presses['$sname'] or {}
local h = p['on_press:layoutbox:$sname#0']
if h ~= nil then h() end"
after=$(eval_kiln 'return require("kiln").layout.name(screen.all()[1].selected_tag.layout)')
check "the layoutbox press cycled the layout" "true" \
	"$([ "$before" != "$after" ] && echo true || echo false)"
# next() of the whole cycle is where it landed: proves the box cycles the list,
# not some private order.
check "and it landed on layout.next of what it was" "$after" \
	"$(eval_kiln "return require('kiln').layout.name(
  require('kiln').layout.next(
    (function() for _, f in ipairs(require('kiln').layout.list) do
      if require('kiln').layout.name(f) == '$before' then return f end
    end end)()))")"

# =====================================================================
# The tasklist tracks the two real foot clients (widgets.tasklist keys rows by
# handle).

check "two clients mapped" "2" \
	"$(eval_kiln 'local s, seen, n = screen.all()[1], {}, 0
for _, t in ipairs(s.tags) do
  for _, c in ipairs(t.clients) do
    if not seen[c] and c.mapped then seen[c] = true; n = n + 1 end
  end
end
return n')"
th1=$(eval_kiln 'return screen.all()[1].selected_tag.clients[1].handle')
th2=$(eval_kiln 'return screen.all()[1].selected_tag.clients[2].handle')

# A tasklist row has no point of its own this script could hit: where a row
# lands depends on the widths of everything packed before it. The press table
# is the sound probe instead, and it is not the stale-box trap core.hits
# exists to avoid: init.lua resets state.presses at the top of each declare
# and stashes it at the end, so a key for this row means this row was declared
# in the LAST declare.
row_live() { # handle
	eval_kiln "local p = require('kiln.state').screen_presses['$sname'] or {}
for k in pairs(p) do
  if k:find('^on_press:task:$1#') then return 'live' end
end
return 'absent'"
}

check "the tasklist declared a row for the first client" "live" \
	"$(row_live "$th1")"
check "the tasklist declared a row for the second client" "live" \
	"$(row_live "$th2")"

# The row press focuses its client, restated out of the press table.
set_lua "local st = require('kiln.state')
local p = st.screen_presses['$sname'] or {}
local h = p['on_press:task:$th1#0']
if h ~= nil then h() end"
check "pressing a tasklist row focuses its client" "$th1" \
	"$(eval_kiln 'return client.focus and client.focus.handle or "-"')"

# =====================================================================
# The stdlib menu (ui.menu). Closed is not declared; pressing the launcher opens
# it under the launcher.

check "the menu is not declared while closed" "absent" "$(live '"menu:box"')"
set_lua "local st = require('kiln.state')
local p = st.screen_presses['$sname'] or {}
local h = p['on_press:launcher#0']
if h ~= nil then h() end"
check "pressing the launcher opened the stdlib menu" "live" \
	"$(live '"menu:box"')"
check "the menu is the runtime's one open menu, on this screen" "true" \
	"$(eval_kiln 'local m = require("kiln.menu").open
return tostring(m ~= nil and m.screen == screen.all()[1])')"
# It carries the items the config gave it.
check "the menu's first row is the config's first item" "live" \
	"$(live '"menu:/1"')"
set_lua "require('kiln.menu').close()"
check "closing takes the menu down" "absent" "$(live '"menu:box"')"

# =====================================================================
# prompt completion: kiln.prompt.completion tab-cycles a candidates fn.
# The prompt runs headless and Tab is RESTATED as an on_key, the press
# convention this battery uses. P is a global so it survives across eval calls.
set_lua 'local S = require("kiln")
P = S.prompt.run { text = "foo",
  completion = S.prompt.completion(function() return { "foobar", "foobaz" } end) }
P:on_key { pressed = true, key = "Tab" }'
check "completion cycles to the first candidate" "foobar" \
	"$(eval_kiln 'return P.text')"
set_lua 'P:on_key { pressed = true, key = "Tab" }'
check "completion cycles to the second candidate" "foobaz" \
	"$(eval_kiln 'return P.text')"
set_lua 'P:on_key { pressed = true, key = "Tab" }'
check "completion wraps back to the first candidate" "foobar" \
	"$(eval_kiln 'return P.text')"
set_lua 'P:on_key { pressed = true, key = "BackSpace" }
P:on_key { pressed = true, key = "Tab" }'
check "an edit resets the cycle, Tab recompletes the prefix" "foobar" \
	"$(eval_kiln 'return P.text')"
set_lua 'P:on_key { pressed = true, key = "Escape" }'
check "Escape closed the prompt" "nil" \
	"$(eval_kiln 'return tostring(require("kiln").prompt.active)')"

# =====================================================================
# placement.no_overlap: a float placed to miss the declared floats. The
# two clients are given explicit float boxes so the geometry is deterministic
# regardless of the headless resolution: no_overlap picks the first client's
# right edge, the first free candidate. wa.x is 0 (the bar is on top), so the
# first float sits at x 0 and the second lands at its width.
set_lua 'local S = require("kiln")
local cs = screen.all()[1].tags[1].clients
cs[1].floating = true
cs[2].floating = true
cs[1].float = { x = 0, y = 0, width = 200, height = 150 }
cs[2].float = { x = 0, y = 0, width = 200, height = 150 }
S.placement.top_left(cs[1])
S.placement.no_overlap(cs[2])'
check "no_overlap offsets the second float to the first's right edge" "true" \
	"$(eval_kiln 'local cs = screen.all()[1].tags[1].clients
return tostring(cs[2].float.x == cs[1].float.width and cs[2].float.y == cs[1].float.y)')"

# =====================================================================
# client-list menu: kiln.menu.client_list builds one row per client and
# opens through the same menu.show the stdlib menu uses.
set_lua 'require("kiln").menu.client_list {}'
check "client_list opened one menu level" "1" \
	"$(eval_kiln 'return #require("kiln.menu").open.levels')"
check "with one row per live client" "true" \
	"$(eval_kiln 'return tostring(#require("kiln.menu").open.levels[1].items == #client.all())')"
set_lua 'require("kiln.menu").close()'
check "closing takes the client-list menu down" "true" \
	"$(eval_kiln 'return tostring(require("kiln.menu").open == nil)')"

# =====================================================================
# The compositor stayed clean: no Lua error on the bus, no tree/scene divergence,
# no duplicate id from any of the floats the desktop stacks.
#
# The bus pattern is "error in '", not "bus error in": bus.lua's DEFAULT
# on_error prints "bus error in '...'", but init.lua overrides it to print
# "kiln: error in '...'", and the override is what is installed under the real
# library. Matching on the shared substring catches either sink. Paired with the
# line-buffering fix in init.lua, this leg can now actually fail; matching the
# default's string alone, against a block-buffered log, is why it never could.
noise=$(grep -cE "error in '|tree==scene:|DUPLICATE" "$log" || true)
check "no bus errors, no tree/scene divergence, no duplicate ids" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
