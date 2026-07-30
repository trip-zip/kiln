#!/bin/sh
# Proof that a reposition after a resize re-sends the right size.
#
# client_reposition re-sends an X11 client's configure on a pure move (position
# changed, size unchanged), because X11 windows carry root coordinates. The
# hypothesis under test: the xwl_cfg_width/height cache it reads is dead, because
# wlroots caches X11 geometry optimistically at configure time, so
# xwl_surface->width/height already tracks the last configure. This test holds
# green before AND after the cache deletion:
#
#   1. two xterms tile under mwf 0.7 (unequal columns),
#   2. mwf drops to 0.5 (both clients RESIZE to equal columns),
#   3. the clients SWAP (equal tiles: a pure move, the reposition leg),
#   4. the X server's view (xwininfo against kiln's XWayland display) must
#      show exchanged positions with the post-resize sizes intact, agreeing
#      with the model's committed size for both clients.
#
# A stale or garbage size re-sent at step 3 shows up as an X-side size that
# disagrees with the model, or as sizes reverting to the mwf-0.7 columns.
# Headless: geometry only, no input needed. Clients are matched by WM_CLASS
# instance (xterm -name), never by title (the shell rewrites xterm titles).
#
# Needs: xterm, xdotool, xwininfo. Skips (exit 0, marked SKIP) without them.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
for bin in xterm xdotool xwininfo; do
	command -v "$bin" > /dev/null 2>&1 || {
		echo "SKIP: $bin not installed"; exit 0; }
done
work="$(mktemp -d /tmp/kiln-xwlrepo-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"

# Pin the config, the way prompt-test.sh does. Resolution order puts
# $XDG_CONFIG_HOME/kiln/rc.lua ahead of the repo copy, so an unpinned boot runs
# whatever config the user has installed rather than the one this battery
# asserts against, and the run silently stops testing what it says it tests.
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
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   %s (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s: expected %s got %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	XDG_CONFIG_HOME="$cfg" KILN_RC="$rc" \
	KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

xdisp=$(eval_kiln 'return os.getenv("DISPLAY") or ""')
[ -n "$xdisp" ] || { echo "SKIP: no XWayland in this build"; exit 0; }

count() {
	eval_kiln 'local k = 0
for _, s in ipairs(screen.all()) do
  for _, t in ipairs(s.tags) do k = k + #t.clients end
end
return k'
}
wait_count() { # n
	for _ in $(seq 1 30); do
		[ "$(count)" = "$1" ] && return 0
		sleep 1
	done
	return 1
}

# Sequential spawns: two clients racing the lazy X server's startup has
# dropped one on the floor; the first client brings the server up alone.
eval_kiln 'core.spawn("xterm -name xwlrepoA -e sleep 600")' > /dev/null
wait_count 1 || true
eval_kiln 'core.spawn("xterm -name xwlrepoB -e sleep 600")' > /dev/null
wait_count 2 || true
check "two X11 clients mapped" 2 "$(count)"
[ "$fail" = "0" ] || { grep -i "xwayland\|error" "$log" | head; exit 1; }

# The model's committed size for one client, by instance: "w h".
model_size() { # instance
	eval_kiln 'for _, s in ipairs(screen.all()) do
  for _, t in ipairs(s.tags) do
    for _, c in ipairs(t.clients) do
      if c.instance == "'"$1"'" then
        return c.width .. " " .. c.height
      end
    end
  end
end
return "absent"'
}

# The X server's view of the same window: "x y w h" from xwininfo.
x_box() { # instance
	id=$(DISPLAY="$xdisp" xdotool search --classname "^$1$" 2>/dev/null | head -1)
	[ -n "$id" ] || { echo "absent"; return; }
	DISPLAY="$xdisp" xwininfo -id "$id" | awk '
		/Absolute upper-left X/ { x = $NF }
		/Absolute upper-left Y/ { y = $NF }
		/Width:/  { w = $NF }
		/Height:/ { h = $NF }
		END { print x, y, w, h }'
}

agree() { # label instance
	m=$(model_size "$2")
	x=$(x_box "$2" | cut -d' ' -f3-4)
	check "$1: model size == X size ($2)" "$m" "$x"
}

# One mutation per eval (evals coalesce to one solve); a beat after each for
# the X round trip.
eval_kiln 'screen.all()[1].tags[1].master_width_factor = 0.7' > /dev/null
sleep 2
agree "after mwf 0.7" xwlrepoA
agree "after mwf 0.7" xwlrepoB
wa07=$(x_box xwlrepoA | cut -d' ' -f3)
wb07=$(x_box xwlrepoB | cut -d' ' -f3)
check "mwf 0.7 columns are unequal" 1 \
	"$([ "$wa07" != "$wb07" ] && echo 1 || echo 0)"

eval_kiln 'screen.all()[1].tags[1].master_width_factor = 0.5' > /dev/null
sleep 2
agree "after resize to 0.5" xwlrepoA
agree "after resize to 0.5" xwlrepoB
a_box5=$(x_box xwlrepoA)
b_box5=$(x_box xwlrepoB)
a_pos5=$(echo "$a_box5" | cut -d' ' -f1-2)
b_pos5=$(echo "$b_box5" | cut -d' ' -f1-2)
a_size5=$(echo "$a_box5" | cut -d' ' -f3-4)
b_size5=$(echo "$b_box5" | cut -d' ' -f3-4)
check "0.5 columns differ in position" 1 \
	"$([ "$a_pos5" != "$b_pos5" ] && echo 1 || echo 0)"
check "0.5 columns are equal in size" "$a_size5" "$b_size5"

# Equal tiles swapping is a pure move: no size change, so the reconciler sends
# no configure and the reposition leg alone re-sends geometry. The re-sent
# size must be the post-resize one.
eval_kiln 'local cs = screen.all()[1].tags[1].clients
cs[1]:swap(cs[2])' > /dev/null
sleep 2

check "swap exchanged positions (A)" "$b_pos5" \
	"$(x_box xwlrepoA | cut -d' ' -f1-2)"
check "swap exchanged positions (B)" "$a_pos5" \
	"$(x_box xwlrepoB | cut -d' ' -f1-2)"
check "A kept its post-resize size" "$a_size5" \
	"$(x_box xwlrepoA | cut -d' ' -f3-4)"
check "B kept its post-resize size" "$b_size5" \
	"$(x_box xwlrepoB | cut -d' ' -f3-4)"
agree "after pure-move swap" xwlrepoA
agree "after pure-move swap" xwlrepoB

eval_kiln 'core.quit()' > /dev/null 2>&1 || true
[ "$fail" = "0" ] && echo PASS
exit "$fail"
