#!/bin/sh
# The reload battery: kiln.reload() + core.replay() re-run the config in the
# live process, with no restart and no client lost.
#
#   scripts/reload-test.sh
#
# The contract in one sentence: re-run the config file in the live process and
# every fact the new file states takes, while every client that was already on
# screen stays the same client. So this battery boots a COPY of the real config,
# edits the copy the way a user edits their config (a sed on the bar height and
# on the theme accent), reloads, and asserts both halves: the changed values are
# visible in the next declare, and the three foot clients are still there, still
# the same handles, tagged once and barred once rather than doubled.
#
# WHY A COPY, NOT THE REPO kilnrc.lua: the seds must not touch the tree. The
# copy under the workdir scopes the edit to the config.
#
# XDG_CONFIG_HOME IS ISOLATED because the config picks its palette from a theme
# file under it. Without that, the accent this battery seds for is whichever
# theme the person running it happens to have selected.
#
# REPLAY IS ASYNC, SO THE READBACK POLLS. core.replay() enqueues synthetic
# client::map events on the one origin queue; they drain on an idle callback
# after the eval returns. A bare assert right after the reload eval races the
# drain, so the mapped count is polled up to ~5s before it is judged.
#
# NAMED LIMITATIONS, asserted nowhere because they are the design:
# placement resets (unruled clients re-tag onto the focused screen's selected
# tag and floats re-cascade), an xdg-minimized client replays unminimized, and
# the last-drained client takes focus.
#
# HARNESS TRAPS RESPECTED (a violation would kill the live session):
# - A private KILN_SOCK under a mktemp workdir, never the default socket.
# - Kill only the saved pids in the EXIT trap; never pkill/pgrep -f.
# - One eval per assert: mutations in one eval coalesce to one solve.
# - Existence is asserted through core.hits, never core.box (Clay's element
#   hashmap is persistent, so a stale id keeps answering). The live() helper is
#   copied from rc-test.sh.
# - Element ids are plain strings, never { string, string }.
#
# Needs: foot.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-reload-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
rc="$work/rc.lua"
kiln_pid=""
f1=""
f2=""
f3=""

cleanup() {
	for p in $f1 $f2 $f3 $kiln_pid; do
		kill "$p" 2>/dev/null || true
	done
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

live() { # lua-id-expr
	eval_kiln "
local s = screen.all()[1]
local id = $1
local b = core.box(id)
if b == nil then return 'absent' end
for _, h in ipairs(core.hits(s.name, b.x + b.width / 2, b.y + b.height / 2)) do
  local want = type(id) == 'table' and id[1] or id
  if h.name == want then return 'live' end
end
return 'absent'"
}

# The mapped clients on screen 1, deduped across tags: the count, and the sorted
# handle set. The set is the proof that a reload REPLAYED the clients rather than
# losing and respawning them.
mapped_lua='local s, seen, o = screen.all()[1], {}, {}
for _, t in ipairs(s.tags) do
  for _, c in ipairs(t.clients) do
    if not seen[c] and c.mapped then seen[c] = true; o[#o+1] = c.handle end
  end
end
table.sort(o)
return table.concat(o, " ")'
mapped_set() { eval_kiln "$mapped_lua"; }
mapped_count() {
	eval_kiln "$(printf '%s' "$mapped_lua" |
		sed 's/^return table.concat(o, " ")$/return #o/')"
}

# Is the bar under (5, y)? The bar is declared with a plain "bar" id; a point
# inside it names it, a point below it does not. This is the hits-visible leg of
# "a changed config value is visible in the next declare": core.hits carries only
# { name, index } and no colors, so geometry is what a probe can see.
bar_at() { # y
	eval_kiln "local s = screen.all()[1]
for _, h in ipairs(core.hits(s.name, 5, $1)) do
  if h.name == 'bar' then return 'bar' end
end
return 'no-bar'"
}

# =====================================================================
# Boot a COPY of the real config headless and let its screen.on("added") build
# the tags and the bar.

cp "$repo/kilnrc.lua" "$rc"

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 XDG_CONFIG_HOME="$work/config" \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

check "the compositor booted" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"

wl_disp=$(sed -n 's/.*Running Wayland compositor on WAYLAND_DISPLAY=//p' "$log" | head -1)
WAYLAND_DISPLAY="$wl_disp" foot >"$work/foot1.log" 2>&1 &
f1=$!
WAYLAND_DISPLAY="$wl_disp" foot >"$work/foot2.log" 2>&1 &
f2=$!
WAYLAND_DISPLAY="$wl_disp" foot >"$work/foot3.log" 2>&1 &
f3=$!
sleep 4

# =====================================================================
# The pre-reload world: what the reload has to preserve, and what it has to
# change. Recorded here so every post assert compares against a fact, not a
# hardcode.

check "three clients mapped before the reload" "3" "$(mapped_count)"
handles_before=$(mapped_set)
check "the taglist declared all five tags" "dev web chat files media" \
	"$(eval_kiln 'local o = {}
for _, t in ipairs(screen.all()[1].tags) do o[#o+1] = t.name end
return table.concat(o, " ")')"
check "one bar on the screen" "1" "$(eval_kiln 'return #screen.all()[1].bars')"
# The bar's center is under the floated clock, so probe its top edge.
check "the bar is declared" "true" \
	"$(eval_kiln 'local s = screen.all()[1]
for _, h in ipairs(core.hits(s.name, 2, 2)) do
  if h.name == "bar" then return "true" end
end
return "false"')"
check "the bar is 28 tall, so (5, 40) is below it" "no-bar" "$(bar_at 40)"
check "the theme accent is the config's" "#cba6f7" \
	"$(eval_kiln 'return require("kiln").theme.accent')"
keys_before=$(eval_kiln 'local n = 0
for _ in pairs(require("kiln.state").keys) do n = n + 1 end
return n')
check "the key registry is populated" "true" \
	"$([ "$keys_before" -gt 0 ] && echo true || echo false)"

# A REAL bus-error assert, counted in Lua rather than grepped from the log.
# Bus.on_error is a plain field on the shared Bus table, and reload resets only
# error_bus.listeners, so this wrapper is still installed on the far side of the
# reload and counts anything the teardown, the re-run config, or the replayed
# maps raise. The log cannot answer this: on_error PRINTS, stdout is a file here
# so it is block-buffered, and the process aborts at quit without flushing it.
eval_kiln 'local Bus = require("kiln.bus")
reload_errors = 0
local prev = Bus.on_error
Bus.on_error = function(sig, err)
  reload_errors = reload_errors + 1
  return prev(sig, err)
end' >/dev/null

# =====================================================================
# Edit the config the way a user does, then reload. Both patterns are unique
# within the config: the bar cfg states its height as `h = th.bar_height`, so
# the edit swaps the theme value for a literal 48; `#cba6f7` is the accent of
# the palette an isolated XDG_CONFIG_HOME selects.

sed -i 's/h = th.bar_height/h = 48/' "$rc"
sed -i 's/#cba6f7/#ff2222/' "$rc"
check "the copy's bar height was edited" "1" "$(grep -c 'h = 48' "$rc")"
check "the copy's accent was edited" "1" "$(grep -c '#ff2222' "$rc")"

eval_kiln 'require("kiln").reload()' >/dev/null

# Poll for the replay drain: the synthetic maps land on an idle callback after
# the eval returned, so an immediate assert would race them.
i=0
while [ "$i" -lt 20 ]; do
	[ "$(mapped_count)" = "3" ] && break
	i=$((i + 1))
	sleep 0.25
done
# The model is back, but the SCENE is one frame behind it: the last replayed map
# rebuilt the client objects, and the declare that puts their chrome back on
# screen has not run yet. Every hits assert below reads the last solve, so settle
# one frame first, the way set_lua does in rc-test.sh.
eval_kiln 'core.dirty()' >/dev/null
sleep 0.6

# =====================================================================
# The clients survived, as the SAME clients: not killed, not respawned, not
# doubled.

alive=0
for p in $f1 $f2 $f3; do
	kill -0 "$p" 2>/dev/null && alive=$((alive + 1))
done
check "all three foot clients are still running" "3" "$alive"
check "three clients mapped after the reload (not 0, not 6)" "3" "$(mapped_count)"
check "and they are the same handles, replayed not respawned" "$handles_before" \
	"$(mapped_set)"
first_handle=$(printf '%s' "$handles_before" | cut -d' ' -f1)
# A tasklist row cannot be probed with core.hits here: the reload reorders the
# rows, so no fixed point is tied to THIS handle's row. The press table is the
# sound probe instead, and it is not the stale-box trap core.hits exists to
# avoid: init.lua resets state.presses at the top of each declare and stashes
# it at the end, so a key for this row means this row was declared in the LAST
# declare.
check "the tasklist declared a row for a pre-reload client" "live" \
	"$(eval_kiln "local p = require('kiln.state').screen_presses[screen.all()[1].name] or {}
for k in pairs(p) do
  if k:find('^on_press:task:$first_handle#') then return 'live' end
end
return 'absent'")"

# =====================================================================
# The config's own state was rebuilt once, not stacked: the re-run rc registers
# its handlers onto buses that were reset, and its screen.on("added") runs
# against a screen whose tags and bars were dropped.

check "still five tags (not ten)" "5" \
	"$(eval_kiln 'return #screen.all()[1].tags')"
check "still one bar (ui.bar appends, so a stale list would double it)" "1" \
	"$(eval_kiln 'return #screen.all()[1].bars')"
check "the key registry is the same size (not doubled)" "$keys_before" \
	"$(eval_kiln 'local n = 0
for _ in pairs(require("kiln.state").keys) do n = n + 1 end
return n')"

# =====================================================================
# The edited values took: the accent through the public theme table, the bar
# height through what the next declare actually put on screen.

check "the new accent is live" "#ff2222" \
	"$(eval_kiln 'return require("kiln").theme.accent')"
check "the bar is 48 tall now, so (5, 40) is inside it" "bar" "$(bar_at 40)"

# =====================================================================
# The compositor stayed clean across the whole cycle. Two sources, because they
# come out of different pipes: the Lua bus errors are counted in-process (the
# wrapper installed above), and the C-side noise is grepped from the log, where
# wlr_log puts it on unbuffered stderr. A doubled declare lands in the second
# one: two of the old config's taglists declaring the same ids is a Clay
# duplicate-id error, which is what a missing bus reset actually looks like.

check "no Lua bus error anywhere in the reload" "0" \
	"$(eval_kiln 'return reload_errors')"
noise=$(grep -cE 'clay error|tree==scene:|DUPLICATE' "$log" || true)
check "no clay error, no tree/scene divergence, no duplicate ids" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
