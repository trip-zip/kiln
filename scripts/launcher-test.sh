#!/bin/sh
# The launcher battery: the app launcher as stdlib, and the attach that used to
# be impossible.
#
#   scripts/launcher-test.sh
#
# The launcher is a prompt plus a result list, and the list belongs UNDER the
# prompt. Attaching it to the prompt's element was a Clay abort on the first
# open, because a float whose target has never been declared is an error and the
# config's list was declared BEFORE the runtime declared the prompt. So the
# config summed the prompt's height out of theme parts instead, which is exactly
# the layout arithmetic this project exists to not write. The declare registry
# runs after the prompt, so the attach resolves on the first frame both exist,
# and the sum is gone.
#
# The leg that matters most is therefore the dullest one: after the first open,
# the compositor is still answering. A regression here does not fail an
# assertion, it takes the process down.
#
# The .desktop scan is made hermetic with a private XDG_DATA_HOME, so what the
# battery asserts about matching and ordering is about the launcher and not
# about whatever is installed on the machine running it.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-launcher-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
rc="$work/rc.lua"
apps="$work/share/applications"
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

# Three entries: two that must show and one that must not, so "it lists the
# apps" and "it honours NoDisplay" are one scan rather than two.
mkdir -p "$apps"
cat >"$apps/aardvark.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Aardvark
Exec=touch $work/launched-aardvark %U
EOF
cat >"$apps/badger.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Badger
Exec=touch $work/launched-badger
EOF
cat >"$apps/hidden.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Hidden Thing
NoDisplay=true
Exec=touch $work/launched-hidden
EOF

cat >"$rc" <<'EOF'
local kiln = require("kiln")
local ui, th = kiln.ui, kiln.theme

screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
	ui.bar(s, { edge = "top", h = 28, color = th.bg }, function()
		ui.box({ id = "barcell", w = 40, h = 20, color = th.accent })
	end)
end)
EOF

cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	XDG_DATA_HOME="$work/share" XDG_DATA_DIRS="$work/share" \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

sname=$(eval_kiln 'return screen.all()[1].name')

set_lua() {
	eval_kiln "$1
core.dirty()" >/dev/null
	sleep 0.6
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

press() { # lua-id-expr
	eval_kiln "
local st = require('kiln.state')
local s = screen.all()[1]
local id = $1
local b = core.box(id)
if b == nil then return 'no-box' end
local presses = st.screen_presses[s.name] or {}
for _, h in ipairs(core.hits(s.name, b.x + b.width / 2, b.y + b.height / 2)) do
  local fn = presses['on_press:' .. h.name .. '#' .. h.index]
  if fn ~= nil then
    fn()
    core.dirty()
    return h.name
  end
end
return 'no-handler'"
	sleep 0.6
}

# Type into the prompt through the claim it holds, which is the door every
# queued key goes through.
typekey() { # keyname
	eval_kiln "return tostring(require('kiln.grab').route_key
  { pressed = true, key = '$1', utf8 = '$2' })" >/dev/null
	sleep 0.4
}

# =====================================================================
# 1. The scan. Hermetic, so these are facts about the launcher.

check "CONTROL: nothing is declared while the launcher is closed" "absent" \
	"$(live '"launcher-list"')"
check "the scan found the two visible apps" "Aardvark Badger" \
	"$(eval_kiln 'local out = {}
for _, a in ipairs(require("kiln").launcher.apps()) do
  out[#out + 1] = a.name
end
table.sort(out)
return table.concat(out, " ")')"
check "and left NoDisplay out of them" "false" \
	"$(eval_kiln 'for _, a in ipairs(require("kiln").launcher.apps()) do
  if a.name == "Hidden Thing" then return "true" end
end
return "false"')"
check "the Exec field drops its field codes" "true" \
	"$(eval_kiln 'for _, a in ipairs(require("kiln").launcher.apps()) do
  if a.name == "Aardvark" then
    return tostring(a.exec:find("%%") == nil)
  end
end
return "missing"')"

# =====================================================================
# 2. The open, and the attach that used to abort. The prompt and the list first
# appear on the SAME frame, which is the case a float whose target was never
# declared cannot survive.

set_lua 'require("kiln").launcher.open()'
check "THE LEG: the compositor survived the first open" "1" \
	"$(eval_kiln 'return 1')"
check "the prompt is up" "live" "$(live "\"prompt:$sname\"")"
check "and the result list with it" "live" "$(live '"launcher-list"')"
check "both rows are listed" "live" "$(live '"launcher-row:1"')"
check "the hidden entry is not a row" "absent" "$(live '"launcher-row:3"')"

# The attachment, read off the two solved boxes. The list hangs on the prompt's
# bottom edge and lines up with its left, which is Clay answering rather than
# any sum of theme parts.
check "the list hangs off the prompt's bottom edge" "true" \
	"$(eval_kiln "local p = core.box('prompt:$sname')
local l = core.box('launcher-list')
if p == nil or l == nil then return 'no box' end
return tostring(l.y >= p.y + p.height - 1)")"
check "and lines up with its left edge" "true" \
	"$(eval_kiln "local p = core.box('prompt:$sname')
local l = core.box('launcher-list')
if p == nil or l == nil then return 'no box' end
return tostring(math.abs(l.x - p.x) <= 1)")"

# =====================================================================
# 3. Typing narrows the list. The prompt owns the keyboard for its lifetime, so
# this goes through the claim rather than around it.

# One "a" is not discriminating: Aardvark matches on its prefix and Badger on
# containing the letter, which is the ranking working rather than failing.
typekey a a
check "a letter both apps share keeps both rows" "live" \
	"$(live '"launcher-row:2"')"
check "with the prefix match ranked first" "Aardvark" \
	"$(eval_kiln 'return tostring(require("kiln").launcher.matches()[1].name)')"
typekey a a
check "a second letter narrows to the one match" "live" \
	"$(live '"launcher-row:1"')"
check "and drops the one that no longer matches" "absent" \
	"$(live '"launcher-row:2"')"
check "the match is the one that was typed" "Aardvark" \
	"$(eval_kiln 'return tostring(require("kiln").launcher.matches()[1].name)')"
check "and it is the only one" "1" \
	"$(eval_kiln 'return #require("kiln").launcher.matches()')"

# =====================================================================
# 4. A press on a row launches it and closes the launcher. The Exec touches a
# sentinel, so "it launched" is a fact on disk and not an inference.

check "a press on the row is taken by the row" "launcher-row:1" \
	"$(press '"launcher-row:1"')"
sleep 1
check "the app was spawned" "yes" \
	"$([ -e "$work/launched-aardvark" ] && echo yes || echo no)"
check "and the launcher closed behind it" "absent" "$(live '"launcher-list"')"
check "taking the prompt with it" "absent" "$(live "\"prompt:$sname\"")"
check "and giving the keyboard back" "false" \
	"$(eval_kiln 'return tostring(require("kiln.grab").route_key
  { pressed = true, key = "Escape" })')"

# =====================================================================
# 5. Escape cancels without launching, which is the other way out.

set_lua 'require("kiln").launcher.open()'
check "CONTROL: open again" "live" "$(live '"launcher-list"')"
typekey Escape ""
check "Escape closed it" "absent" "$(live '"launcher-list"')"
check "and launched nothing" "no" \
	"$([ -e "$work/launched-badger" ] && echo yes || echo no)"

# =====================================================================
# 6. Reload drops the scan cache. The apps are scanned once for the session, so
# an app installed while kiln runs appears on the next reload and not before.

cat >"$apps/civet.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Civet
Exec=touch $work/launched-civet
EOF
check "a new .desktop is not seen by the cached scan" "2" \
	"$(eval_kiln 'return #require("kiln").launcher.apps()')"
set_lua 'require("kiln").reload()'
sleep 1
check "and reload re-scans" "3" \
	"$(eval_kiln 'return #require("kiln").launcher.apps()')"
check "the launcher still opens after a reload" "live" \
	"$(set_lua 'require("kiln").launcher.open()'; live '"launcher-list"')"
set_lua 'require("kiln").launcher.close()'

# =====================================================================
printf '\n'
if [ "$fail" -eq 0 ]; then
	printf 'PASS\n'
else
	printf 'FAIL\n'
fi
exit "$fail"
