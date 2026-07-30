#!/bin/sh
# The anchor-lifetime battery. Four facts:
#
#   1. A screen's declare-time id strings survive ANOTHER screen's declare and
#      a full GC: core.hits on the screen that did not declare last names its
#      elements byte for byte. Unanchored, the strings one screen's declare
#      interned are collectible the moment another screen declares, and the hit
#      names read back as freed bytes. Asserted for both screens, because
#      either one can be the one left behind.
#   2. The control, same round with the two declares swapped so the queried
#      screen declares LAST. Green with the anchors and without them: that is
#      what says a red in fact 1 is the anchor lifetime and not the probe, the
#      churn, or the hit index.
#   3. Names still cross as (pointer, length), so an anonymous Clay element is
#      the empty string and never a strlen of NULL. Re-asserted here because
#      holding the ids alive by copying bytes instead would have changed that.
#   4. The shape shipped is the anchor table, not the byte copy: core.__anchors
#      exists and struct ui_hit still hands out a pointer.
#
# Usage:
#   scripts/anchor-test.sh                        # 25 rounds per leg
#   KILN_ANCHOR_ROUNDS=100 scripts/anchor-test.sh
#
# Pure headless, two outputs (WLR_HEADLESS_OUTPUTS=2), the repo config pinned.
# The defect is intermittent by nature, so fact 1 is a RATE over N rounds inside
# ONE boot, and the evidence is the paired control: the same N rounds on a build
# without the anchors must go red at a measured rate, same machine same hour. A
# single green run is not evidence.
#
# The target string is init.lua's "root-fill:" .. screen_name, built fresh by
# every declare and referenced by nothing else once its anchor is dropped. The
# query chunk deliberately never spells that string: a Lua chunk holds its own
# constants alive, so a chunk mentioning the target would re-intern it and read
# correct for that reason alone. The chunk knows the screen name and an index,
# and the comparison happens in the shell.

set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-anchor-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
rounds="${KILN_ANCHOR_ROUNDS:-25}"

# Pin the config: an unpinned boot runs whatever
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
# Dirty one output and wait for the solve it asks for. The count is snapshotted
# before the dirty is sent, so a solve that lands while the eval is in flight is
# still this call's, and never a solve some earlier call asked for.
dirty_wait() { # name
	_before="$(solves "$1")"
	eval_kiln "core.dirty('$1')" >/dev/null
	_i=0
	while [ "$_i" -lt 30 ]; do
		if [ "$(solves "$1")" -gt "$_before" ]; then return 0; fi
		_i=$(( _i + 1 )); sleep 0.1
	done
	return 1
}
# Wait for the solve log to stop growing. Three identical samples, 0.1s apart.
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
	return 0
}

# --- 4. the shape leg. Static, so it runs before the compositor boots: it says
# which of the two possible shapes is on disk. (a) is an anchor table keyed by
# the Clay context; (b) would have put a char array in struct ui_hit and churned
# the cdef and its guard. A silent drift from one to the other is caught here.
# Two sites: core_create makes the table, core_declare_ref parks each pass's
# anchors in it under the Clay context.
check "core.__anchors is the anchor store (shape a)" "2" \
	"$(grep -cE '"__anchors"' "$repo/core.c" || true)"
check "the pass table is keyed by the Clay context, not the screen name" "1" \
	"$(grep -cE 'lua_pushlightuserdata\(L, Clay_GetCurrentContext\(\)\)' \
		"$repo/core.c" || true)"
check "struct ui_hit still hands out a name pointer, not a buffer" "1" \
	"$(grep -cE '^[[:space:]]*const char \*name;' "$repo/ui.h" || true)"
check "ui.h grew no fixed-size name buffer (shape b)" "0" \
	"$(grep -cE 'char name\[' "$repo/ui.h" || true)"
# Scoped to the ui_hit cdef: core_output_info legitimately carries a char[64],
# so a bare search for a name buffer in cffi.lua is not the question asked.
check "the ui_hit cdef still declares a name pointer (shape b)" "1" \
	"$(grep -A1 'struct ui_hit {' "$repo/lua/kiln/cffi.lua" \
		| grep -cE '^[[:space:]]*const char \*name;' || true)"
check "cffi.lua still copies a (pointer, length) pair" "1" \
	"$(grep -cE 'ffi\.string\(h\.name, h\.name_len\)' "$repo/lua/kiln/cffi.lua" || true)"

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
printf 'info outputs: A=%s  B=%s  rounds=%s\n' "$A" "$B" "$rounds"
settle

# The reference read, once, per screen: the name of the root-fill float and its
# position in the hit list at the probe point. root-fill is a full-output
# background float with passthrough, so it covers every point of its own screen
# and nothing else's, and its id is built by concatenation every declare, which
# is what makes it collectible. Everything after this indexes that position and
# compares to these bytes; a round whose hit list changed shape is skipped
# rather than counted, because then the index means something else.
reference() { # screen -> "want|idx|count", or "" if root-fill is not under the point
	eval_kiln 'local S = "'"$1"'"
local want = "root-fill:" .. S
local o
for _, x in ipairs(core.output.list()) do if x.name == S then o = x end end
local hits = core.hits(S, o.x + 5, o.y + 5)
for i, h in ipairs(hits) do
  if h.name == want then return want .. "|" .. i .. "|" .. #hits end
end
return ""'
}

dirty_wait "$A" || true
want_A="$(reference "$A")"
dirty_wait "$B" || true
want_B="$(reference "$B")"
if [ -z "$want_A" ] || [ -z "$want_B" ]; then
	printf 'FAIL no root-fill id under the probe point (A="%s" B="%s")\n' \
		"$want_A" "$want_B"
	echo "FAIL"; exit 1
fi
printf 'info reference A: %s\n' "$want_A"
printf 'info reference B: %s\n' "$want_B"

# One round. Both declares happen either way; only their ORDER differs, which is
# the whole experiment:
#
#   order=far   SCREEN declares, then OTHER. OTHER's declare is what releases
#               SCREEN's anchors on the unfixed build. This is fact 1.
#   order=near  OTHER declares, then SCREEN. SCREEN's own anchors are the live
#               ones, so this is green on every build. This is fact 2, the
#               control: same churn, same index, same probe point.
#
# The churn and the query are ONE eval so no frame can land between them;
# SCREEN's solve count is sampled either side of that eval, and a round that saw
# SCREEN re-solve is SKIPPED, not counted, because a re-declare re-anchors the
# string and would read green for the wrong reason. The clock's minute rollover
# is the only thing in rc.lua that can do that.
#
# The churn strings are all digits and run through the byte lengths around the
# target's, because LuaJIT bins string allocations by rounded size and the freed
# bytes are only overwritten by a string that lands in the same bin. A string
# that does land there reads back as digits: the length is right and the bytes
# are wrong, which is the signature of a collected id, printed.
round() { # screen ref order -> prints "green" | "red <bytes>" | "skip"
	_s="$1"
	_want="${2%%|*}"
	_rest="${2#*|}"
	_idx="${_rest%%|*}"
	_n="${_rest##*|}"
	_other="$B"; if [ "$_s" = "$B" ]; then _other="$A"; fi

	if [ "$3" = far ]; then _first="$_s"; _last="$_other";
	else _first="$_other"; _last="$_s"; fi
	dirty_wait "$_first" || { echo "skip"; return; }
	dirty_wait "$_last" || { echo "skip"; return; }

	_pre="$(solves "$_s")"
	_got="$(eval_kiln 'local S, IDX, L = "'"$_s"'", '"$_idx"', '"${#_want}"'
collectgarbage("collect")
local churn, k = {}, 0
for pad = -4, 4 do
  local fmt = "%0" .. (L + pad) .. "d"
  for i = 1, 8000 do k = k + 1; churn[k] = string.format(fmt, i) end
end
local o
for _, x in ipairs(core.output.list()) do if x.name == S then o = x end end
local hits = core.hits(S, o.x + 5, o.y + 5)
local h = hits[IDX]
local raw = h and h.name or "<no-hit>"
local shown = raw:gsub("[^%w%.:_%-]", function(c)
  return string.format("<%02X>", c:byte())
end)
return shown .. "|" .. #raw .. "|" .. #hits')"
	_post="$(solves "$_s")"

	if [ "$_pre" != "$_post" ]; then echo "skip"; return; fi
	if [ "${_got##*|}" != "$_n" ]; then echo "skip"; return; fi
	if [ "${_got%%|*}" = "$_want" ]; then echo "green"; else echo "red $_got"; fi
}

# --- 1. the defect, both screens. --- 2. the control, both screens. The four
# legs differ only in which screen is queried and which of the two declares came
# last; everything else about a round is identical, which is what makes the
# near legs a control on the far ones rather than a second assertion.
#
# Per-boot behaviour worth knowing when reading a red count: whether the freed
# bytes get overwritten is settled by the allocator's state at boot, so a far
# leg tends to be all red or all green for the life of one compositor. The
# paired control is therefore run over several boots, not several rounds.
for leg in "far $A" "far $B" "near $A" "near $B"; do
	order="${leg%% *}"; s="${leg#* }"
	if [ "$s" = "$A" ]; then ref="$want_A"; else ref="$want_B"; fi
	if [ "$order" = far ]; then
		label="$s queried after the other screen declared"
	else
		label="$s queried after its own declare (control)"
	fi
	red=0; skip=0; i=0
	first_red=""
	while [ "$i" -lt "$rounds" ]; do
		i=$(( i + 1 ))
		r="$(round "$s" "$ref" "$order")"
		case "$r" in
		green) ;;
		skip) skip=$(( skip + 1 )) ;;
		red*)
			red=$(( red + 1 ))
			if [ -z "$first_red" ]; then first_red="${r#red }"; fi
			;;
		esac
	done
	printf 'info %s: %s rounds, %s red, %s skipped\n' \
		"$label" "$rounds" "$red" "$skip"
	if [ -n "$first_red" ]; then
		printf 'info first red bytes: %s (wanted %s)\n' \
			"$first_red" "${ref%%|*}"
	fi
	check "$label reads its id back byte for byte" "0" "$red"
	# A run that skipped everything proves nothing; say so rather than pass.
	check "the rounds that counted are a majority" "true" \
		"$(if [ "$skip" -lt $(( rounds / 2 )) ]; then echo true; else echo false; fi)"
done

# --- 3. names are still (pointer, length): the anonymous elements under the
# probe point come back as the empty string, not a strlen of NULL. The scene has
# such elements under every point.
check "an anonymous element's name is empty, not a strlen of NULL" "true" \
	"$(eval_kiln 'local S = "'"$A"'"
local o
for _, x in ipairs(core.output.list()) do if x.name == S then o = x end end
local hits, anon = core.hits(S, o.x + 5, o.y + 5), 0
for _, h in ipairs(hits) do
  if type(h.name) ~= "string" then return "name is a " .. type(h.name) end
  if h.name == "" then anon = anon + 1 end
end
return tostring(#hits > 1 and anon > 0)')"

# The compositor has to have survived all of it, and quietly.
check "the compositor is still answering" "true" \
	"$(eval_kiln 'return tostring(core.hits ~= nil)')"
noise=$(grep -cE "lua error|error in '|tree==scene:" "$log" || true)
check "no lua errors, no tree/scene divergence" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
