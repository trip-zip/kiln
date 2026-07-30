#!/bin/sh
# Headless native-lock state machine check. Boots kiln headless and drives
# core.lock/authenticate/unlock over IPC, asserting the C-enforced gate.
#
#   scripts/lock-test.sh
#
# The full authenticate->unlock leg needs the PAM test stub, so build with
#   meson configure build -Dpam=disabled && ninja -C build
# before running. With real PAM the script still checks everything that holds
# without a valid login (lock engages, unlock refused without auth, a wrong
# password is refused, a second lock is refused) and skips the stub-only leg.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-lock-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"

# Pin the config, the way prompt-test.sh does. Resolution order puts
# $XDG_CONFIG_HOME/kiln/rc.lua ahead of the repo copy, so an unpinned boot runs
# whatever config the user has installed rather than the one this battery
# asserts against, and the run silently stops testing what it says it tests.
rc="$repo/kilnrc.lua"
cfg="$work/config"
mkdir -p "$cfg"
trap 'kill $kiln_pid 2>/dev/null; rm -rf "$work"' EXIT

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
	KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

fail=0
eval_kiln() { KILN_SOCK="$sock" "$repo/scripts/kiln-eval" "$1"; }
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   %s (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s: expected %s got %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

check "not locked at boot"        false "$(eval_kiln 'return tostring(require("kiln").lockscreen.active)')"
check "core.lock engages"          true "$(eval_kiln 'return tostring(core.lock())')"
sleep 0.3
check "native lockscreen active"   true "$(eval_kiln 'return tostring(require("kiln").lockscreen.active)')"
check "second lock refused"       false "$(eval_kiln 'return tostring(core.lock())')"
check "unlock refused pre-auth"   false "$(eval_kiln 'return tostring(core.unlock())')"
check "wrong password refused"    false "$(eval_kiln 'return tostring(core.authenticate("definitely-wrong"))')"
check "unlock still refused"      false "$(eval_kiln 'return tostring(core.unlock())')"

# Stub-only: the fixed test password authenticates and opens the gate.
if [ "$(eval_kiln 'return tostring(core.authenticate("kilntest"))')" = "true" ]; then
	check "stub password unlocks"      true "$(eval_kiln 'return tostring(core.unlock())')"
	sleep 0.3
	check "inactive after unlock"     false "$(eval_kiln 'return tostring(require("kiln").lockscreen.active)')"
	check "unlock idempotent"          true "$(eval_kiln 'return tostring(core.unlock())')"
else
	printf 'skip stub password leg (real PAM build; use -Dpam=disabled)\n'
	check "unlock refused (real PAM)" false "$(eval_kiln 'return tostring(core.unlock())')"
fi

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
