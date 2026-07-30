#!/bin/sh
# Zero-config measurement of every running kiln: RSS breakdown, timing
# rollup, and the latest solve gauges, per instance. The log path is
# recovered from each instance's stderr (fd 2), so nothing needs to be
# remembered or passed in; `make run`/`make dev`/`make headless` all
# launch with stderr pointed at a log file.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
pids="$(pgrep -x kiln || true)"
if [ -z "$pids" ]; then
	echo "measure: no kiln running" >&2
	exit 1
fi
for pid in $pids; do
	log="$(readlink "/proc/$pid/fd/2" 2>/dev/null || echo '?')"
	sock="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
		| sed -n 's/^KILN_SOCK=//p')"
	echo "==== kiln pid $pid  sock ${sock:-${XDG_RUNTIME_DIR:-/tmp}/kiln.sock (default)}  log $log"
	"$repo/scripts/rss-breakdown.sh" "$pid"
	case "$log" in
	/dev/*|'?')
		echo "(stderr is not a log file; launch via make run/dev/headless for timing + gauges)"
		;;
	/*)
		"$repo/scripts/solve-rollup.sh" "$log" || true
		grep 'solve #' "$log" | tail -1 \
			| sed 's/.*rnodes=/latest gauges: rnodes=/' || true
		;;
	esac
	echo
done
