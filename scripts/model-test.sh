#!/bin/sh
# The model battery: the client model remainder (raise/lower/swap/ontop/
# minimized/multi-tag as list ops), tag params and multi-select, the input
# config surface, and the rule{} combinators.
#
#   scripts/model-test.sh
#
# Pure headless: every verb here is a property write or a list move, and the
# consequence of each is a declaration. Nothing needs a real input device, so the
# harness stays on the headless backend (no Xvfb, no xdotool).
#
# STACKING IS ASSERTED THROUGH THE SCENE, NOT THE LIST. Reading t.clients back
# after c:raise() would only prove table.insert works. The claim under test is
# that the LIST IS THE STACK, so it is tested where stacking is observable:
# core.hits. Clay sorts its float roots ascending by zIndex and
# Clay_SetPointerState walks them top-down, breaking at the first root that
# captures the pointer, and our floats capture by default. So at a point covered
# by two overlapping floats, core.hits names the chain of the TOP one and nothing
# below it. Which client is named at the overlap IS the stacking order, read out
# of the solve. A raise that does not reach the declaration cannot fake this.
#
# The same reasoning makes core.hits the existence test for minimized: an
# undeclared client stops being named. core.box is NOT an existence test: Clay's
# element hashmap is persistent and keeps answering with the last box an id ever
# had, so a dropped id still reads back a live-looking box. Box is therefore
# only used below for geometry already known to be declared.
#
# Geometry expectations are restated from the workarea and the tag params, never
# hardcoded and never by calling the layout, so a layout that agrees with itself
# but not with the screen cannot pass.
#
# MANUAL, not claimed passed: the real keyboard edge. Headless has no keyboard
# and no input devices (WLR_LIBINPUT_NO_DEVICES=1), so a `release` handler
# firing from an actual key-up, and kiln.input's libinput writes actually
# reaching a device, are TTY legs. What is proven below is the ROUTING (on_key's
# dispatch, restated) and the PROPERTY SURFACE (last-written-value readback). A
# green run here does not claim a key was pressed.
#
# Needs: foot.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-model-test.XXXXXX)"
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

# The rc under test: four tags, tile with one master, and the rule set whose
# behavior the rule legs assert. Public API only: no core.* reach-through, so a
# config that cannot express this could not be written against it either.
cat >"$rc" <<'EOF'
local kiln = require("kiln")

-- Rules are registered at boot; the clients they match are spawned later over
-- IPC, so each rule leg maps a client with the rule already in place.

-- focus = false plus a plain prop. The client must float AND must not steal
-- focus from whatever held it.
kiln.rule {
	match = { app = "^ruleflt$" },
	props = { floating = true, focus = false },
}

-- The pattern leg. "^rulep" matches "rulepat" as a LUA PATTERN (a prefix
-- anchor) and does NOT match it as a plain substring: there is no literal "^"
-- in "rulepat". So a matcher still using find(pat, 1, true) fails this and a
-- matcher using :match() passes it. That asymmetry is the whole point.
kiln.rule {
	match = { app = "^rulep" },
	props = { ontop = true },
}

-- except vetoes a hit. The app matches; the title veto must win, so the client
-- is NOT minimized.
kiln.rule {
	match_any = { app = { "^rulev" } },
	except = { title = "veto" },
	props = { minimized = true },
}

-- The general escape: a predicate over the same public object.
kiln.rule {
	match = { fn = function(c) return c.app_id == "rulefn" end },
	props = { maximized = true },
}

screen.on("added", function(s)
	for _, name in ipairs({ "one", "two", "three", "four" }) do
		tag.new { name = name, screen = s, layout = kiln.layout.tile }
	end
	s.tags[1]:view()
end)
EOF

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init.
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

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

# --- the readbacks.

# at: which client the solve put on top at this point, read out of the scene.
# Walks core.hits and returns the handle of the first element named "client"
# (widgets.client declares id = { "client", c.handle }). Because Clay
# breaks at the topmost capturing float root, at an overlap this names the TOP
# float and nothing under it: presence here IS "is on top".
at() { # x y
	eval_kiln "
local s = screen.all()[1]
for _, h in ipairs(core.hits(s.name, $1, $2)) do
  if h.name == 'client' then return h.index end
end
return '-'"
}

# live: is this client declared right now? Its own box center, probed through
# hits, so an undeclared client (minimized) stops being named however stale its
# box is.
live() { # handle
	eval_kiln "
local s = screen.all()[1]
local b = core.box({ 'client', $1 })
if b == nil then return 'absent' end
for _, h in ipairs(core.hits(s.name, b.x + b.width / 2, b.y + b.height / 2)) do
  if h.name == 'client' and h.index == $1 then return 'live' end
end
return 'absent'"
}

cbox() { # handle
	eval_kiln "
local b = core.box({ 'client', $1 })
return b == nil and '-' or
  string.format('%d,%d %dx%d', b.x, b.y, b.width, b.height)"
}

# The handles of the selected tag's clients, in list order. The list is the
# stack, so this is the declaration order, and the legs below assert the scene
# agrees with it.
handles() {
	eval_kiln '
local o = {}
for _, c in ipairs(screen.all()[1].selected_tag.clients) do
  o[#o+1] = tostring(c.handle)
end
return table.concat(o, " ")'
}

# Every client declared on the screen right now, deduped by handle, sorted. The
# multi-select legs use this: a client on two selected tags must appear ONCE.
declared() {
	eval_kiln '
local s = screen.all()[1]
local seen, o = {}, {}
for _, t in ipairs(s.tags) do
  for _, c in ipairs(t.clients) do
    if not seen[c.handle] then
      local b = core.box({ "client", c.handle })
      if b ~= nil then
        for _, h in ipairs(core.hits(s.name, b.x + b.width / 2,
            b.y + b.height / 2)) do
          if h.name == "client" and h.index == c.handle then
            seen[c.handle] = true
            o[#o+1] = c.handle
            break
          end
        end
      end
    end
  end
end
table.sort(o)
local out = {}
for i, h in ipairs(o) do out[i] = tostring(h) end
return table.concat(out, " ")'
}

check "three clients mapped on tag one" "3" \
	"$(eval_kiln 'return #screen.all()[1].selected_tag.clients')"

h1=$(eval_kiln 'return screen.all()[1].selected_tag.clients[1].handle')
h2=$(eval_kiln 'return screen.all()[1].selected_tag.clients[2].handle')
h3=$(eval_kiln 'return screen.all()[1].selected_tag.clients[3].handle')

# =====================================================================
# swap: a list op, observed as an exchange of solved cells.

m_before=$(cbox "$h1")
s_before=$(cbox "$h2")
check "swap: the two cells differ to begin with" "differ" \
	"$([ "$m_before" != "$s_before" ] && echo differ || echo same)"

set_lua "local cs = screen.all()[1].selected_tag.clients
cs[1]:swap(cs[2])"
check "swap: the list order exchanged" "$h2 $h1 $h3" "$(handles)"
check "swap: and the solved cells exchanged with it" \
	"$s_before $m_before" "$(cbox "$h1") $(cbox "$h2")"

# Put it back, so the rest of the legs start from map order.
set_lua "local cs = screen.all()[1].selected_tag.clients
cs[1]:swap(cs[2])"
check "swap: swapping back restores map order" "$h1 $h2 $h3" "$(handles)"

# =====================================================================
# focus raises floats, but NEVER reorders the tiled flow. A naive
# raise-on-every-focus would move the master cell out from under the user; this
# is the leg that catches it.

set_lua "require('kiln.object').lookup($h3):focus()"
check "focus: a tiled client is not reordered by focus" "$h1 $h2 $h3" \
	"$(handles)"
check "focus: so the master cell did not jump" "$m_before" "$(cbox "$h1")"

# =====================================================================
# raise: two overlapping floats. Which one core.hits names at the overlap is
# which one the solve put on top.

set_lua "local o = require('kiln.object')
local a, b = o.lookup($h1), o.lookup($h2)
a.floating = true
b.floating = true
a.float = { x = 100, y = 100, width = 300, height = 300 }
b.float = { x = 200, y = 200, width = 300, height = 300 }"

# The overlap is 200,200 .. 400,400; 300,300 is inside both.
check "raise: the later float in the list is on top to begin with" "$h2" \
	"$(at 300 300)"
set_lua "require('kiln.object').lookup($h1):raise()"
check "raise: raising moves it to the tail of the list" "$h2 $h3 $h1" \
	"$(handles)"
check "raise: and the scene now puts it on top at the overlap" "$h1" \
	"$(at 300 300)"

set_lua "require('kiln.object').lookup($h1):lower()"
check "lower: back to the head of the list, and back under" "$h2" \
	"$(at 300 300)"

# Focus is the one-line policy over the same list move: focusing an
# out-of-flow client raises it, with no second stacking authority.
set_lua "require('kiln.object').lookup($h1):focus()"
check "focus: focusing a float raises it, through the list" "$h1" \
	"$(at 300 300)"

# =====================================================================
# ontop: a BAND, which outranks the list. The ontop float stays on top even
# after the other one is focused and raised to the list tail.

set_lua "require('kiln.object').lookup($h2).ontop = true
require('kiln.object').lookup($h1):focus()"
check "ontop: the list put h1 last" "$h1" \
	"$(eval_kiln "local cs = screen.all()[1].selected_tag.clients
return cs[#cs].handle")"
check "ontop: but the band outranks the list, so h2 is still on top" "$h2" \
	"$(at 300 300)"

set_lua "require('kiln.object').lookup($h2).ontop = false"
check "ontop: clearing it returns h1 (the list tail) to the top" "$h1" \
	"$(at 300 300)"

# Back to tiled for the remaining legs.
set_lua "local o = require('kiln.object')
o.lookup($h1).floating = false
o.lookup($h2).floating = false"

# =====================================================================
# minimized: a plain property write is the whole verb. Not hidden, not
# zero-sized: not declared.

set_lua "require('kiln.object').lookup($h2):focus()"
set_lua "require('kiln.object').lookup($h2).minimized = true"
check "minimized: a property write, and the leaf is gone from the scene" \
	"absent" "$(live "$h2")"
check "minimized: focus did not stay on a window nothing draws" "false" \
	"$(eval_kiln "return tostring(client.focus ~= nil and
  client.focus.handle == $h2)")"
check "minimized: the survivors re-solved to fill the tag" "2" \
	"$(declared | wc -w | tr -d ' ')"

set_lua "require('kiln.object').lookup($h2).minimized = false"
check "minimized: clearing it declares the client again" "live" "$(live "$h2")"
check "minimized: and the tag is back to three cells" "3" \
	"$(declared | wc -w | tr -d ' ')"

# =====================================================================
# multi-tag membership: c.tags is the list, c.tag is sugar for tags[1].

set_lua "local t = screen.all()[1].tags
require('kiln.object').lookup($h3).tags = { t[1], t[3] }"
check "tags: the client is on both tags' client lists" "true true" \
	"$(eval_kiln "local o = require('kiln.object')
local c = o.lookup($h3)
local t = screen.all()[1].tags
local function has(l, v)
  for _, x in ipairs(l) do if x == v then return true end end
  return false
end
return tostring(has(t[1].clients, c)) .. ' ' .. tostring(has(t[3].clients, c))")"
check "tags: c.tag is sugar for tags[1]" "one" \
	"$(eval_kiln "return require('kiln.object').lookup($h3).tag.name")"
check "tags: c.screen is derived from the tag" "true" \
	"$(eval_kiln "local c = require('kiln.object').lookup($h3)
return tostring(c.screen == screen.all()[1])")"

# Viewing the OTHER tag it is on declares it there too. That is the whole of
# multi-tag: one client, two homes.
set_lua "screen.all()[1].tags[3]:view()"
check "tags: viewing tag three declares the same client" "live" \
	"$(live "$h3")"
check "tags: and it is the only client on tag three" "1" \
	"$(declared | wc -w | tr -d ' ')"
set_lua "screen.all()[1].tags[1]:view()"

# =====================================================================
# multi-select: two tags viewed at once. The declared set is the DEDUPED union.
# h3 is on tags one and three, so with both selected it must appear ONCE. A
# declare that walked each tag's list without deduping would declare it twice
# under the same Clay id, and the stack column would carry a phantom cell.

set_lua "screen.all()[1].tags[3]:toggle()"
check "multi-select: both tags are selected" "one three" \
	"$(eval_kiln 'local o = {}
for _, t in ipairs(screen.all()[1].selected_tags) do o[#o+1] = t.name end
return table.concat(o, " ")')"
check "multi-select: selected_tag is sugar for selected_tags[1]" "one" \
	"$(eval_kiln 'return screen.all()[1].selected_tag.name')"
check "multi-select: t.selected is true for both" "true true" \
	"$(eval_kiln 'local t = screen.all()[1].tags
return tostring(t[1].selected) .. " " .. tostring(t[3].selected)')"
check "multi-select: the union is deduped, h3 appears once" "3" \
	"$(declared | wc -w | tr -d ' ')"

# The geometric half of the dedupe claim: with three unique clients and one
# master, the stack column holds exactly TWO cells. A double-declared h3 would
# make it three, and every stack cell would be shorter. Restated from the
# workarea and the tag params, never from the layout.
#
# The stack client is read out of the union rather than named: the raise, lower,
# swap and focus legs above have all reordered this list on purpose, and the
# list IS the layout order, so which handle sits in a stack cell is not a
# constant this test gets to assume.
check "multi-select: the stack cell height says three cells, not four" \
	"$(eval_kiln 'local wa = screen.all()[1].workarea
local t = screen.all()[1].selected_tag
local g = t.gap or require("kiln.state").theme.gap
local H = wa.height - 2 * g
-- two stack cells sharing the inner height with one gap between them
return tostring(math.floor((H - g) / 2 + 0.5))')" \
	"$(eval_kiln 'local s = screen.all()[1]
local seen, union = {}, {}
for _, t in ipairs(s.selected_tags) do
  for _, c in ipairs(t.clients) do
    if not seen[c] then seen[c] = true; union[#union+1] = c end
  end
end
-- master_count defaults to 1, so union[2] is the first STACK cell
local c = union[2]
if c == nil then return "no-stack-client" end
local b = core.box({ "client", c.handle })
return b == nil and "-" or tostring(b.height)')"

set_lua "screen.all()[1].tags[3]:toggle()"
check "multi-select: toggling off leaves one selected" "one" \
	"$(eval_kiln 'return screen.all()[1].selected_tag.name')"
check "multi-select: toggling the last tag off is refused, never empty" "one" \
	"$(eval_kiln 'local t = screen.all()[1].tags
t[1]:toggle()
return screen.all()[1].selected_tag.name')"

# =====================================================================
# t:delete(): the clients rehome to a survivor, nothing is orphaned.

set_lua "local t = screen.all()[1].tags
require('kiln.object').lookup($h3).tags = { t[3] }"
set_lua "screen.all()[1].tags[3]:delete()"
check "delete: the tag is gone from the screen" "one two four" \
	"$(eval_kiln 'local o = {}
for _, t in ipairs(screen.all()[1].tags) do o[#o+1] = t.name end
return table.concat(o, " ")')"
check "delete: its client rehomed to a survivor, not orphaned" "one" \
	"$(eval_kiln "return require('kiln.object').lookup($h3).tag.name")"
check "delete: and it is declared again" "live" "$(live "$h3")"

# =====================================================================
# rule{}: the combinators, the patterns, and the specials.
#
# Each rule client is spawned AFTER boot (the rules are already registered in
# the rc), and every readback looks the client up by app_id inside Lua rather
# than interpolating a handle from the shell, so a client that never mapped
# fails a leg cleanly instead of producing a Lua syntax error.

# prop: read one property off the client with this app_id, as a string.
prop() { # app_id property
	eval_kiln "
for _, c in ipairs(client.all()) do
  if c.app_id == '$1' then return tostring(c.$2) end
end
return 'no-client'"
}

spawn_rule() { # app-id [one extra foot arg]
	set_lua "require('kiln').spawn({ 'foot', '--app-id=$1'${2:+, '$2'} })"
	sleep 3
	eval_kiln 'core.dirty()' >/dev/null
	sleep 0.6
}

focus_before=$(eval_kiln 'return client.focus and client.focus.handle or "-"')
spawn_rule ruleflt
check "rule: a props write applied on map" "true" "$(prop ruleflt floating)"
check "rule: focus = false suppressed focus-on-open" "$focus_before" \
	"$(eval_kiln 'return client.focus and client.focus.handle or "-"')"

# "^rulep" matches "rulepat" as a LUA PATTERN (a prefix anchor) and does NOT
# match it as a plain substring: there is no literal "^" in "rulepat". A matcher
# still using find(pat, 1, true) fails this leg; one using :match() passes it.
spawn_rule rulepat
check "rule: matching is by Lua pattern, not substring" "true" \
	"$(prop rulepat ontop)"

# The app matches "^rulev", but the title veto must win.
spawn_rule rulever --title=veto
check "rule: except vetoed a matching rule" "nil" \
	"$(prop rulever minimized)"

spawn_rule rulefn
check "rule: an fn matcher is a predicate over the public object" "true" \
	"$(prop rulefn maximized)"

# =====================================================================
# The key registry: what a hotkeys cheat sheet reads. A RANGE IS ONE ENTRY.
# Nine rows reading "1" through "9" is not a cheat sheet; one row reading
# "1-9  view tag" is. So the registry is per key{} call, while the bound chord
# set C consumes is per expanded key.

set_lua 'local kiln = require("kiln")
kiln.key.clear()
kiln.key { mods = { "mod" }, key = "Return", desc = "open terminal",
  group = "launcher", press = function() end }
kiln.key { mods = { "mod" }, key = "1-9", desc = "view tag", group = "tag",
  press = function(i) VIEWED = i end }
kiln.key { mods = { "mod" }, key = "q", desc = "close", group = "client",
  press = function() end, release = function() RELEASED = true end }'

check "registry: one entry per key{} call, ranges NOT expanded" "3" \
	"$(eval_kiln 'return #require("kiln").key.all()')"
check "registry: in declaration order, with desc and group intact" \
	"Return/open terminal/launcher 1-9/view tag/tag q/close/client" \
	"$(eval_kiln 'local o = {}
for _, k in ipairs(require("kiln").key.all()) do
  o[#o+1] = k.key .. "/" .. k.desc .. "/" .. k.group
end
return table.concat(o, " ")')"
check "registry: but the range DID expand into nine bound chords" "11" \
	"$(eval_kiln 'local n = 0
for _ in pairs(require("kiln.state").keys) do n = n + 1 end
return n')"
check "registry: clear() empties both the registry and the chord set" "0 0" \
	"$(eval_kiln 'local kiln = require("kiln")
local st = require("kiln.state")
kiln.key.clear()
local n = 0
for _ in pairs(st.keys) do n = n + 1 end
return #kiln.key.all() .. " " .. n')"

# Ranges: the digit handler receives a number, the letter handler a letter.
check "ranges: a digit range presses with the index as a number" "number 5" \
	"$(eval_kiln 'local kiln = require("kiln")
kiln.key.clear()
kiln.key { mods = { "mod" }, key = "1-9", press = function(i) GOT = i end }
require("kiln.state").keys["alt+5"].press()
return type(GOT) .. " " .. tostring(GOT)')"
check "ranges: a letter range presses with the letter" "string c" \
	"$(eval_kiln 'local kiln = require("kiln")
kiln.key.clear()
kiln.key { mods = { "mod" }, key = "a-e", press = function(l) GOT = l end }
require("kiln.state").keys["alt+c"].press()
return type(GOT) .. " " .. tostring(GOT)')"

# Release: on_key's dispatch, restated. The router looks the chord up and fires
# .press or .release by ev.pressed; this is that lookup against the same table
# bind() built. A release-only chord must still be in C's consume set, or the
# key would leak to the focused client.
check "release: a release-only chord is still synced to C's consume set" "1" \
	"$(eval_kiln 'local kiln = require("kiln")
kiln.key.clear()
kiln.key { mods = { "mod" }, key = "F5", release = function() FIRED5 = true end }
local n = 0
for _ in pairs(require("kiln.state").keys) do n = n + 1 end
return n')"
check "release: the release edge dispatches the release handler" "true none" \
	"$(eval_kiln 'FIRED5 = "none"; PRESSED5 = "none"
local b = require("kiln.state").keys["alt+F5"]
-- restate on_key: press edge fires .press, release edge fires .release
if b.press ~= nil then PRESSED5 = "press-ran" end
if b.release ~= nil then b.release() end
return tostring(FIRED5) .. " " .. tostring(PRESSED5)')"

# =====================================================================
# kiln.input: plain properties, FORWARDED to the C verbs that already exist.
# Reading returns the last written value.
#
# A readback alone would prove nothing: a raw `kiln.input = core.input` alias
# also stores and returns a field you assign to it. So each
# leg SPIES on the C verb, swapping core.input.set_* for a recorder, and asserts
# the property write actually reached it with the right arguments. That is the
# claim; the last-written-value readback is the easy half.
#
# Headless has no input devices (WLR_LIBINPUT_NO_DEVICES=1), so what the verb
# then does to a real device is the TTY leg, not this one.

# Each write sends ONLY the field that changed: core.input.set_pointer takes a
# table of optional fields and a nil one is untouched (the has_ flags in
# core_pointer_config). So the spy accumulates rather than overwrites, which is
# also an assertion that one property write does not silently restate the others.
check "input: writing a property forwards to the C verb" "flat true 1" \
	"$(eval_kiln 'local kiln = require("kiln")
local got = { keys = 0 }
local real = core.input.set_pointer
core.input.set_pointer = function(cfg)
  local n = 0
  for _ in pairs(cfg) do n = n + 1 end
  got.keys = math.max(got.keys, n)
  if cfg.accel_profile ~= nil then got.profile = cfg.accel_profile end
  if cfg.natural_scrolling ~= nil then got.natural = cfg.natural_scrolling end
end
kiln.input.accel_profile = "flat"
kiln.input.natural_scrolling = true
core.input.set_pointer = real
return tostring(got.profile) .. " " .. tostring(got.natural) .. " " ..
  tostring(got.keys)')"
check "input: and the property reads back the last written value" "flat true" \
	"$(eval_kiln 'local kiln = require("kiln")
return tostring(kiln.input.accel_profile) .. " " ..
  tostring(kiln.input.natural_scrolling)')"

# set_repeat(rate, delay) is a TWO-ARG C call, so writing ONE half must still
# pass both (luaL_checknumber on a nil delay would error). The store has to
# remember the other half, seeded from kiln's own compiled-in defaults (25/600).
check "input: repeat_delay defaults are seeded, not nil" "25 600" \
	"$(eval_kiln 'local kiln = require("kiln")
return tostring(kiln.input.repeat_rate) .. " " ..
  tostring(kiln.input.repeat_delay)')"
check "input: writing repeat_rate alone still passes both args to set_repeat" \
	"30 600" \
	"$(eval_kiln 'local kiln = require("kiln")
local got = "not-called"
local real = core.input.set_repeat
core.input.set_repeat = function(rate, delay)
  got = tostring(rate) .. " " .. tostring(delay)
end
kiln.input.repeat_rate = 30
core.input.set_repeat = real
return got')"

check "input: the keymap is one table property, forwarded whole" "dvorak" \
	"$(eval_kiln 'local kiln = require("kiln")
local got = "not-called"
local real = core.input.set_keymap
core.input.set_keymap = function(km) got = tostring(km.layout) end
kiln.input.keymap = { layout = "dvorak" }
core.input.set_keymap = real
return got')"
check "input: numlock forwards" "true" \
	"$(eval_kiln 'local kiln = require("kiln")
local got = "not-called"
local real = core.input.set_numlock
core.input.set_numlock = function(on) got = tostring(on) end
kiln.input.numlock = true
core.input.set_numlock = real
return got')"

# =====================================================================
# The compositor stayed clean. Clay's DUPLICATE_ID error is in the grep on
# purpose: it is what a multi-select union that forgot to dedupe would trip.
#
# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's
# pcall, so this leg MUST go red under it, which is what proves the grep can see
# a swallowed handler error at all.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

noise=$(grep -cE "error in '|tree==scene:|DUPLICATE" "$log" || true)
check "no bus errors, no tree/scene divergence, no duplicate ids" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
