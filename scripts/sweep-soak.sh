#!/bin/sh
# The RSS regression soak: boot headless with the real config and a client set,
# drive a 100-tag-switch sweep, then assert the RSS ceiling and report the
# tracked metrics (live rnodes, buffers per solve, post-soak RSS). Run from
# anywhere; foot(1) provides the clients.
#
#   scripts/sweep-soak.sh [switches]
#
# KILN_RSS_CEILING_MB sets the ceiling (default 250). Headless still renders on
# the DRM node, so most of that RSS is the GPU driver's shared library pages
# rather than kiln's own memory, and the figure moves with the host's driver.
# Retained rasters scale with output count and resolution, so a session with
# more or larger outputs than this one output needs the ceiling raised.
set -eu
switches="${1:-100}"
ceiling_mb="${KILN_RSS_CEILING_MB:-250}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-sweep-soak.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"

# Pin the config, the way prompt-test.sh does. Resolution order puts
# $XDG_CONFIG_HOME/kiln/rc.lua ahead of the repo copy, so an unpinned boot runs
# whatever config the user has installed rather than the one this battery
# asserts against, and the run silently stops testing what it says it tests.
rc="$repo/kilnrc.lua"
cfg="$work/config"
mkdir -p "$cfg"
trap 'kill $kiln_pid $c1 $c2 $c3 2>/dev/null; rm -rf "$work"' EXIT

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
	KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2
disp=$(sed -n 's/.*Running Wayland compositor on WAYLAND_DISPLAY=//p' "$log" | head -1)
WAYLAND_DISPLAY="$disp" foot > /dev/null 2>&1 & c1=$!
WAYLAND_DISPLAY="$disp" foot > /dev/null 2>&1 & c2=$!
WAYLAND_DISPLAY="$disp" foot > /dev/null 2>&1 & c3=$!
sleep 3

# The compositor may run under a wrapper; resolve the real pid off the socket
# owner: the newest process whose comm is kiln.
kiln_real=$(pgrep -nx kiln)
rss_kb() { awk '/^VmRSS:/ { print $2 }' "/proc/$kiln_real/status"; }
ev() { KILN_SOCK="$sock" "$repo/scripts/kiln-eval" "$1"; }

ntags=$(ev 'return #screen.all()[1].tags')
rss0=$(rss_kb)
solves0=$(grep -c 'solve #' "$log")

i=0
while [ "$i" -lt "$switches" ]; do
	i=$((i + 1))
	ev "screen.all()[1].tags[$(( (i % ntags) + 1 ))]:view()" > /dev/null
	sleep 0.05
done
sleep 1

rss1=$(rss_kb)
solves1=$(grep -c 'solve #' "$log")
last=$(grep 'solve #' "$log" | tail -1 | sed 's/.*rnodes=/rnodes=/')

echo "== sweep-soak: $switches tag switches over $ntags tags, 3 foot clients"
echo "solves: $((solves1 - solves0)) during sweep ($solves0 at start)"
echo "metrics: $last"
echo "rss: ${rss0} kB before, ${rss1} kB after"
"$repo/scripts/solve-rollup.sh" "$log"

fail=0
if [ "$rss1" -le "$((ceiling_mb * 1024))" ]; then
	echo "PASS  RSS ceiling  (${rss1} kB <= ${ceiling_mb} MB)"
else
	echo "FAIL  RSS ceiling  (${rss1} kB > ${ceiling_mb} MB)"
	fail=1
fi
if [ "$((solves1 - solves0))" -ge "$((switches / 2))" ]; then
	echo "PASS  sweep drove solves  ($((solves1 - solves0)) >= $((switches / 2)))"
else
	echo "FAIL  sweep drove solves  ($((solves1 - solves0)) < $((switches / 2)))"
	fail=1
fi
exit $fail
