#!/bin/sh
# The client battery: the command surface over the socket, driven through the
# installed client rather than through eval, so what is under test is the same
# path a user types.
#
#   scripts/cli-test.sh
#
#   1. Every verb family answers, and the reply shape is the one the client
#      knows how to read (OK header stripped, ERROR to stderr, exit code set).
#   2. --json is valid JSON in both the ok and the error arm.
#   3. The handler installers stay unreachable through the reflection verbs and
#      reachable through eval. Each replaces live runtime state with no way
#      back, so a wrong one ends the session: the ergonomic surface must refuse
#      them and the escape hatch must not.
#   4. A reply past the old fixed buffer arrives whole. A truncated answer is
#      indistinguishable from a complete one, which is why this is asserted on
#      a length rather than on content.
#   5. An argument holding spaces survives quoting, which a join-on-space wire
#      format loses.
#   6. Raw Lua over the same socket is undisturbed, because every other battery
#      rides that path.
#   7. Every verb describes itself, the shape a user is shown is the arity that
#      is actually enforced, and completion answers from live state rather than
#      from a list that can go stale.
#
# Needs: build/kiln, build/kiln-client, build/wl-toplevel, python3.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-cli-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
rc="$work/rc.lua"
kiln_pid=""
probe_pid=""

cleanup() {
	[ -n "$probe_pid" ] && kill "$probe_pid" 2>/dev/null || true
	[ -n "$kiln_pid" ] && kill "$kiln_pid" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

fail=0
K="$repo/build/kiln-client"
kc() { KILN_SOCK="$sock" "$K" "$@"; }
raw() { KILN_SOCK="$sock" "$repo/scripts/kiln-eval" "$1"; }

check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   %s\n     (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s\n     expected %s\n     got      %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

# Two tags with known names, so a selector has something stable to resolve.
cat > "$rc" <<'EOF'
local kiln = require("kiln")

screen.on("added", function(s)
	for _, name in ipairs({ "web", "code" }) do
		tag.new { name = name, screen = s }
	end
	s.selected_tag = s.tags[1]
end)
EOF

WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 KILN_RC="$rc" \
	KILN_SOCK="$sock" "$repo/build/kiln" > "$log" 2>&1 &
kiln_pid=$!
sleep 2

check "the compositor booted" "1" \
	"$(grep -c 'Running Wayland compositor' "$log")"

# --------------------------------------------------------------------------
# 1. The verb families.

check "ping answers" "pong" "$(kc ping)"
check "commands lists a verb surface" "yes" \
	"$([ "$(kc commands | wc -l)" -gt 40 ] && echo yes || echo no)"

check "screen list names the output" "1" \
	"$(kc screen list | grep -c 'HEADLESS-1')"
check "screen count" "1" "$(kc screen count)"
check "screen focused" "HEADLESS-1" "$(kc screen focused)"

check "tag list carries both tags" "2" "$(kc tag list | wc -l)"
check "tag current is the selected one" "web" "$(kc tag current)"
kc tag view code > /dev/null
check "tag view switches" "code" "$(kc tag current)"

check "layout get reads a name, not an address" "tile" "$(kc layout get)"
kc layout set spiral > /dev/null
check "layout set takes" "spiral" "$(kc layout get)"
kc layout set tile > /dev/null

# A tag layout param is a plain property, so the verb and the reflection layer
# are two faces of one write.
kc tag mwfact code 0.7 > /dev/null
check "tag mwfact writes" "0.7" "$(kc get tag code master_width_factor)"
check "output list names the output" "1" \
	"$(kc output list | grep -c 'HEADLESS-1')"
# A verb that does not check hands nil to the primitive layer, which reports
# the failure in its own terms rather than in the caller's.
check "output scale names a non-number" "1" \
	"$(kc output scale HEADLESS-1 big 2>&1 >/dev/null \
		| grep -c "output scale: 'big' is not a number")"
check "output enabled names a non-boolean" "1" \
	"$(kc output enabled HEADLESS-1 sometimes 2>&1 >/dev/null \
		| grep -c 'is not on or off')"
check "theme get reads a key" "8" "$(kc theme get gap)"
kc theme set gap 12 > /dev/null
check "theme set writes" "12" "$(kc theme get gap)"
kc theme set gap 8 > /dev/null
check "input reports its settings" "yes" \
	"$([ "$(kc input | wc -l)" -ge 11 ] && echo yes || echo no)"
check "key list answers" "0" "$(kc key list | wc -l)"
check "rule list answers" "0" "$(kc rule list | wc -l)"

# --------------------------------------------------------------------------
# 2. Reply shape and exit codes.

# Captured through `|| rc=$?` rather than a trailing `echo $?`: set -e aborts
# the substitution subshell the moment the client exits nonzero, so the naive
# form reports an empty string for every failing arm and passes vacuously.
status() { # command...
	local_rc=0
	"$@" > /dev/null 2>&1 || local_rc=$?
	echo "$local_rc"
}

check "an ok verb exits 0" "0" "$(status kc ping)"
check "a failing verb exits 1" "1" "$(status kc tag view nosuchtag)"
check "an error goes to stderr, not stdout" "" \
	"$(kc tag view nosuchtag 2>/dev/null || true)"
check "an error names the tag" "1" \
	"$(kc tag view nosuchtag 2>&1 >/dev/null | grep -c "nosuchtag")"
# Inline rather than through status(), because an environment assignment in
# front of a shell function is not portably scoped to that call.
absent_rc=0
KILN_SOCK="$work/absent.sock" "$K" ping > /dev/null 2>&1 || absent_rc=$?
check "an absent socket exits 2" "2" "$absent_rc"
check "an unknown verb is named as unknown" "1" \
	"$(kc bogus verb 2>&1 >/dev/null | grep -c 'unknown command')"
# The flag needs a separator: glued, it is a verb nobody wrote.
check "--json glued to a word is not the flag" "1" \
	"$(kc --jsonping 2>&1 >/dev/null | grep -c 'unknown command: --jsonping')"
# Asserted on the message, not the exit code: a truncated path fails to
# connect too, and names a path the caller never gave while doing it.
check "a socket path too long for the address says so" "1" \
	"$(KILN_SOCK="/tmp/$(python3 -c 'print("x" * 200)')" "$K" ping 2>&1 \
		>/dev/null | grep -c 'longer than')"

# --------------------------------------------------------------------------
# 3. JSON.

check "--json ok arm parses" "ok" \
	"$(kc --json tag current | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
check "--json error arm parses" "error" \
	"$(kc --json tag view nosuchtag 2>&1 >/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
check "--json carries real types, not stringified ones" "int" \
	"$(kc --json screen count | python3 -c 'import json,sys; print(type(json.load(sys.stdin)["result"]).__name__)')"
check "--json list result is an array" "list" \
	"$(kc --json tag list | python3 -c 'import json,sys; print(type(json.load(sys.stdin)["result"]).__name__)')"

# A failure outside the handler call still has to answer in the shape the
# caller asked for. An argument list this long raises inside unpack, which is
# the dispatcher's own plumbing, not a verb: if that escapes, the reply is the
# eval layer's plain text and a --json caller reads an error as a success.
many="$(python3 -c 'print(" ".join(["x"] * 10000))')"
# shellcheck disable=SC2086
check "an argument list past unpack still answers as JSON" "error" \
	"$(kc --json get $many 2>&1 >/dev/null \
		| python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
# shellcheck disable=SC2086
check "and exits 1, not 0" "1" "$(status kc --json get $many)"

# --------------------------------------------------------------------------
# 4. The handler installers: refused by reflection, reachable by eval.
#
# Asserted on reachability, never by calling one: calling one is the exact
# accident the refusal exists to prevent.

for verb in get set call; do
	check "$verb refuses the primitive namespace" "1" \
		"$(kc $verb core all set_event_handler x 2>&1 >/dev/null \
			| grep -c 'no such class')"
done
check "reflect refuses it too" "1" \
	"$(kc reflect core 2>&1 >/dev/null | grep -c 'no such class')"
check "no class exposes an installer as a method" "0" \
	"$(for c in client screen tag layer notification; do
		kc reflect $c | grep -c 'set_event_handler\|set_frame_handler'
	done | paste -sd+ | bc)"
check "eval still reaches an installer" "function" \
	"$(kc eval 'return type(core.set_event_handler)')"

# The mixin's bus methods sit on every class, so `call` reaches them without
# anything having offered them. An installed listener has no name to remove it
# by and an emitted event runs config handlers for something that never
# happened: same one-way change as an installer, same escape hatch.
for m in on off emit; do
	check "call refuses $m" "1" \
		"$(kc call client focused $m map x 2>&1 >/dev/null \
			| grep -c 'use eval')"
done

# --------------------------------------------------------------------------
# 5. Size, quoting, and the raw path.

# Past the fixed buffer the reply used to live in. A truncation here answers
# short with no error, so the length IS the assertion.
check "a reply past the old buffer arrives whole" "100000" \
	"$(kc eval 'return string.rep("x", 100000)' | tr -d '\n' | wc -c)"

# A join-on-space wire format loses this: the title would arrive as three
# arguments and the tag would be renamed to the first word alone.
kc tag rename code "two words here" > /dev/null
check "an argument holding spaces survives" "two words here" \
	"$(kc get tag "two words here" name)"
kc tag rename "two words here" code > /dev/null

# The tokenizer splits on every byte Lua calls whitespace, so the client has
# to quote on the same set: a carriage return out of a copied title would
# otherwise arrive as two arguments.
cr="$(printf 'a\rb')"
# The rename is allowed to fail loudly here: unquoted, the return splits the
# argument and the extra word lands on the verb's screen parameter. The
# read-back below is the assertion either way.
kc tag rename code "$cr" > /dev/null 2>&1 || true
check "an argument holding a carriage return survives" "$cr" \
	"$(kc get tag "$cr" name)"
kc tag rename "$cr" code > /dev/null 2>&1 || true

# A client that quits mid-reply leaves the peer gone under a write still in
# flight. The default SIGPIPE disposition takes the session down with it, so
# this asserts on the compositor still answering rather than on the reply: the
# dropped reply is expected, the dead compositor is the regression.
python3 - "$sock" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(b'return string.rep("x", 10000000)')
s.shutdown(socket.SHUT_WR)
time.sleep(0.05)
s.close()
PY
sleep 1
check "a client quitting mid-reply leaves the compositor up" "pong" "$(kc ping)"

# A peer is free to ask for megabytes and then not read them. If the reply is
# written in one blocking pass, the compositor sits inside that write with no
# input, no frames, and no Wayland dispatch for anyone until this peer drains.
# The timeout IS the assertion: without it the answer arrives, three seconds
# late, and the check passes over a frozen session.
python3 - "$sock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(b'return string.rep("x", 10000000)')
s.shutdown(socket.SHUT_WR)
time.sleep(3)
s.close()
PY
stall_pid=$!
sleep 0.5
check "a peer that will not read does not stall the session" "pong" \
	"$(KILN_SOCK="$sock" timeout 2 "$K" ping 2>/dev/null || true)"
wait "$stall_pid" 2>/dev/null || true

# Stringifying a result runs config-supplied code. The crossing into Lua is
# protected, so a raising __tostring cannot end the session either way; what
# is asserted here is the narrower contract, that one cell which cannot say
# what it is costs that cell and not the whole reply.
check "a raising __tostring degrades to a placeholder" "?	after" \
	"$(raw 'return setmetatable({}, { __tostring = function() error("boom") end }), "after"')"
check "and leaves the compositor up" "pong" "$(kc ping)"

check "raw Lua over the same socket is undisturbed" "42" "$(raw 'return 42')"

# The reply is assembled in Lua, so a config that never loads the library
# leaves nothing to assemble it. C answers with the failure rather than
# closing on silence, which is the difference between a broken config and a
# broken socket for whoever is debugging one.
bare="$work/bare.lua"
bare_sock="$work/bare.sock"
echo '-- no library' > "$bare"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 KILN_RC="$bare" \
	KILN_SOCK="$bare_sock" "$repo/build/kiln" > "$work/bare.log" 2>&1 &
bare_pid=$!
sleep 2
check "a config without the library still gets an answer" "1" \
	"$(KILN_SOCK="$bare_sock" "$repo/scripts/kiln-eval" 'return 1' \
		| grep -c '^ERROR: ')"
kill "$bare_pid" 2>/dev/null || true

check "raw multi-result is still tab joined" "1	2" "$(raw 'return 1, 2')"
check "raw error still carries its own prefix" "1" \
	"$(raw 'return nosuchglobal()' | grep -c '^ERROR:')"

# --------------------------------------------------------------------------
# 6. A real client, so the client verbs and the selectors have a subject.

wl="$(sed -n 's/.*WAYLAND_DISPLAY=\([^ ]*\).*/\1/p' "$log" | head -n1)"
WAYLAND_DISPLAY="$wl" "$repo/build/wl-toplevel" open cli.probe "Probe Window" &
probe_pid=$!
sleep 2

check "client list carries the probe" "1" \
	"$(kc client list | grep -c 'cli.probe')"
check "a selector resolves by handle" "cli.probe" \
	"$(kc get client 1 app_id)"
check "a selector resolves focused" "cli.probe" \
	"$(kc get client focused app_id)"
check "a field filter resolves" "Probe Window" \
	"$(kc get client app_id:cli.probe title)"
check "geometry reads back" "64" "$(kc get client focused width)"

check "a tiled client reads as tiled" "1" \
	"$(kc client list | grep -c 'tiled')"

kc set client focused floating true > /dev/null
check "set writes a property" "yes" "$(kc get client focused floating)"
check "and the state column follows the flag, not the geometry box" "1" \
	"$(kc client list | grep -c 'float')"

# Every string is truthy in Lua and so is 0, so the spellings that mean "off"
# would otherwise set the flag they were written to clear.
for word in 0 off false no disable; do
	kc client floating focused true > /dev/null
	check "client floating $word clears it" "no" \
		"$(kc client floating focused $word)"
done
kc set client focused floating 0 > /dev/null
check "set 0 clears a boolean property too" "no" \
	"$(kc get client focused floating)"
check "and a word that is neither is named" "1" \
	"$(kc client floating focused maybe 2>&1 >/dev/null \
		| grep -c 'is not on or off')"
kc call client focused toggle_fullscreen > /dev/null
check "call invokes a method" "yes" "$(kc get client focused fullscreen)"
kc call client focused toggle_fullscreen > /dev/null

kc client movetotag code > /dev/null
check "movetotag rehomes the client" "code" "$(kc get client focused tag)"

check "reflect lists the live property set" "1" \
	"$(kc reflect client | grep -c '^property  app_id')"
check "reflect lists methods" "1" \
	"$(kc reflect client | grep -c '^method    toggle_fullscreen')"

# --------------------------------------------------------------------------
# 7. Discovery: help and completion.

# The anti-drift assertion, and the reason the metadata lives on the registry
# rather than in a written document: a verb added without a spec is a verb
# nobody can learn from the tool, and nothing else in this suite would notice.
check "help answers for every verb commands lists" "0" \
	"$(for v in $(kc commands); do
		kc help "$v" > /dev/null 2>&1 || echo miss
	done | grep -c miss)"
check "and none of them is undocumented" "0" \
	"$(for v in $(kc commands); do kc help "$v"; done | grep -c undocumented)"

kc --json help > "$work/help.json"
check "--json help parses and carries args" "yes" \
	"$(python3 -c 'import json, sys
d = json.load(sys.stdin)
ok = d["status"] == "ok" and any("args" in v for v in d["result"])
print("yes" if ok else "no")' < "$work/help.json")"

# The shape a user is shown and the arity actually enforced come from one
# declaration, so every verb called one argument short must answer with its own
# derived usage. Driven off the spec rather than a copied string: a test that
# restates the usage text asserts only that someone typed it twice.
#
# Only verbs carrying a required argument are called, and only ever one short,
# so the arity check fires before the handler. Nothing here can run a verb,
# which is what makes it safe to sweep the whole surface.
python3 - "$work/help.json" > "$work/arity.txt" <<'PY'
import json, sys
for v in json.load(open(sys.argv[1]))["result"]:
    required = [a for a in v.get("args", []) if a.get("required")]
    if required:
        print("%s\t%d\t%s" % (v["name"], len(required), v["usage"]))
PY
arity_fail=0
arity_n=0
tab="$(printf '\t')"
while IFS="$tab" read -r name n usage; do
	arity_n=$((arity_n + 1))
	short=""
	i=1
	while [ "$i" -lt "$n" ]; do
		short="$short x"
		i=$((i + 1))
	done
	# shellcheck disable=SC2086
	out="$(kc $(echo "$name" | tr '.' ' ') $short 2>&1 > /dev/null || true)"
	case "$out" in
	*"$usage"*) ;;
	*)
		arity_fail=$((arity_fail + 1))
		printf '     arity: %s answered %s\n' "$name" "$out"
		;;
	esac
done < "$work/arity.txt"
check "a verb one argument short answers with its own derived usage" "0" \
	"$arity_fail"
# Guards the loop above against passing because it swept nothing.
check "and that swept a real share of the surface" "yes" \
	"$([ "$arity_n" -ge 20 ] && echo yes || echo no)"

# Completion answers from live state, so a name that exists is offered and a
# name that stops existing stops being offered. A hand-kept list passes the
# first half of this and fails the second.
kc tag add scratch > /dev/null
check "complete offers a live tag name" "1" \
	"$(kc complete 3 tag view '' | grep -cx scratch)"
kc tag delete scratch > /dev/null
check "and stops offering it once the tag is gone" "0" \
	"$(kc complete 3 tag view '' | grep -cx scratch)"

check "complete offers verb names before a verb resolves" "1" \
	"$(kc complete 1 '' | grep -cx tag)"

# The case that pays for the mechanism: the method set is the live one, and the
# three the call verb refuses are not offered. A static file cannot express
# either half, and a second hand-kept list would drift from the first.
kc reflect client | awk '$1 == "method" { print $2 }' \
	| grep -vxE 'on|off|emit' | sort > "$work/methods.txt"
kc complete 4 call client focused '' | sort > "$work/completed.txt"
check "complete offers exactly the callable methods reflect reports" "0" \
	"$(diff "$work/methods.txt" "$work/completed.txt" | grep -c '^[<>]')"

# The same hold on the other half. Without it, a new kind of property reaches
# reflect and completion misses it with nothing to say so.
kc reflect client | awk '$1 != "method" { print $2 }' | sort -u > "$work/props.txt"
kc complete 4 get client focused '' | sort > "$work/completed-props.txt"
check "complete offers exactly the properties reflect reports" "0" \
	"$(diff "$work/props.txt" "$work/completed-props.txt" | grep -c '^[<>]')"

# The two verbs whose requirement is conditional rather than positional keep
# their own guards, so the arity sweep above cannot cover them.
check "notify still names its own conditional usage" "1" \
	"$(kc notify 2>&1 > /dev/null | grep -c 'usage: notify')"
check "input at zero arguments still lists" "yes" \
	"$([ "$(kc input | wc -l)" -ge 11 ] && echo yes || echo no)"
kc input repeat_rate 33 > /dev/null
check "input at one and two arguments still gets and sets" "33" \
	"$(kc input repeat_rate)"

# The shim strips the client's own flags before computing the index. Left in,
# every candidate answers for the wrong argument position, which reads as
# completion offering the wrong thing rather than as anything failing.
if command -v bash > /dev/null 2>&1; then
	shim="$(KILN_SOCK="$sock" PATH="$repo/build:$PATH" bash -c '
		. "$1"
		COMP_WORDS=(kiln-client --json -s /some/path tag view "")
		COMP_CWORD=6
		_kiln_client
		printf "%s\n" "${COMPREPLY[@]}"
	' _ "$repo/completions/kiln-client.bash")"
	check "the bash shim survives the client's own flags" "1" \
		"$(echo "$shim" | grep -cx code)"
fi

# A candidate carries a name a user chose, so one holding a space has to stay
# one candidate. The compositor answers correctly either way; the shell is
# where the answer gets torn into fragments that name nothing.
kc tag rename code "two words" > /dev/null
check "complete answers a spaced name as one candidate" "1" \
	"$(kc complete 3 tag view '' | grep -cxF 'two words')"
if command -v bash > /dev/null 2>&1; then
	spaced="$(KILN_SOCK="$sock" PATH="$repo/build:$PATH" bash -c '
		. "$1"
		COMP_WORDS=(kiln-client tag view "")
		COMP_CWORD=3
		_kiln_client
		printf "%s\n" "${COMPREPLY[@]}"
	' _ "$repo/completions/kiln-client.bash")"
	# Quoted, so what the shell puts on the command line is one argument.
	check "and the bash shim keeps it whole" "1" \
		"$(echo "$spaced" | grep -cxF 'two\ words')"
fi
kc tag rename "two words" code > /dev/null

check "help names an unknown verb rather than listing its family" "1" \
	"$(kc help tag bogus 2>&1 > /dev/null | grep -c 'unknown command: tag bogus')"
check "complete offers a namespace's verbs for a verb-valued argument" "1" \
	"$(kc complete 3 help tag '' | grep -cx view)"

check "no bus errors" "0" "$(grep -c 'bus error' "$log")"

if [ "$fail" -eq 0 ]; then
	echo "cli-test: all green"
fi
exit "$fail"
