#!/bin/sh
# The FFI boundary battery. Nine facts:
#
#   1. ffi.C resolves kiln's own symbols, which is what export_dynamic buys.
#   2. core.dirty is Lua now: it lives in lua/kiln/cffi.lua, not in [C]. Its
#      l_dirty wrapper is gone from core.c.
#   3. The verb still does its job over the new transport: a named dirty solves
#      exactly that output, a bare dirty solves both, an unknown name no-ops.
#   4. The public edge validates before ffi.C is touched: a non-string
#      argument raises in Lua rather than reaching the cdef'd call.
#   5. The sweep moved exactly the verbs it claims and no others: each swept
#      verb is a Lua function defined in cffi.lua, the ones that stay classic
#      still report [C], and the core.* / core.client.* / core.input.* /
#      core.output.* key sets are unchanged, which is what keeps every caller
#      and IPC snippet working.
#   6. The swept verbs still do their job: an output setter's write is
#      visible through core.output.list, core.tick still arms a frame clock,
#      the lock trio still returns plain booleans, a stale timer_cancel no-ops.
#   7. The accept-set changes are exactly these and no more:
#      the string and number edges tightened (a number is no longer a string),
#      the boolean edges did NOT (lua_toboolean's truthiness is preserved), and
#      a table-shaped verb refuses a field of the wrong type instead of silently
#      handing C a NULL with the field's set flag raised.
#   8. The three readback verbs cross the same way: hits and output.list
#      fill a caller-allocated out-array, box returns a by-value struct already
#      rounded half-up in C, and cffi.lua turns each into plain Lua tables at the
#      public edge, so nothing a caller can see changed. Names come out of
#      (pointer, length): an anonymous Clay element carries a NULL stringId, and
#      a bare ffi.string would strlen it.
#   9. The per-frame declare path crosses too: core.open, core.close,
#      core.text and core.surface fill one scratch Clay_ElementDeclaration
#      reused across frames and call Clay directly, and the strings Clay retains
#      are anchored on the Lua side in the per-pass table C hands over. The
#      evidence is solved geometry: every declaration field that moves a box,
#      read back through core.box, plus the four edges that raise in Lua with
#      the messages C used to raise.
#
#   scripts/ffi-test.sh
#
# Pure headless, two outputs (WLR_HEADLESS_OUTPUTS=2). The per-output solve
# counter is the solve log itself ("solve #N on <name>:", ui.c), the counter
# animation-test.sh already asserts over: no new C surface to test the change
# that removes some.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-ffi-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"

# Pin the config, the way animation-test.sh does: an unpinned boot runs whatever
# config the user has installed rather than the one this battery asserts against.
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
# Solves logged for one output since boot (the per-output frame counter).
solves() { grep -cE "solve #[0-9]+ on $1:" "$log" || true; }
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   %s\n     (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s\n     expected %s\n     got      %s\n' "$1" "$2" "$3"
		fail=1
	fi
}
check_gt() { # label threshold actual
	if [ "$3" -gt "$2" ]; then
		printf 'ok   %s\n     (%s > %s)\n' "$1" "$3" "$2"
	else
		printf 'FAIL %s\n     expected > %s\n     got        %s\n' "$1" "$2" "$3"
		fail=1
	fi
}
# Wait for the solve log to stop growing before a snapshot is taken. A leg that
# snapshots, acts, sleeps and diffs counts the PREVIOUS leg's late solves as its
# own if they land after their own window closed: that was a 4% false red, six
# runs in 150. Quiescence is the thing those legs assume, so
# they wait for it instead. Three identical samples, 0.1s apart, 3s cap.
settle() {
	prev=""; same=0; i=0
	while [ "$i" -lt 30 ]; do
		cur="$(( $(solves "$A") + $(solves "$B") ))"
		if [ "$cur" = "$prev" ]; then
			same=$(( same + 1 ))
			[ "$same" -ge 2 ] && return 0
		else
			same=0
		fi
		prev="$cur"; i=$(( i + 1 )); sleep 0.1
	done
}

# --- 0. the source leg: no l_dirty wrapper survives in C, and the cdef lives in
# exactly one file. Static, so it runs before the compositor boots.
check "l_dirty is gone from core.c" "0" \
	"$(grep -cE '\bl_dirty\b' "$repo/core.c" || true)"
# 56 wrappers in all: 43 are FFI-swept and 13 stay classic Lua-C, and the counts
# below pin that split. l_surface is swept with the other declare verbs because
# it was the last caller of to_declaration.
check "only the 13 unswept l_* wrappers remain in core.c" "13" \
	"$(grep -cE '^static int l_' "$repo/core.c" || true)"
check "no l_client_/l_input_/l_output_set_ wrapper survives" "0" \
	"$(grep -cE '^static int l_(client_|input_|output_set_)' "$repo/core.c" || true)"
check "no l_hits/l_box/l_output_list wrapper survives" "0" \
	"$(grep -cE '^static int l_(hits|box|output_list)' "$repo/core.c" || true)"
check "no l_open/l_close/l_text/l_surface wrapper survives" "0" \
	"$(grep -cE '^static int l_(open|close|text|surface)' "$repo/core.c" || true)"
# The marshalling family went with them: no C function builds a Clay struct out
# of a Lua table any more, so cffi.lua's filler is the only such mapping in kiln
# and there is no second declare path beside it. field_table
# survives and is deliberately not in this pattern: it is a Lua-stack idiom with
# one caller, l_set_key_bindings, and it maps onto no Clay type.
check "no C function maps a Lua table onto a Clay struct" "0" \
	"$(grep -cE '^static (Clay_[A-Za-z_]+ |float field_num|int field_enum)' \
		"$repo/core.c" || true)"
check "ffi.cdef appears in exactly one lua/kiln file" "1" \
	"$(grep -rlE 'ffi\.cdef' "$repo/lua/kiln" | wc -l | tr -d ' ')"
check "the one file is cffi.lua" "$repo/lua/kiln/cffi.lua" \
	"$(grep -rlE 'ffi\.cdef' "$repo/lua/kiln")"
check "no raw ffi.C call escapes cffi.lua" "0" \
	"$(grep -rlE 'ffi\.C\b' "$repo/lua/kiln" | grep -cv '/cffi\.lua$' || true)"

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init.
cd "$repo"
WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=2 \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
	WLR_LIBINPUT_NO_DEVICES=1 KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

A=$(eval_kiln 'return core.output.list()[1].name')
B=$(eval_kiln 'return core.output.list()[2].name')
if [ -z "$A" ] || [ -z "$B" ] || [ "$A" = "$B" ]; then
	printf 'FAIL need two distinct headless outputs (got "%s" "%s")\n' "$A" "$B"
	echo "FAIL"; exit 1
fi
printf 'info outputs: A=%s  B=%s\n' "$A" "$B"

# --- 1. export_dynamic: ffi.C finds a symbol defined in the kiln executable.
# Without it the same lookup raises "undefined symbol", which is what this leg
# was red with before the meson change.
check "ffi.C resolves kiln_dirty out of the executable" "true" \
	"$(eval_kiln 'local ffi = require("ffi")
return tostring(pcall(function() return ffi.C.kiln_dirty end))')"

# --- 2. the verb is Lua now. Its chunk is cffi.lua; before the migration
# debug.getinfo reported "=[C]" for the registered closure.
check "core.dirty is a Lua function" "function" \
	"$(eval_kiln 'return type(core.dirty)')"
check "core.dirty is defined in cffi.lua" "lua/kiln/cffi.lua" \
	"$(eval_kiln 'local s = debug.getinfo(core.dirty, "S").source
return s:match("lua/kiln/cffi%.lua$") or s')"
# The public value is a plain Lua nil, no cdata leaks back out.
check "core.dirty returns no cdata" "0" \
	"$(eval_kiln 'return tostring(select("#", core.dirty()))')"

# --- 3. the verb still works, over the new transport. Every snapshot below is
# taken from a settled log, or the leg before it lends this one its solves.
settle
ac=$(solves "$A"); bc=$(solves "$B")
eval_kiln "core.dirty('$A')" >/dev/null
sleep 0.4
check_gt "a named dirty solved output A" "0" "$(( $(solves "$A") - ac ))"
check "a named dirty left output B alone" "0" "$(( $(solves "$B") - bc ))"

settle
ac=$(solves "$A"); bc=$(solves "$B")
eval_kiln 'core.dirty()' >/dev/null
sleep 0.4
check_gt "a bare dirty solved output A" "0" "$(( $(solves "$A") - ac ))"
check_gt "a bare dirty solved output B" "0" "$(( $(solves "$B") - bc ))"

settle
ac=$(solves "$A"); bc=$(solves "$B")
ret=$(eval_kiln 'core.dirty("no-such-output") return "ok"')
sleep 0.4
check "an unknown output name no-ops without error" "ok" "$ret"
check "an unknown name solved neither output" "0" \
	"$(( $(solves "$A") - ac + $(solves "$B") - bc ))"

# --- 4. the public edge raises, and it raises in Lua. If validation had
# been left to ffi.C the number would have been converted and passed through.
check "a non-string argument is refused at the edge" "false" \
	"$(eval_kiln 'return tostring(pcall(core.dirty, 42))')"
check "the refusal names the argument" "true" \
	"$(eval_kiln 'local ok, err = pcall(core.dirty, 42)
return tostring(tostring(err):match("core%.dirty") ~= nil)')"
check "the edge raise came from Lua, not a segfault" "true" \
	"$(eval_kiln 'return tostring(core ~= nil)')"

# --- 5. the verb sweep. The primitive namespace is the union of what C still
# registers and what cffi.lua installs back, and no caller can tell which is
# which. NAMES is all 56 primitive verbs, each in its namespace.
NAMES='local NAMES = {
  core = { "open","close","text","surface","hits","box","inspector",
    "inspector_scroll","screenshot","image_reload","set_frame_handler",
    "set_event_handler","set_lock_handler","set_key_bindings","timer","spawn",
    "spawn_with_token","spawn_pipe","replay","dirty","tick","quit",
    "timer_cancel","set_idle_timeout","layer_configure","lock","unlock",
    "authenticate","notify_closed","notify_action","tray_activate" },
  client = { "focus","configure","close","kill","set_activated",
    "set_fullscreen_hint","set_maximized_hint","set_tiled_hint",
    "set_suspended","set_minimized_hint","set_output_mirror" },
  input = { "grab_pointer","grab_keyboard","set_cursor","set_keymap",
    "set_repeat","set_numlock","set_pointer","set_cursor_theme" },
  output = { "list","set_mode","set_scale","set_position","set_enabled",
    "set_adaptive_sync" },
}
local function each(fn)
  for ns, list in pairs(NAMES) do
    local t = ns == "core" and core or core[ns]
    for _, k in ipairs(list) do fn(t[k], ns .. "." .. k) end
  end
end
local function where(f)
  return type(f) == "function" and debug.getinfo(f, "S").source or "missing"
end'

check "all 56 primitive verbs still answer to their name" "56" \
	"$(eval_kiln "$NAMES
local n = 0
each(function(f) if type(f) == \"function\" then n = n + 1 end end)
return n")"
# 43 is the 35 swept verbs, plus core.dirty, the 3 getters and the 4 declare
# verbs.
check "43 verbs moved to cffi.lua" "43" \
	"$(eval_kiln "$NAMES
local n = 0
each(function(f) if where(f):match(\"cffi%.lua\$\") then n = n + 1 end end)
return n")"
check "the other 13 are still C wrappers" "13" \
	"$(eval_kiln "$NAMES
local n = 0
each(function(f) if where(f) == \"=[C]\" then n = n + 1 end end)
return n")"

# --- 6. the swept verbs still do their job, over the new transport.
scale0=$(eval_kiln "return core.output.list()[1].scale")
eval_kiln "core.output.set_scale('$A', 1.5) core.output.set_position('$A', 40, 20)" >/dev/null
sleep 0.4
check "an output setter's write is visible through list()" "1.5|40|20" \
	"$(eval_kiln "local o = core.output.list()[1]
return o.scale .. '|' .. o.x .. '|' .. o.y")"
eval_kiln "core.output.set_scale('$A', $scale0) core.output.set_position('$A', 0, 0)" >/dev/null
sleep 0.4

settle
ac=$(solves "$A")
eval_kiln "core.tick('$A', true)" >/dev/null
sleep 0.5
eval_kiln "core.tick('$A', false)" >/dev/null
check_gt "core.tick armed the frame clock (more than one solve)" "1" \
	"$(( $(solves "$A") - ac ))"

# The lock trio runs at the end of the battery, not here. core.lock() engages
# the native lockscreen and only a PAM success can undo it, so core.unlock()
# answers false and the session stays locked: every leg after that point runs
# against a locked compositor, which the readback legs cannot feel but a declare
# leg can (the desktop frame handler stops being called).
check "a stale timer_cancel no-ops" "ok" \
	"$(eval_kiln 'core.timer_cancel(999999) return "ok"')"
check "a nil handle focuses nothing without error" "ok" \
	"$(eval_kiln 'core.client.focus(nil) core.client.focus() return "ok"')"

# --- 7. the accept-set diff. Validation moved from luaL_check* in C to
# the checkers in cffi.lua, and the two sides do not accept the same values.
# TIGHTENED: luaL_checkstring took a number and coerced it, luaL_checknumber
# took a numeric string. Neither crosses now.
check "a number is no longer a string (output.set_scale)" "false" \
	"$(eval_kiln 'return tostring(pcall(core.output.set_scale, 42, 2))')"
check "a numeric string is no longer a number (client.focus)" "false" \
	"$(eval_kiln 'return tostring(pcall(core.client.focus, "1"))')"
check "the refusal names the verb" "true" \
	"$(eval_kiln 'local ok, err = pcall(core.output.set_scale, 42, 2)
return tostring(tostring(err):match("core%.output%.set_scale") ~= nil)')"
check "a table-shaped verb refuses a wrong-typed field" "false" \
	"$(eval_kiln 'return tostring(pcall(core.input.set_keymap, { layout = 42 }))')"
# The old C read this field with lua_tostring: a boolean gave NULL while
# has_accel_profile stayed true, handing kiln.c a set flag with no string.
check "set_pointer refuses a boolean where a string goes" "false" \
	"$(eval_kiln 'return tostring(pcall(core.input.set_pointer,
  { accel_profile = true }))')"
check "set_pointer refuses a numeric string for accel_speed" "false" \
	"$(eval_kiln 'return tostring(pcall(core.input.set_pointer,
  { accel_speed = "0.3" }))')"
# UNCHANGED: lua_toboolean accepted any value and called only nil and false
# false. 0 is true in Lua, and it still is here.
check "the boolean edge did not tighten: 0 is still true" "ok" \
	"$(eval_kiln "core.output.set_enabled('$A', 0)
core.input.set_numlock('yes')
core.input.grab_keyboard({})
core.input.grab_keyboard(false)
return 'ok'")"
# UNCHANGED: the optional arguments keep their C defaults and their nil.
check "optional arguments still take nil" "ok" \
	"$(eval_kiln "core.input.set_cursor_theme(nil)
core.tray_activate('org.kde.StatusNotifierItem-0-0', 'activate')
core.set_idle_timeout()
core.client.set_output_mirror(0, nil)
return 'ok'")"
# Again over the whole sweep: no verb hands a cdata back to Lua. The lock trio
# is not covered here: core.lock() is terminal in a real-PAM build, so it runs
# in the last block of the battery instead, where it cannot stop the declare
# legs from getting a frame.
check "no swept verb returns cdata" "0" \
	"$(eval_kiln "$NAMES
local n = 0
local function seen(v) if type(v) == \"cdata\" then n = n + 1 end end
seen(core.dirty()) seen(core.timer_cancel(1))
seen(core.output.set_scale('$A', $scale0)) seen(core.input.set_numlock(false))
return n")"

# --- 8. the getters. Three readbacks, three shapes: hits and output.list
# fill caller-allocated out-arrays, box returns a by-value struct. What a caller
# sees is the plain Lua tables the deleted wrappers used to build by hand.
check "core.hits is defined in cffi.lua" "lua/kiln/cffi.lua" \
	"$(eval_kiln 'local s = debug.getinfo(core.hits, "S").source
return s:match("lua/kiln/cffi%.lua$") or s')"
check "core.box is defined in cffi.lua" "lua/kiln/cffi.lua" \
	"$(eval_kiln 'local s = debug.getinfo(core.box, "S").source
return s:match("lua/kiln/cffi%.lua$") or s')"
check "core.output.list is defined in cffi.lua" "lua/kiln/cffi.lua" \
	"$(eval_kiln 'local s = debug.getinfo(core.output.list, "S").source
return s:match("lua/kiln/cffi%.lua$") or s')"

# The probe: pin Clay's current context to output A (core.hits sets it, and
# core.box answers in whichever context solved last), then read A's workarea
# back and hit-test its centre. Layout coordinates, so A's own layout origin is
# added; section 6 moved this output and put it back. All of it is true before
# the migration too: these are controls on the transport swap, not new rules.
PROBE='local A = "'"$A"'"
local o
for _, x in ipairs(core.output.list()) do if x.name == A then o = x end end
core.hits(A, o.x, o.y)
local id = "workarea:" .. A
local b = core.box(id)
local cx, cy = o.x + b.x + b.width / 2, o.y + b.y + b.height / 2'

check "box reads a solved element back as four integers" "true" \
	"$(eval_kiln "$PROBE
return tostring(b.x == math.floor(b.x) and b.y == math.floor(b.y)
  and b.width == math.floor(b.width) and b.height == math.floor(b.height)
  and b.width > 0 and b.height > 0)")"
# Clay hashes a string id with offset 0, which is exactly what the { name, index }
# form asks for at index 0: one signature covers both id shapes.
check "the { id, 0 } form is the string form" "true" \
	"$(eval_kiln "$PROBE
local t = core.box({ id, 0 })
return tostring(t.x == b.x and t.y == b.y and t.width == b.width
  and t.height == b.height)")"
check "an id that was never declared is nil" "nil" \
	"$(eval_kiln "$PROBE
return tostring(core.box('no-such-element-ever'))")"
check "hits names the element whose box centre it probes" "true" \
	"$(eval_kiln "$PROBE
for _, h in ipairs(core.hits(A, cx, cy)) do
  if h.name == id then return 'true' end
end
return 'false'")"
# Names cross as (pointer, length), never as a C string: an anonymous Clay
# element carries CLAY__STRING_DEFAULT, whose chars are NULL, and a bare
# ffi.string would strlen(NULL). The scene has such elements under every point.
check "an anonymous element's name is empty, not a strlen of NULL" "true" \
	"$(eval_kiln "$PROBE
local hits, anon = core.hits(A, cx, cy), 0
for _, h in ipairs(hits) do
  if type(h.name) ~= 'string' then return 'name is a ' .. type(h.name) end
  if h.name == '' then anon = anon + 1 end
end
return tostring(#hits > 1 and anon > 0)")"
check "output.list reports both outputs with all nine keys" "2|true" \
	"$(eval_kiln "local l = core.output.list()
for _, o in ipairs(l) do
  if type(o.name) ~= 'string' or type(o.width) ~= 'number'
    or type(o.height) ~= 'number' or type(o.refresh) ~= 'number'
    or type(o.scale) ~= 'number' or type(o.x) ~= 'number'
    or type(o.y) ~= 'number' or type(o.enabled) ~= 'boolean'
    or type(o.modes) ~= 'table' then
    return #l .. '|' .. o.name
  end
end
return #l .. '|true'")"
# Over the whole readback, fields and nested tables included: a uint32_t
# index or a struct field handed back raw would show up here as cdata.
check "no getter hands back cdata, at any depth" "0" \
	"$(eval_kiln "$PROBE
local n = 0
local function seen(v) if type(v) == 'cdata' then n = n + 1 end end
seen(b) seen(b.x) seen(b.width)
for _, h in ipairs(core.hits(A, cx, cy)) do seen(h) seen(h.name) seen(h.index) end
for _, out in ipairs(core.output.list()) do
  seen(out) seen(out.name) seen(out.scale) seen(out.enabled) seen(out.modes)
  for _, m in ipairs(out.modes) do seen(m.width) seen(m.height) seen(m.refresh) end
end
return n")"

# The getters' accept-set. luaL_checkstring took a number, and
# luaL_checknumber took a numeric string; neither crosses now.
check "hits refuses a number where the screen goes" "false" \
	"$(eval_kiln 'return tostring(pcall(core.hits, 42, 0, 0))')"
check "hits refuses a numeric string for x and y" "false" \
	"$(eval_kiln "return tostring(pcall(core.hits, '$A', '0', '0'))")"
check "the hits refusal names the verb" "true" \
	"$(eval_kiln 'local ok, err = pcall(core.hits, 42, 0, 0)
return tostring(tostring(err):match("core%.hits") ~= nil)')"
check "box refuses a number id" "false" \
	"$(eval_kiln 'return tostring(pcall(core.box, 42))')"
# UNCHANGED: to_element_id already rejected a non-numeric index outright, to keep
# a config typo from collapsing every such id onto one hash.
check "box still refuses a non-numeric table index" "false" \
	"$(eval_kiln 'return tostring(pcall(core.box, { "x", "1" }))')"
# The one that was not an error before: luaL_checkany passed nil through, and
# to_element_id then ran lua_rawgeti on it, which segfaults kiln.
check "box refuses nil instead of segfaulting on it" "false" \
	"$(eval_kiln 'return tostring(pcall(core.box, nil))')"
check "the compositor survived the nil id" "true" \
	"$(eval_kiln 'return tostring(core.box ~= nil)')"

# --- 9. the per-frame declare path. core.open, core.close, core.text and
# core.surface cross by FFI: the declaration is filled into one scratch cdata
# reused across frames and handed to Clay__ConfigureOpenElementPtr, and the
# strings Clay retains are anchored in the per-pass table C hands over through
# core.__declare. Nothing a caller can see changes, so what these legs measure
# is solved geometry: every field of the declaration that moves a box, read back
# through core.box, plus the edges that now raise in Lua.
check "core.open is defined in cffi.lua" "lua/kiln/cffi.lua" \
	"$(eval_kiln 'local s = debug.getinfo(core.open, "S").source
return s:match("lua/kiln/cffi%.lua$") or s')"
check "core.close is defined in cffi.lua" "lua/kiln/cffi.lua" \
	"$(eval_kiln 'local s = debug.getinfo(core.close, "S").source
return s:match("lua/kiln/cffi%.lua$") or s')"
check "core.text is defined in cffi.lua" "lua/kiln/cffi.lua" \
	"$(eval_kiln 'local s = debug.getinfo(core.text, "S").source
return s:match("lua/kiln/cffi%.lua$") or s')"
check "core.surface is defined in cffi.lua" "lua/kiln/cffi.lua" \
	"$(eval_kiln 'local s = debug.getinfo(core.surface, "S").source
return s:match("lua/kiln/cffi%.lua$") or s')"

# Outside a declare pass there is no scratch to fill and no anchor table to hold
# the strings, so the edge raises rather than corrupting Clay's open stack. This
# is check_in_declare's message, moved to Lua and kept word for word.
check "a declare verb outside the frame handler raises" "false" \
	"$(eval_kiln 'return tostring(pcall(core.open, {}))')"
check "the refusal names the frame handler" "true" \
	"$(eval_kiln 'local ok, err = pcall(core.open, {})
return tostring(tostring(err):match("inside the frame handler") ~= nil)')"

# The probe scene. One deterministic subtree per output, covering every
# declaration field that moves a box: fixed and grow and percent and fit sizing
# with min/max, padding, childGap, childAlignment, layoutDirection, floating with
# an offset and an attach point, clip with a childOffset, the { name, index } id
# form, and a text leaf whose fontSize drives the fit. The three raises the edge
# owes are taken here too, under pcall, so they answer without writing a lua
# error line into the log.
eval_kiln 'ANCHOR_N = 0
core.set_frame_handler(function(sn, w, h)
  ANCHOR_N = ANCHOR_N + 1
  P = {}
  core.open({ id = "p-root",
    layout = {
      sizing = { width = 400, height = 200 },
      padding = { left = 10, right = 20, top = 5, bottom = 15 },
      childGap = 7,
      childAlignment = { x = "right", y = "top" },
      layoutDirection = "ttb",
    },
    backgroundColor = { r = 10, g = 20, b = 30, a = 255 },
    cornerRadius = { topLeft = 4, topRight = 4, bottomLeft = 4, bottomRight = 4 },
    border = { color = { r = 1, g = 2, b = 3, a = 255 },
      width = { left = 2, right = 3, top = 4, bottom = 5, betweenChildren = 1 } },
  })
    core.open({ id = "p-grow",
      layout = { sizing = { width = { type = "grow" }, height = 30 } } })
    core.close()
    core.open({ id = "p-pct",
      layout = { sizing = { width = { type = "percent", percent = 0.5 },
        height = 20 } } })
    core.close()
    core.open({ id = "p-fit",
      layout = { sizing = { width = { type = "fit", min = 44, max = 88 },
        height = 24 } } })
      core.text("hi", { fontId = 0, fontSize = 20, letterSpacing = 0,
        lineHeight = 0, wrapMode = "none", textAlignment = "center",
        textColor = { r = 255, g = 255, b = 255, a = 255 } })
    core.close()
  core.close()
  -- The same string at two font sizes, each in a box that fits its content, so
  -- the solved widths are the measured text widths. Nothing but the fontSize
  -- crossing the boundary can separate them.
  core.open({ id = "p-small", layout = { sizing = {
    width = { type = "fit" }, height = { type = "fit" } } } })
    core.text("measure me", { fontSize = 10, wrapMode = "none" })
  core.close()
  core.open({ id = "p-big", layout = { sizing = {
    width = { type = "fit" }, height = { type = "fit" } } } })
    core.text("measure me", { fontSize = 30, wrapMode = "none" })
  core.close()
  core.open({ id = "p-float",
    floating = { attachTo = "root", offset = { x = 100, y = 50 }, zIndex = 3,
      expand = { width = 0, height = 0 },
      attachPoints = { element = "left_top", parent = "left_top" },
      pointerCaptureMode = "passthrough", clipTo = "none" },
    layout = { sizing = { width = 60, height = 40 } } })
  core.close()
  core.open({ id = "p-clip",
    clip = { horizontal = true, vertical = false,
      childOffset = { x = -5, y = 0 } },
    layout = { sizing = { width = 50, height = 50 } } })
    core.open({ id = "p-clipchild",
      layout = { sizing = { width = 30, height = 10 } } })
    core.close()
  core.close()
  core.open({ id = { "p-idx", 7 },
    layout = { sizing = { width = 11, height = 13 } } })
  core.close()
  -- A fresh id every frame, so the previous frames anchor is collectable and
  -- the name core.hits reads back can only be right if this frame anchored it.
  core.open({ id = "p-anchor-" .. ANCHOR_N,
    layout = { sizing = { width = 9, height = 9 } } })
  core.close()
  -- The edges, taken inside a real declare pass so the in_declare check is not
  -- what answers. Each is pcalled, so none of them writes to the log.
  P.badidx = select(2, pcall(core.open, { id = { "bad", "notanumber" } }))
  P.unmatched = select(2, pcall(core.close))
  P.badhandle = select(2, pcall(core.surface, "notanumber"))
  P.nontable = select(2, pcall(core.open, 42))
  -- From inside a real pass: the declare verbs hand nothing back, least
  -- of all a cdata view of the scratch declaration they just filled.
  P.openrets = select("#", core.open({ id = "p-rets",
    layout = { sizing = { width = 5, height = 5 } } }))
  P.textrets = select("#", core.text("r"))
  P.closerets = select("#", core.close())
end)
return "installed"' >/dev/null
settle
eval_kiln "core.dirty('$A')" >/dev/null
sleep 0.4
settle

# core.hits pins Clay to output A first, the way section 8 does: core.box answers
# in whichever context solved last, and with two outputs that is not necessarily
# the one being asked about.
PROBE9='local A = "'"$A"'"
local o
for _, x in ipairs(core.output.list()) do if x.name == A then o = x end end
core.hits(A, o.x, o.y)
local function b(id) return core.box(id) end
local root = b("p-root")'

check "a fixed sizing pair solves to exactly that box" "400|200" \
	"$(eval_kiln "$PROBE9
return root.width .. '|' .. root.height")"
# padding left 10 / top 5, grow across a 400 box minus left 10 and right 20.
check "padding and grow place the first child" "10|5|370|30" \
	"$(eval_kiln "$PROBE9
local c = b('p-grow')
return (c.x - root.x) .. '|' .. (c.y - root.y) .. '|' .. c.width .. '|' .. c.height")"
# percent 0.5 of the 370 content width, right-aligned by childAlignment.x, and
# pushed down by the first child plus childGap 7.
check "percent sizing, childAlignment and childGap place the second" "195|42|185|20" \
	"$(eval_kiln "$PROBE9
local c = b('p-pct')
return (c.x - root.x) .. '|' .. (c.y - root.y) .. '|' .. c.width .. '|' .. c.height")"
# fit clamped to [44, 88] around a 20px text leaf: the text has to have measured
# for this to land inside the clamp at all.
check "fit sizing clamps to its min and max around the text" "true" \
	"$(eval_kiln "$PROBE9
local c = b('p-fit')
return tostring(c.width >= 44 and c.width <= 88 and c.height == 24
  and (c.y - root.y) == 69)")"
# The text config crossed with its fontSize: the same string measures wider and
# taller at 30px than at 10px, and Pango is what answers, through the measure
# callback Clay calls during the solve.
check "fontSize crosses: the same text measures larger" "true" \
	"$(eval_kiln "$PROBE9
local s, g = b('p-small'), b('p-big')
return tostring(s.width > 0 and s.height > 0
  and g.width > s.width and g.height > s.height)")"
# attachTo root plus offset is absolute positioning in layout coordinates.
check "floating attaches to the root at its offset" "100|50|60|40" \
	"$(eval_kiln "$PROBE9
local c = b('p-float')
return c.x .. '|' .. c.y .. '|' .. c.width .. '|' .. c.height")"
# clip carries the child offset; Clay attaches childOffset only when an axis
# clips, so -5 on x is the whole mechanism this leg is here for.
check "clip childOffset shifts the child, not the parent" "-5|50|50" \
	"$(eval_kiln "$PROBE9
local p, c = b('p-clip'), b('p-clipchild')
return (c.x - p.x) .. '|' .. p.width .. '|' .. p.height")"
check "the { name, index } id form declares and reads back" "11|13" \
	"$(eval_kiln "$PROBE9
local c = b({ 'p-idx', 7 })
return c.width .. '|' .. c.height")"
check "the string form does not answer for an indexed id" "nil" \
	"$(eval_kiln "$PROBE9
return tostring(b('p-idx'))")"
# The anchor leg. The id is rebuilt every frame, so the string the PREVIOUS pass
# handed Clay is collectable; a full GC before the query makes that concrete.
# core.hits reads the name out of Clay's hashmap, so it can only be right if this
# pass anchored its own bytes, which is now the Lua side's job.
check "a per-frame id survives a GC and reads back by name" "true" \
	"$(eval_kiln "$PROBE9
collectgarbage('collect')
local n = ANCHOR_N
local c = b('p-anchor-' .. n)
if c == nil then return 'no box for frame ' .. n end
for _, h in ipairs(core.hits(A, o.x + c.x + c.width / 2, o.y + c.y + c.height / 2)) do
  if h.name == 'p-anchor-' .. n then return 'true' end
end
return 'no hit named p-anchor-' .. n")"

# The edges the probe took inside a real pass. Each message is the one C raised,
# kept word for word so a config author sees no change.
check "a non-numeric table id still raises at declare" "true" \
	"$(eval_kiln 'return tostring(tostring(P.badidx):match(
  "table id index must be a number") ~= nil)')"
check "core.close without core.open raises" "true" \
	"$(eval_kiln 'return tostring(tostring(P.unmatched):match(
  "core%.close without matching core%.open") ~= nil)')"
check "core.surface refuses a non-number handle at the edge" "true" \
	"$(eval_kiln 'return tostring(tostring(P.badhandle):match("core%.surface") ~= nil)')"
check "core.open refuses a non-table declaration" "true" \
	"$(eval_kiln 'return tostring(tostring(P.nontable):match("core%.open") ~= nil)')"
check "no declare verb returns anything" "0|0|0" \
	"$(eval_kiln 'return P.openrets .. "|" .. P.textrets .. "|" .. P.closerets')"

# An unclosed element is rebalanced at the end of the pass, against Clay's own
# open stack now that C no longer counts opens. A handler that leaks one open
# must not take the tree down, and the next pass must be clean.
eval_kiln 'core.set_frame_handler(function(sn, w, h)
  core.open({ id = "p-leak", layout = { sizing = { width = 12, height = 12 } } })
end)
return "installed"' >/dev/null
settle
eval_kiln "core.dirty('$A')" >/dev/null
sleep 0.4
settle
check "an unclosed element is rebalanced, not fatal" "12|12" \
	"$(eval_kiln "$PROBE9
local c = b('p-leak')
return c.width .. '|' .. c.height")"
check "the compositor survived the unbalanced pass" "2" \
	"$(eval_kiln 'return 1 + 1')"

# The lock legs run last because they are terminal on a real-PAM build:
# core.lock() engages the native lockscreen, core.unlock() is gated on a PAM
# success that no stub provides, and from that point the desktop frame handler
# is never called again. Locking in section 6 or 7 instead leaves every later
# leg running against a locked compositor, which the readback legs cannot feel
# and a declare leg cannot survive.
check "the lock trio returns plain booleans, not cdata" "boolean|boolean|0" \
	"$(eval_kiln 'local a = core.lock()
local b = core.unlock()
local n = 0
if type(a) == "cdata" then n = n + 1 end
if type(b) == "cdata" then n = n + 1 end
return type(a) .. "|" .. type(b) .. "|" .. n')"

# --- the compositor stayed clean through every dirty and every refusal.
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

noise=$(grep -cE "lua error|error in '|tree==scene:" "$log" || true)
check "no lua errors, no tree/scene divergence" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
