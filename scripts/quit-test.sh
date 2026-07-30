#!/bin/sh
# The clean-exit battery: core.quit() must EXIT, not abort.
#
#   scripts/quit-test.sh
#
# Every manager listener kiln attaches to a wl_display-scoped global has to be
# detached before wl_display_destroy; wlroots asserts those listener lists are
# empty and aborts the process if one is still attached. Two of them never were
# (new_pointer_constraint, request_set_shape), so every core.quit() went to
# SIGABRT with a core dump instead of exiting 0.
#
# WHY THIS BATTERY EXISTS AT ALL. The abort was invisible for the whole life of
# the project because no battery ever looked at the exit status: they all end in
# `eval_kiln 'core.quit()' || true` and then a `kill` from the cleanup trap, which
# cannot tell a clean exit from an abort. This battery is the one that looks. It
# is deliberately narrow: boot, quit, WAIT, read $?. That single assert is what
# would have caught those two leaked listeners, and it is what catches the next
# manager that lands without its removal.
#
# Three runs, because an abort at teardown is a race in principle (the assert
# fires on whatever list is non-empty first, and one masked the other here:
# the pointer-constraints assert hid the cursor-shape one behind it until it was
# fixed). One green run does not prove much; three do.
#
# Boots the real repo rc.lua, the same config rc-test.sh uses, so the teardown
# path runs against a fully built desktop rather than an empty one.
#
# Needs: nothing beyond a built ./build/kiln.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
rc="$repo/kilnrc.lua"
work="$(mktemp -d /tmp/kiln-quit-test.XXXXXX)"
kiln_pid=""

cleanup() {
	[ -n "$kiln_pid" ] && kill "$kiln_pid" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

fail=0
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   %s\n     (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s\n     expected %s\n     got      %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

# =====================================================================
# One run: boot headless, quit over IPC, and READ THE EXIT STATUS.

run_once() { # n
	n="$1"
	sock="$work/kiln$n.sock"
	log="$work/kiln$n.log"

	# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
	# orphans the compositor to init (the capture-test.sh rule).
	cd "$repo"
	# XDG_CONFIG_HOME isolated: the config picks its palette from a theme file
	# under it, so without this the run depends on whose theme is selected.
	WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 XDG_CONFIG_HOME="$work/config" \
		KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
	kiln_pid=$!
	sleep 2

	check "run $n: the compositor booted" "yes" \
		"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"

	KILN_SOCK="$sock" "$repo/scripts/kiln-eval" 'core.quit()' >/dev/null 2>&1 || true

	# The assert this battery exists for. `wait` reaps the pid and reports the
	# real status: 0 on a clean exit, 134 (128 + SIGABRT) on a leaked listener.
	# set -e would kill the script on a non-zero wait, so the status is captured
	# through an || branch rather than let to propagate.
	status=0
	wait "$kiln_pid" 2>/dev/null || status=$?
	# Reaped: clear it so the cleanup trap does not kill an unrelated pid that
	# the OS may since have handed this number to.
	kiln_pid=""

	check "run $n: core.quit() exits 0 (not 134/SIGABRT)" "0" "$status"

	# The assert names itself in the log when it fires; catching the string as
	# well as the status says WHICH failure happened when this goes red.
	check "run $n: no wlroots assertion at teardown" "0" \
		"$(grep -cE 'Assertion|handle_display_destroy' "$log" || true)"
}

run_once 1
run_once 2
run_once 3

if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
