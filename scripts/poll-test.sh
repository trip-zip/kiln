#!/bin/sh
# The poll battery: kiln.poll runs a command on an interval, holds its answer,
# and dirties only when that answer CHANGED.
#
#   scripts/poll-test.sh
#
# A poll is a LOOP, so what this battery is really testing is the re-arm: every
# leg below reads a value that only exists because kiln.spawn.watch armed itself
# again after its last child exited. That is worth stating because a broken
# re-arm does not raise anything. The value simply stops moving, and a bar built
# on it shows a stale number for the rest of the session.
#
# The interval is deliberately short and the legs deliberately sequential, so
# the loop re-arms many times over the run rather than once. A watch that runs
# once proves nothing here: the only existing watch coverage before this battery
# pinned its interval to 3600s ("runs exactly once during the test",
# scripts/pipe-test.sh), and a lost exit was invisible underneath it for exactly
# that reason.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-poll-test.XXXXXX)"
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

cat >"$rc" <<'EOF'
local kiln = require("kiln")
screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
end)
EOF

cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

set_lua() {
	eval_kiln "$1
core.dirty()" >/dev/null
	sleep 0.6
}

# =====================================================================
# 1. kiln.poll. The workhorse behind every bar widget that shows what a command
# says: run it, parse it, redraw when the answer CHANGED. The change test is the
# part worth having, because a poll that dirtied every interval would keep a
# screen re-solving forever over an answer that never moved.

printf 'first\n' > "$work/pollfile"
set_lua "POLLED = 0
POLL = require('kiln').poll {
  'cat $work/pollfile', every = 1,
  parse = function(lines) POLLED = POLLED + 1 return lines[1] end,
}"
sleep 2
check "the poll ran its command and parsed the answer" "first" \
	"$(eval_kiln 'return tostring(POLL.value)')"
check "and kept the run's raw lines" "first" \
	"$(eval_kiln 'return tostring(POLL.lines[1])')"

# parse is called once per RUN, not once per line: a command answering in three
# lines is one answer, and a parse that saw them one at a time could not tell
# which was the whole of it.
printf 'a\nb\nc\n' > "$work/pollfile"
sleep 2
check "a multi-line answer is one parse of all its lines" "a|b|c" \
	"$(eval_kiln 'return table.concat(POLL.lines, "|")')"

# The change test. Dirty marks are counted rather than inferred, because "it
# redrew" and "it redrew only when it had to" are different claims.
set_lua 'local real = core.dirty
DIRTIES = 0
core.dirty = function(...) DIRTIES = DIRTIES + 1 return real(...) end'
# Zeroed AFTER the patch is in and settled, and without dirtying: set_lua ends
# in a dirty of its own, which the counter would otherwise be counting.
eval_kiln 'DIRTIES = 0' >/dev/null
sleep 3
check "an unchanged answer dirties nothing" "0" \
	"$(eval_kiln 'return DIRTIES')"
printf 'moved\n' > "$work/pollfile"
sleep 2
check "and a changed one does" "true" \
	"$(eval_kiln 'return tostring(DIRTIES > 0)')"
check "with the new value in hand" "moved" \
	"$(eval_kiln 'return tostring(POLL.value)')"

# stop ends the re-arm. A poll is a loop, and a loop nothing can stop is a leak
# with a friendly name.
set_lua 'POLL:stop()'
printf 'ignored\n' > "$work/pollfile"
sleep 2
check "a stopped poll stops following the file" "moved" \
	"$(eval_kiln 'return tostring(POLL.value)')"

# Reload drops it, because a poll closes over the config that armed it. It rides
# spawn.watch, so this is the reset that was already wired rather than a second
# one to remember.
set_lua "POLL2 = require('kiln').poll { 'cat $work/pollfile', every = 1 }"
sleep 2
check "CONTROL: a second poll is following the file" "ignored" \
	"$(eval_kiln 'return tostring(POLL2.value)')"
set_lua 'require("kiln").reload()'
sleep 1
printf 'after-reload\n' > "$work/pollfile"
sleep 3
check "reload stopped it" "ignored" \
	"$(eval_kiln 'return tostring(POLL2.value)')"

# =====================================================================
# 2. The endurance leg, and it is the one that fails first if the exit path
# regresses. Everything above reads a VALUE, which a stalled loop can still
# answer with a stale one; this counts the runs themselves. A watch that stops
# re-arming stops here at whatever number it reached and never moves again, so
# the assertion is that the count is still climbing a long way in, not that it
# hit some exact figure the machine's load has a say in.

set_lua 'BEATS = 0
BEAT = require("kiln.spawn").watch({ "true" }, 0.2,
  { done = function() BEATS = BEATS + 1 end })'
sleep 6
early=$(eval_kiln 'return BEATS')
sleep 6
late=$(eval_kiln 'return BEATS')
check "a fast watch re-armed well past the handful that used to strand it" \
	"true" "$(eval_kiln "return tostring($early > 12)")"
check "and it was still re-arming six seconds later" "true" \
	"$(eval_kiln "return tostring($late > $early + 5)")"
# The exit is what re-arms, so an unreaped child is the failure underneath a
# stalled count. None may survive.
check "with no child left unreaped behind it" "0" \
	"$(ps --ppid "$kiln_pid" -o stat= | grep -c Z || true)"
set_lua 'BEAT.stop()'

# =====================================================================
printf '\n'
if [ "$fail" -eq 0 ]; then
	printf 'PASS\n'
else
	printf 'FAIL\n'
fi
exit "$fail"
