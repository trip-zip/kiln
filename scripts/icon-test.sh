#!/bin/sh
# The icon battery: the two X11 client facts a config could not reach (the
# window's _NET_WM_ICON pixels and its WM_WINDOW_ROLE), and the Lua icon lookup
# that turns an app_id into a path:
#
#   scripts/icon-test.sh
#
# The C half rides the payload, never a verb: an X client's icon is decoded into
# the image cache under "xwl-icon:<handle>" and the KEY rides client::map, so
# Lua declares the pixels it never saw. The role rides the same payload, which
# is what makes `kiln.rule{ match = { role = "pop%-up" } }` expressible.
#
# The Lua half is kiln.icon: XDG dirs, a .desktop Icon= line, and a fixed list of
# icon-theme probes. No index.theme parse and no inherits chain, on purpose:
# the fixed list is the small answer, and a name that resolves to nothing
# is nil, which the widgets render as the placeholder they already had.
#
# LARGEST-WINS is the interesting claim, so the fixture declares the 8x8 red icon
# FIRST and the 16x16 green one second: first-wins keeps red, largest-wins keeps
# green. The structural half of that assert (an icon arrived at all) is
# dependency-free; the pixel half needs ImageMagick and skips with a note when it
# is absent (the recipes-test.sh pattern).
#
# XDG_DATA_HOME is planted BEFORE the boot: kiln.icon runs inside the compositor
# process, so the fixture dirs must be in the env kiln itself inherits.
#
# Needs: XWayland (skips without it). foot and ImageMagick are optional legs.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-icon-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
rc="$work/rc.lua"
apps="$work/data/applications"
kiln_pid=""
fixture_pid=""

cleanup() {
	[ -n "$fixture_pid" ] && kill "$fixture_pid" 2>/dev/null || true
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

# =====================================================================
# The fixture data dir: one .desktop naming an icon file that exists, planted
# under a private XDG_DATA_HOME (the menubar-test.sh recipe). The PNG's pixels do
# not matter; kiln.icon probes for existence and hands the path to the widget.

mkdir -p "$apps"
footicon="$work/data/footicon.png"
base64 -d > "$footicon" <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6
kgAAAABJRU5ErkJggg==
EOF
cat >"$apps/foot.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Foot
Icon=$footicon
Exec=foot
EOF

# The probe-ordering fixture: one name that ships BOTH a scalable svg and a
# sized png, one that ships only an svg. gdk-pixbuf decodes png builtin but has no
# svg loader where librsvg 2.62+ ships none, so the sized png must win whenever
# both exist, and svg stays the last resort for a theme that has nothing else.

hicolor="$work/data/icons/hicolor"
mkdir -p "$hicolor/scalable/apps" "$hicolor/48x48/apps"
cp "$footicon" "$hicolor/48x48/apps/bothicon.png"
cat >"$hicolor/scalable/apps/bothicon.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>
EOF
cp "$hicolor/scalable/apps/bothicon.svg" "$hicolor/scalable/apps/svgonly.svg"

# =====================================================================
# The rc under test: a bar with the tasklist (the icon slot's home), titlebars,
# and the role rule whose firing is the role fact's user-visible proof. The dash
# is escaped because match values are Lua patterns.

cat >"$rc" <<'EOF'
local kiln = require("kiln")
local ui = kiln.ui
local widgets = kiln.widgets
local th = kiln.theme
local rule = kiln.rule

rule { match = { role = "pop%-up" }, props = { floating = true } }

screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
	ui.bar(s, { edge = "top", h = 28, color = th.bg }, function()
		widgets.tasklist(s)
		-- The always-declared probe cell: the icon slot's decode leg with no
		-- client needed, so the decode-error assertion holds before XWayland.
		ui.image(kiln.icon.path("bothicon"), { id = "iconprobe", w = 12, h = 12 })
	end)
end)

client.on("map", function(c)
	c.titlebar = true
end)
EOF

# =====================================================================
# Boot with the fixture dirs in the env: kiln.icon reads them in-process.

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	XDG_DATA_HOME="$work/data" XDG_DATA_DIRS="/usr/local/share:/usr/share" \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

check "the compositor booted" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"

# =====================================================================
# The probe order. Lookup-level and log-level, both before the XWayland
# gate: neither needs an X client, and the ordering defect bites every client.
#
# The svg-only row asserts the FALL-THROUGH, not a rendered cell: a resolved but
# undecodable path renders nothing (render.c: "A missing, failed, or
# not-yet-decoded entry shows nothing"), it does not fall to the accent
# placeholder, and it logs. So the undecodable svg is never declared into a live
# cell here, which is what leaves the decode-error count honestly zero rather
# than exempted. The conversion answer for an svg-only theme is a recipe note.

tail_of() { eval_kiln "return (require('kiln.icon').path('$1') or ''):match('([^/]+/[^/]+/[^/]+/[^/]+)\$') or 'nil'"; }

check "a sized png beats the scalable svg" "hicolor/48x48/apps/bothicon.png" \
	"$(tail_of bothicon)"
check "an svg-only name still falls through to svg" \
	"hicolor/scalable/apps/svgonly.svg" "$(tail_of svgonly)"
# The decode is lazy: a declared image is only opened when a frame rasters it, so
# the probe cell has to be rendered before the log can be believed. A screenshot
# is the headless way to force that frame.
eval_kiln "core.screenshot(screen.all()[1].name, '$work/probe.png')" >/dev/null
sleep 1
check "the declared icon decoded, no decode errors" "0" \
	"$(grep -c 'image decode failed' "$log" || true)"

xdisp=$(eval_kiln 'return os.getenv("DISPLAY") or ""')
[ -n "$xdisp" ] || { echo "SKIP: no XWayland in this build"; exit 0; }

# live: is this id declared RIGHT NOW? core.box keeps answering with the last box
# an id ever had (Clay's hashmap is persistent), so existence is
# core.hits' answer, never core.box's. The rc-test.sh helper, verbatim.
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

count() {
	eval_kiln 'local k = 0
for _, s in ipairs(screen.all()) do
  for _, t in ipairs(s.tags) do k = k + #t.clients end
end
return k'
}

# =====================================================================
# The fixture client: a managed X11 window carrying both facts.
#
# XWayland is lazy (spawned on the first X client), and the connection that
# TRIGGERS that start races xwm's grab of SubstructureRedirect on the root: a
# bare xcb client that maps in one breath can lose its MapRequest, where a
# slow-starting real app never would. The fixture already waits for the WM
# (_NET_SUPPORTING_WM_CHECK) before mapping, which covers the common case, but
# the very first client on a cold XWayland is inherently flaky. So spawn until
# one maps: a lost attempt is a harmless idle client (it never mapped, so it is
# in no tag and matches no class), and once XWayland is warm the next spawn
# lands. It converges in one or two tries, and dies with the compositor at
# teardown.

for _ in $(seq 1 8); do
	[ "$(count)" = "1" ] && break
	eval_kiln 'core.spawn("'"$repo"'/build/x11-icon")' >/dev/null
	for _ in 1 2 3 4; do
		[ "$(count)" = "1" ] && break
		sleep 1
	done
done
check "the X11 fixture mapped" "1" "$(count)"

# Its handle, matched by WM_CLASS (the xwl-reposition-test discipline: never by
# title).
h=$(eval_kiln 'for _, s in ipairs(screen.all()) do
  for _, t in ipairs(s.tags) do
    for _, c in ipairs(t.clients) do
      if c.class == "KilnIcon" then return c.handle end
    end
  end
end
return "absent"')
check "the fixture is findable by its WM_CLASS" "true" \
	"$([ "$h" != "absent" ] && echo true || echo false)"
[ "$h" != "absent" ] || { echo FAIL; exit 1; }

by_handle() { # lua-expr over c
	eval_kiln 'for _, s in ipairs(screen.all()) do
  for _, t in ipairs(s.tags) do
    for _, c in ipairs(t.clients) do
      if c.handle == '"$h"' then return '"$1"' end
    end
  end
end
return "absent"'
}

# =====================================================================
# The role fact, and the rule it makes expressible.

check "WM_WINDOW_ROLE reached Lua as c.role" "pop-up" \
	"$(by_handle 'c.role')"
check "a rule matching role = pop%-up fired" "true" \
	"$(by_handle 'tostring(c.floating == true)')"

# =====================================================================
# The icon fact: the key rides the payload, and the tasklist declares the cell.

check "_NET_WM_ICON reached Lua as c.icon (the cache key)" "xwl-icon:$h" \
	"$(by_handle 'c.icon')"
check "the tasklist declared an icon cell for it" "live" \
	"$(live "{ \"taskicon\", $h }")"

# =====================================================================
# Largest-wins. The structural half is above: c.icon is non-nil only because
# ui_image_put accepted a buffer whose own numbers agreed. The pixel half names
# WHICH icon survived, and needs a way to read a pixel back.

if command -v magick > /dev/null 2>&1 || command -v convert > /dev/null 2>&1; then
	im=$(command -v magick || command -v convert)
	shot="$work/shot.png"
	sname=$(eval_kiln 'return screen.all()[1].name')
	eval_kiln "core.screenshot('$sname', '$shot')" >/dev/null
	sleep 1
	cxy=$(eval_kiln "local b = core.box({ 'taskicon', $h })
if b == nil then return 'absent' end
return math.floor(b.x + b.width / 2) .. ',' .. math.floor(b.y + b.height / 2)")
	if [ "$cxy" = "absent" ]; then
		check "the icon cell has a box to probe" "true" "false"
	else
		px=$("$im" "$shot" -format "%[hex:p{$cxy}]" info: 2>/dev/null | head -c 6)
		# Green is the 16x16 icon, red the 8x8 one declared before it.
		check "the LARGEST icon won (green, not the red one declared first)" \
			"green" "$(case "$px" in
				00*00) echo green ;;
				[Ff][Ff]0000) echo red ;;
				*) echo "unknown($px)" ;;
			esac)"
	fi
else
	echo "info the largest-wins pixel probe needs ImageMagick; skipped"
	echo "     (c.icon being set still proves an icon buffer was accepted)"
fi

# =====================================================================
# The Lua lookup, asserted directly: the planted foot.desktop's Icon= line is
# what kiln.icon.path resolves, and a name nothing ships is nil.

check "kiln.icon.path resolves an app_id through its .desktop Icon= line" \
	"$footicon" \
	"$(eval_kiln 'return require("kiln.icon").path("foot") or "nil"')"
check "a name nothing ships resolves to nil (the placeholder path)" "nil" \
	"$(eval_kiln 'return tostring(require("kiln.icon").path("kiln-no-such-app"))')"

if command -v foot > /dev/null 2>&1; then
	eval_kiln 'core.spawn("foot")' >/dev/null
	for _ in $(seq 1 15); do
		[ "$(count)" = "2" ] && break
		sleep 1
	done
	fh=$(eval_kiln 'for _, s in ipairs(screen.all()) do
  for _, t in ipairs(s.tags) do
    for _, c in ipairs(t.clients) do
      if c.app_id == "foot" then return c.handle end
    end
  end
end
return "absent"')
	if [ "$fh" != "absent" ]; then
		# A Wayland client has no C icon fact; the lookup is the whole path.
		check "a Wayland client's icon comes from the lookup" "$footicon" \
			"$(eval_kiln 'for _, s in ipairs(screen.all()) do
  for _, t in ipairs(s.tags) do
    for _, c in ipairs(t.clients) do
      if c.handle == '"$fh"' then
        return require("kiln.icon").client(c) or "nil"
      end
    end
  end
end
return "absent"')"
		check "and its tasklist row declared the icon cell" "live" \
			"$(live "{ \"taskicon\", $fh }")"
	else
		echo "info foot did not map; the Wayland lookup leg is skipped"
	fi
else
	echo "info foot is not installed; the Wayland lookup leg is skipped"
fi

# =====================================================================
# A missing icon is a placeholder, not an error: the whole battery ran with one
# client that has no icon file to find, and the bus stayed clean.

# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's
# pcall, so this leg MUST go red under it, or the grep is watching nothing.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

noise=$(grep -cE "error in '|tree==scene:|DUPLICATE" "$log" || true)
check "no bus errors, no tree/scene divergence, no duplicate ids" "0" "$noise"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
