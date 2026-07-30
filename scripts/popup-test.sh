#!/bin/sh
# The popup battery: ui.popup is the quartet every piece of stdlib chrome was
# hand-rolling, offered once.
#
#   scripts/popup-test.sh
#
# The quartet: open state that IS the declare condition, a keyboard claim whose
# lifetime is the popup's, a scrim that catches the press landing outside, and a
# per-frame declare the runtime calls. Each of menu, hotkeys and the launcher
# built its own; what is under test is that one construction covers them and
# keeps each part's contract.
#
# PRESSES ARE RESTATED, NOT DRIVEN (the menu-test.sh discipline): headless has no
# input device, so a chrome press walks core.hits innermost-first and fires the
# first id carrying a handler, against the press table the last declare built.
# Keys go through grab.route_key, which is the door init.lua uses for every
# queued key, and its return value is the claim question: true means a claim
# held and consumed the key.
#
# EXISTENCE IS ASSERTED THROUGH core.hits, NEVER core.box: Clay's element
# hashmap persists, so core.box keeps answering with the last box an id ever had
# long after it stopped being declared.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-popup-test.XXXXXX)"
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

# The rc under test. Three popups, because the three things a popup can be
# anchored to are a point, the screen, and another element, and the claim rules
# only show themselves when two of them exist at once.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
local ui, th = kiln.ui, kiln.theme

CLOSED = {}

-- A keyed popup with a scrim: the hotkeys shape. Escape closes by name, and
-- everything else is swallowed, because a grab is a claim on the device and not
-- a filter on some of its events.
PP = ui.popup {
	id = "pp",
	scrim = true,
	anchor = "center",
	keys = { Escape = "close" },
	color = th.bg, radius = 6, pad = 8,
	on_close = function() CLOSED[#CLOSED + 1] = "pp" end,
	fn = function()
		ui.box({ id = "pp:body", w = 120, h = 60, color = th.accent })
	end,
}

-- A second keyed popup. One claim per device with no stack, so showing this
-- must take the keyboard off PP and PP must go with it.
QQ = ui.popup {
	id = "qq",
	anchor = "center",
	keys = { Escape = "close" },
	color = th.bg, pad = 8,
	on_close = function() CLOSED[#CLOSED + 1] = "qq" end,
	fn = function()
		ui.box({ id = "qq:body", w = 80, h = 40, color = th.urgent })
	end,
}

-- An element-attached popup with no keys at all. This is the case that used to
-- have no answer: it attaches to a bar element, and both first appear on the
-- same frame, which is a Clay error when the target has never been declared.
UNDER = ui.popup {
	id = "under",
	under = "anchorcell",
	scrim = false,
	color = th.bg, pad = 4,
	fn = function()
		ui.box({ id = "under:body", w = 60, h = 30, color = th.muted })
	end,
}

screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
	ui.bar(s, { edge = "top", h = 28, color = th.bg }, function()
		-- The float target: a plain bar cell with a stable id.
		ui.box({ id = "anchorcell", w = 40, h = 20, color = th.accent })
	end)
end)
EOF

cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

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

press_at() { # x y
	eval_kiln "
local st = require('kiln.state')
local s = screen.all()[1]
local presses = st.screen_presses[s.name] or {}
for _, h in ipairs(core.hits(s.name, $1, $2)) do
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

rkey() { # keyname
	eval_kiln "return tostring(require('kiln.grab').route_key
  { pressed = true, key = '$1' })"
	sleep 0.6
}

# hits_at: every id named under a point, outermost last, as one string. What a
# scrim needs that live() cannot give: a screen-sized rect's own centre is where
# the popup sits, so asking about it there answers about the popup. The scrim is
# only itself where the popup is not.
hits_at() { # x y
	eval_kiln "
local s = screen.all()[1]
local out = {}
for _, h in ipairs(core.hits(s.name, $1, $2)) do
  out[#out + 1] = h.name
end
return table.concat(out, ' ')"
}

# has: is this id among the hits at a point?
has() { # x y id
	case " $(hits_at "$1" "$2") " in
		*" $3 "*) echo yes ;;
		*) echo no ;;
	esac
}

# =====================================================================
# 1. Open state IS the declare condition. There is no visibility flag beside it,
# so a closed popup is not hidden chrome, it is no chrome.

corner=$(eval_kiln 'return screen.all()[1].height - 5')

check "CONTROL: a constructed popup declares nothing" "absent" "$(live '"pp"')"
check "CONTROL: and neither does its body" "absent" "$(live '"pp:body"')"
check "CONTROL: nor its scrim" "no" "$(has 5 "$corner" pp:scrim)"

set_lua 'PP:show()'
check "show declares the popup" "live" "$(live '"pp"')"
check "and the body its fn declared" "live" "$(live '"pp:body"')"
# The scrim is asked about where the popup is NOT, because a screen-sized rect's
# own centre is exactly where a centred popup sits.
check "and the scrim under it" "yes" "$(has 5 "$corner" pp:scrim)"
check "open names the screen it is on" "true" \
	"$(eval_kiln 'return tostring(PP.open == screen.all()[1])')"

# =====================================================================
# 2. The scrim. A press outside dismisses; a press ON the popup does not, which
# is dispatch being innermost-first with no bubbling rather than any geometry
# the scrim knows about.

# Over the popup the scrim is not in the hit list at all: the popup captures,
# and dispatch stops at the first hit carrying a handler with no bubbling. So a
# press there cannot reach the scrim however the two are stacked.
bodyx=$(eval_kiln 'local b = core.box("pp:body")
return math.floor(b.x + b.width / 2)')
bodyy=$(eval_kiln 'local b = core.box("pp:body")
return math.floor(b.y + b.height / 2)')
check "the popup is what is under a press on its body" "yes" \
	"$(has "$bodyx" "$bodyy" pp)"
check "and the scrim is not reachable there" "no" \
	"$(has "$bodyx" "$bodyy" pp:scrim)"
check "so a press there leaves the popup up" "no-handler" \
	"$(press_at "$bodyx" "$bodyy")"
check "and the popup is still up" "live" "$(live '"pp"')"

check "a press outside reaches the scrim" "pp:scrim" "$(press_at 5 "$corner")"
check "which closed the popup" "absent" "$(live '"pp"')"
check "and the scrim went with it" "absent" "$(live '"pp:scrim"')"
check "on_close fired exactly once" "pp" \
	"$(eval_kiln 'return table.concat(CLOSED, " ")')"

# =====================================================================
# 3. The keyboard claim. Its lifetime is the popup's: held while open, released
# on close, and a key the map does not name is still consumed.

check "CONTROL: no claim while closed" "false" "$(rkey Escape)"
set_lua 'PP:show()'
check "an open popup holds the claim" "true" "$(rkey Escape)"
check "and Escape closed it by name" "absent" "$(live '"pp"')"
check "the claim is released with the popup" "false" "$(rkey Escape)"

set_lua 'PP:show()'
check "an unmapped key is swallowed rather than leaking to a binding" "true" \
	"$(rkey z)"
check "and does NOT close a popup that did not name it" "live" \
	"$(live '"pp"')"

# =====================================================================
# 4. One claim per device, no stack. A second keyed popup takes the keyboard,
# and a popup that cannot be driven is not the popup that was opened, so it goes
# with its claim.

set_lua 'CLOSED = {}
QQ:show()'
check "the second popup is up" "live" "$(live '"qq"')"
check "and the first went with its claim" "absent" "$(live '"pp"')"
check "its on_close ran, so nothing was left half-open" "pp" \
	"$(eval_kiln 'return table.concat(CLOSED, " ")')"
check "the survivor holds the claim" "true" "$(rkey Escape)"
check "and closes on it" "absent" "$(live '"qq"')"

# grab.reset() is the reload door: every claim stops, so every popup riding one
# closes rather than being stranded with no way to dismiss it.
set_lua 'CLOSED = {}
PP:show()'
set_lua 'require("kiln.grab").reset()'
check "a claim reset takes the popup down" "absent" "$(live '"pp"')"
check "through the same on_close" "pp" \
	"$(eval_kiln 'return table.concat(CLOSED, " ")')"

# =====================================================================
# 5. The element attach, which is why a popup declares where it declares. The
# target and the popup first appear on the SAME frame, and a float whose target
# has never been declared is a Clay error that takes the compositor with it. So
# the leg that matters is that the compositor is still answering afterwards.

set_lua 'UNDER:show()'
check "the compositor survived a first-frame element attach" "1" \
	"$(eval_kiln 'return 1')"
check "the attached popup is up" "live" "$(live '"under"')"
check "with no scrim, because it did not ask for one" "absent" \
	"$(live '"under:scrim"')"
check "and it holds no claim, so bindings still work under it" "false" \
	"$(rkey Escape)"
# Attachment is Clay's answer, not arithmetic: the popup's left edge is the
# cell's left edge, and it sits at or below the cell's bottom. At or below
# rather than exactly at, because the target is a BAR cell and the fit keeps the
# box inside the workarea, which starts under the bar: a popup dropped from a
# bar cell clears the bar the way the menu does. Reading both boxes back is how
# an attachment is checked; nothing here computes a position.
check "it lines up with its target's left edge" "true" \
	"$(eval_kiln 'local a = core.box("anchorcell")
local p = core.box("under")
if a == nil or p == nil then return "no box" end
return tostring(math.abs(p.x - a.x) <= 1)')"
check "and hangs at or below its bottom edge" "true" \
	"$(eval_kiln 'local a = core.box("anchorcell")
local p = core.box("under")
if a == nil or p == nil then return "no box" end
return tostring(p.y >= a.y + a.height - 1)')"
set_lua 'UNDER:close()'
check "and closes with no claim to release" "absent" "$(live '"under"')"

# =====================================================================
# 6. The constructor's own guards. A popup is built once and lives for the
# session; the ways to get that wrong are silent, so they are refused.

check "a table id is refused" "false" \
	"$(eval_kiln 'return tostring((pcall(require("kiln.ui").popup,
  { id = { "bad", 1 }, fn = function() end })))')"
check "a missing id is refused" "false" \
	"$(eval_kiln 'return tostring((pcall(require("kiln.ui").popup,
  { fn = function() end })))')"
check "and so is a second popup claiming a live id" "false" \
	"$(eval_kiln 'return tostring((pcall(require("kiln.ui").popup,
  { id = "pp", fn = function() end })))')"
check "CONTROL: a fresh id is accepted" "true" \
	"$(eval_kiln 'return tostring((pcall(require("kiln.ui").popup,
  { id = "fresh", fn = function() end })))')"
check "destroy releases the id for reuse" "true" \
	"$(eval_kiln 'local ui = require("kiln.ui")
local p = ui.popup { id = "recycled", fn = function() end }
p:destroy()
return tostring((pcall(ui.popup, { id = "recycled", fn = function() end })))')"

# =====================================================================
printf '\n'
if [ "$fail" -eq 0 ]; then
	printf 'PASS\n'
else
	printf 'FAIL\n'
fi
exit "$fail"
