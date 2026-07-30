#!/bin/sh
# The image/text cache residency soak: render N distinct images and strings,
# drop them, and assert residency is bounded, not monotonic. Headless,
# self-contained.
#
#   scripts/cache-soak.sh [budget_mb] [n_images]
#
# PASS criteria:
#   - after shrinking the declared image set, images_kb <= budget
#   - after dropping everything, raster_kb returns to 0
#   - three rounds of distinct strings hold raster_kb flat
#   - an identical re-declare performs 0 mutations
#   - RSS is bounded, not monotonic: after a warmup cycle (which pays
#     one-time GL texture-pool, JIT, and allocator costs), two further
#     full load/drop cycles must hold RSS flat
set -eu
budget="${1:-8}"
n="${2:-100}"
steady_slack_kb="${KILN_SOAK_STEADY_SLACK_KB:-8192}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-cache-soak.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
trap 'kill $kiln_pid 2>/dev/null; rm -rf "$work"' EXIT

python3 -c "
for i in range(1, $n + 1):
    w = h = 256
    px = bytes((i * 37 % 256, i * 91 % 256, i * 13 % 256)) * (w * h)
    with open(f'$work/img-{i}.ppm', 'wb') as f:
        f.write(b'P6\n%d %d\n255\n' % (w, h)); f.write(px)
"

WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 KILN_SOCK="$sock" \
	KILN_RC="$repo/scripts/soak-cache.lua" KILN_IMAGE_BUDGET_MB="$budget" \
	"$repo/build/kiln" > "$log" 2>&1 &
kiln_pid=$!
sleep 2

ev() { KILN_SOCK="$sock" "$repo/scripts/kiln-eval" "$1" > /dev/null; sleep 0.6; }
gauge() { grep 'solve #' "$log" | tail -1 | sed 's/.*rnodes=/rnodes=/'; }
field() { gauge | tr ' ' '\n' | sed -n "s/^$1=//p"; }
rss_kb() { awk '/^VmRSS:/ { print $2 }' "/proc/$kiln_pid/status"; }

ev "SOAK_DIR = '$work'; SOAK_MODE = 'images'; SOAK_N = $n; core.dirty()"
peak_img=$(field images_kb)
ev "SOAK_N = 10; core.dirty()"
shrunk_img=$(field images_kb)
ev "SOAK_MODE = 'none'; core.dirty()"
dropped_raster=$(field raster_kb)
ev "SOAK_MODE = 'text'; SOAK_N = 200; SOAK_ROUND = 1; core.dirty()"
r1=$(field raster_kb)
ev "SOAK_ROUND = 2; core.dirty()"
r2=$(field raster_kb)
ev "SOAK_ROUND = 3; core.dirty()"
r3=$(field raster_kb)
ev "core.dirty()"
idle_muts=$(grep 'solve #' "$log" | tail -1 | sed 's/.*, \([0-9]*\) mutations.*/\1/')
ev "SOAK_MODE = 'none'; core.dirty()"
rss_warm=$(rss_kb)

# Two more full cycles on the warmed instance: bounded means flat here.
cycle=0
while [ "$cycle" -lt 2 ]; do
	cycle=$((cycle + 1))
	ev "SOAK_MODE = 'images'; SOAK_N = $n; core.dirty()"
	ev "SOAK_MODE = 'text'; SOAK_N = 200; SOAK_ROUND = $((cycle + 3)); core.dirty()"
	ev "SOAK_MODE = 'none'; core.dirty()"
done
rss_steady=$(rss_kb)

fail=0
check() { # check <name> <ok> <detail>
	if [ "$2" = 1 ]; then echo "PASS  $1  ($3)"; else echo "FAIL  $1  ($3)"; fail=1; fi
}
check "live set exempt over budget" "$((peak_img > budget * 1024 ? 1 : 0))" \
	"declared ${n}: images_kb=$peak_img > budget $((budget * 1024))"
check "eviction to budget on shrink" "$((shrunk_img <= budget * 1024 ? 1 : 0))" \
	"images_kb=$shrunk_img <= $((budget * 1024))"
check "rasters swept on drop" "$((dropped_raster == 0 ? 1 : 0))" \
	"raster_kb=$dropped_raster"
check "raster flat across distinct-string rounds" \
	"$(( (r1 == r2 && r2 == r3 && r1 > 0) ? 1 : 0 ))" "rounds=$r1/$r2/$r3 kB"
check "identical frame is 0 mutations" "$((idle_muts == 0 ? 1 : 0))" \
	"mutations=$idle_muts"
check "RSS bounded, not monotonic" \
	"$(( rss_steady - rss_warm <= steady_slack_kb ? 1 : 0 ))" \
	"post-warmup ${rss_warm}kB, after 2 more cycles ${rss_steady}kB, slack ${steady_slack_kb}kB"

exit $fail
