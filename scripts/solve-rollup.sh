#!/bin/sh
# Roll up the per-solve timing log: count, averages, and worst case.
#
#   scripts/solve-rollup.sh /tmp/kiln-prof.log
#
# Every solve logs one line (ui.c): commands, mutations, and the
# declare/solve/reconcile/total microsecond spans. The regression asserts are
# counters over these lines (idle = 0 solves, N marks = 1 solve, identical
# frame = 0 mutations); this prints the timing view.
set -eu
awk '/solve #/ {
	n++
	for (i = 1; i <= NF; i++) if (split($i, a, "=") == 2) {
		v = a[2] + 0
		if (a[1] == "declare") d += v
		else if (a[1] == "solve") s += v
		else if (a[1] == "reconcile") r += v
		else if (a[1] == "total") { t += v; if (v > tmax) tmax = v }
	}
}
END {
	if (n == 0) { print "no solves in log"; exit 1 }
	printf "%d solves  avg declare/solve/reconcile/total = %.0f/%.0f/%.0f/%.0f us  max total = %d us\n",
		n, d/n, s/n, r/n, t/n, tmax
}' "${1:?usage: solve-rollup.sh <log>}"
