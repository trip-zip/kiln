#!/bin/sh
# The async-spawn battery: core.spawn_pipe + kiln.spawn.watch, the fact every
# status widget rides.
#
#   scripts/pipe-test.sh
#
# Pure headless, no client needed. A spawned child's stdout/stderr reach Lua as
# raw spawn::out chunks and one spawn::exit; the line split and the watch re-arm
# are Lua's. This battery arms pipes from a synthetic rc and reads the collected
# results back over IPC.
#
# HARNESS TRAPS RESPECTED (a violation would kill the live session):
# - A private KILN_SOCK under a mktemp workdir, never the default socket.
# - Kill only the saved $kiln_pid in the EXIT trap; never pkill/pgrep -f.
# - One eval per arm, a sleep before the readback: mutations in one eval coalesce
#   to one solve, and a pipe needs the loop to turn between arm and result.
# - Existence is asserted through core.hits, never core.box (Clay's element
#   hashmap is persistent). The live() helper is copied from rc-test.sh.
# - Element ids are plain strings ("probe:hello"), never { string, string }.
#
# The killed-child arm self-kills (kill -9 $$): deterministic, no pid matching, no
# pkill exposure. 137 = 128 + SIGKILL, the shell convention C reports.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-pipe-test.XXXXXX)"
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

# The rc under test: a bar whose one widget is a box keyed by the watched line, so
# a delivered line both reads back as a value and repaints the scene; plus arm_*
# functions the test calls to exercise the split, the exit code, and the two-fd
# split. All escaping is contained in this quoted heredoc (one Lua layer), so the
# test evals below stay plain. Public API only.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
local ui = kiln.ui
local th = kiln.theme

probe = { line = "" }

-- printf 'a\nb' writes one complete line "a" and a trailing unterminated "b";
-- the split delivers "a", and the flush at exit delivers "b".
function arm_split()
	SPLIT_LINES = {}
	SPLIT_EXIT = nil
	kiln.spawn.pipe("printf 'a\nb'", {
		on_line = function(l) SPLIT_LINES[#SPLIT_LINES + 1] = l end,
		on_exit = function(c) SPLIT_EXIT = c end,
	})
end

function arm_kill()
	KILLED = nil
	kiln.spawn.pipe("kill -9 $$", {
		on_exit = function(c) KILLED = c end,
	})
end

-- echo err 1>&2: the chunk arrives on fd 2 (on_err), and on_line must never see
-- it. Two fds, two facts, no merge.
function arm_err()
	ERR_CHUNK = ""
	ERR_ONLINE = 0
	kiln.spawn.pipe("echo err 1>&2", {
		on_err = function(chunk) ERR_CHUNK = ERR_CHUNK .. chunk end,
		on_line = function(l) ERR_ONLINE = ERR_ONLINE + 1 end,
	})
end

screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
	ui.bar(s, { edge = "top", h = 28, color = th.bg }, function()
		ui.box({
			id = "probe:" .. probe.line,
			w = 60, h = 20, color = th.accent, align = "center",
		}, function() ui.text(probe.line, { size = 12 }) end)
		ui.spacer()
	end)
	-- Interval 3600s: runs exactly once during the test.
	kiln.spawn.watch("echo hello", 3600, function(line)
		probe.line = line
		kiln.dirty()
	end)
end)
EOF

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

check "the compositor booted" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"

# live: is this id declared RIGHT NOW? core.hits names what the last solve put
# under a point, so an id that stopped being declared stops being named.
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

# =====================================================================
# 2. kiln.spawn.watch delivered the line (the echo ran once at boot).
check "watch delivered the child's line" "hello" \
	"$(eval_kiln 'return probe.line')"

# 3. and the line repainted the bar (the box id carries it).
check "the delivered line repainted the bar" "live" "$(live '"probe:hello"')"

# =====================================================================
# 4. The splitter and the exit path: one complete line, one flushed trailing
# partial, then exit 0.
eval_kiln 'arm_split()' >/dev/null
sleep 0.6
check "the split delivered both lines (trailing partial flushed)" "a,b" \
	"$(eval_kiln 'return table.concat(SPLIT_LINES, ",")')"
check "the child exited with code 0" "0" \
	"$(eval_kiln 'return SPLIT_EXIT')"

# =====================================================================
# 5. A killed child delivers spawn::exit with the signal code.
eval_kiln 'arm_kill()' >/dev/null
sleep 0.6
check "a killed child reports 128 + SIGKILL" "137" \
	"$(eval_kiln 'return KILLED')"

# =====================================================================
# 6. Two fds, two facts: stderr reaches on_err, never on_line.
eval_kiln 'arm_err()' >/dev/null
sleep 0.6
check "stderr chunk reached on_err" "true" \
	"$(eval_kiln 'return tostring(ERR_CHUNK:find("err") ~= nil)')"
check "and on_line never saw the stderr chunk" "0" \
	"$(eval_kiln 'return ERR_ONLINE')"

# =====================================================================
# The compositor stayed clean: no Lua error on the bus.
#
# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's
# pcall, so this leg MUST go red under it.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

noise=$(grep -cE "error in '|DUPLICATE" "$log" || true)
check "no bus errors, no duplicate ids" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
