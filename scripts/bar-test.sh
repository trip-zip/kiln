#!/bin/sh
# The bar-edge battery: a bar's cfg is ordinary element cfg plus `edge`, and
# the strut fold handles all four edges, so a left bar needs no machinery a
# top bar does not have.
#
#   scripts/bar-test.sh
#
# What is under test is the left edge, the one the old runtime clamped away:
# the bar reserves workarea on the LEFT, its along-edge axis grows to the full
# screen height, its direction defaults from the edge to a column, and the
# documented defaults (pad on the along axis, gap 6, cross-axis center) reach
# a vertical bar. Alongside the edge legs, a plain ui.box speaks `dir` in both
# vocabularies: the constructor name and the Clay name must each turn a box
# into a column. Every geometry leg compares solved boxes to each other and
# to the live screen size, never to a pixel constant a wrong-but-consistent
# layout would also produce; the one existence leg goes through core.hits,
# because core.box keeps answering for ids that stopped being declared.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-bar-test.XXXXXX)"
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

# Two fixed-size cells, so the column claim can be read out of their solved
# boxes alone. The bar states only edge, across-axis width and color; dir,
# pad, gap and align are the defaults under test.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
local ui, th = kiln.ui, kiln.theme

screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()

	ui.bar(s, { edge = "left", w = 40, color = th.bg }, function()
		ui.box({ id = "cell1", w = 24, h = 24, color = th.bg2 })
		ui.box({ id = "cell2", w = 24, h = 24, color = th.bg2 })
		ui.box({ id = "dbox", dir = "column" }, function()
			ui.box({ id = "d1", w = 10, h = 10, color = th.bg2 })
			ui.box({ id = "d2", w = 10, h = 10, color = th.bg2 })
		end)
		ui.box({ id = "tbox", dir = "ttb" }, function()
			ui.box({ id = "t1", w = 10, h = 10, color = th.bg2 })
			ui.box({ id = "t2", w = 10, h = 10, color = th.bg2 })
		end)
	end)
end)
EOF

cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

# =====================================================================
# The bar itself: declared, on the left, grown to the full screen height.

check "the bar is declared at the left edge (mid height)" "true" \
	"$(eval_kiln 'local s = screen.all()[1]
for _, h in ipairs(core.hits(s.name, 2, s.height / 2)) do
  if h.name == "bar" then return "true" end
end
return "false"')"

check "the bar solves at x 0, its stated width, the full screen height" \
	"true" \
	"$(eval_kiln 'local s = screen.all()[1]
local b = core.box({ "bar", 1 })
if b == nil then return "no box" end
return tostring(b.x == 0 and b.width == 40 and b.height == s.height)')"

# =====================================================================
# The strut: the workarea gives up exactly the bar's width on the left and
# keeps the full height, restated from the live screen size.

check "the workarea is reserved on the left, full height" "true" \
	"$(eval_kiln 'local s = screen.all()[1]
local wa = core.box("workarea:" .. s.name)
if wa == nil then return "no box" end
return tostring(wa.x == 40 and wa.width == s.width - 40
  and wa.y == 0 and wa.height == s.height)')"

# =====================================================================
# The body: dir defaulted from the edge to a column, with the documented
# defaults on a vertical bar (pad y 8 leading, gap 6 between, cross-axis
# center).

check "the cells stack as a column, gap 6 apart" "true" \
	"$(eval_kiln 'local a = core.box("cell1")
local b = core.box("cell2")
if a == nil or b == nil then return "no box" end
return tostring(a.x == b.x and b.y - (a.y + a.height) == 6)')"

check "the first cell sits below the leading pad" "true" \
	"$(eval_kiln 'local bar = core.box({ "bar", 1 })
local a = core.box("cell1")
if bar == nil or a == nil then return "no box" end
return tostring(a.y - bar.y == 8)')"

check "the cross axis centers the cells in the bar" "true" \
	"$(eval_kiln 'local bar = core.box({ "bar", 1 })
local a = core.box("cell1")
if bar == nil or a == nil then return "no box" end
return tostring(a.x - bar.x == (bar.width - a.width) / 2)')"

# =====================================================================
# The dir cfg key on a plain ui.box, both spellings. A box lays its children
# out ltr unless told otherwise, so children that stack vertically are proof
# the key reached the solver rather than being dropped.

check "dir = \"column\" stacks a box's children" "true" \
	"$(eval_kiln 'local a = core.box("d1")
local b = core.box("d2")
if a == nil or b == nil then return "no box" end
return tostring(a.x == b.x and b.y == a.y + a.height)')"

check "dir = \"ttb\" stacks a box's children" "true" \
	"$(eval_kiln 'local a = core.box("t1")
local b = core.box("t2")
if a == nil or b == nil then return "no box" end
return tostring(a.x == b.x and b.y == a.y + a.height)')"

# =====================================================================
printf '\n'
if [ "$fail" -eq 0 ]; then
	printf 'PASS\n'
else
	printf 'FAIL\n'
fi
exit "$fail"
