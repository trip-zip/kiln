#!/bin/sh
# The paint battery: what a declaration can make the renderer PUT DOWN, as
# opposed to where it puts it. Five sections so far.
#
#   scripts/paint-test.sh
#
# Section 1, shapes with no new code. A rounded rect whose radius reaches half
# the smaller side IS a circle, and giving that box a border instead of a fill
# makes it a ring: every straight edge solves to zero extent, so the whole
# annulus is the four corner tiles. Written first because the rest of the paint
# question rests on the claim, and it must be green before anything changes.
#
# Section 2, image recolor. The colour on an image declaration replaces the
# file's own colours and keeps only its transparency, so one glyph file can be
# drawn in any ink. The legs that matter are the ones a flat fill would also
# pass, so the fixture is HALF TRANSPARENT and every colour claim is paired with
# a control that must read differently.
#
# Section 3, the font table. Text is the one leaf whose SIZE the renderer
# decides, so the legs that matter here are boxes rather than pixels: a fitted
# box around a text leaf IS what the measure callback answered, and a face that
# reached the raster without reaching the measure would leave that box at the
# default face's width. The pixel leg is a paired control, not the claim.
#
# Section 4, truncating an overflowing run. The bound is the only hard part: a
# text element is sized to its own glyphs and its render command reports that
# same width, so no available width exists anywhere on the declaration side.
# What bounds a run is the clip its parent declared, which makes truncation a
# property of the pair. Every claim is paired with a cell that must NOT change,
# because "something moved" is cheap and "only the right thing moved" is not.
#
# Section 5, generated assets. The one thing a declaration cannot do is MAKE an
# image, so anything with no vocabulary here (a gradient) arrives as a file
# rendered out of process. The claims are that the file is addressed by its
# content and that it is rendered once, and the one pixel leg reads the
# generated file rather than a capture, because a document that rasterized to
# nothing passes every other leg.
#
# The rest are pixel legs on purpose. Boxes cannot answer "what colour is this",
# and the compositor is entitled to solve a correct box and paint the wrong
# thing into it; that is the whole defect class here. Sample points are computed
# from core.box, never written down.
#
# Needs ImageMagick for the pixel legs, which are skipped with an info line
# when it is absent. No client fixture: nothing here needs a surface.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-paint-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
rc="$work/rc.lua"
cfg="$work/config"
img="$work/half.png"
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
		printf 'ok   %s\n     (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s\n     expected %s\n     got      %s\n' "$1" "$2" "$3"
		fail=1
	fi
}
note() { printf 'info %s\n' "$1"; }

# The fixture: 64x64, left half opaque #40C0F0, right half fully transparent.
# Carried as base64 rather than generated, so the battery needs no image tool to
# BUILD its input and the input bytes never drift. The transparent half is
# load-bearing: it is the difference between recolouring an image and filling a
# box.
base64 -d > "$img" <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAaUlEQVR42u3QAQkAAAjAMKMZ3Ug2
0Bgi7PACi6yey+M6AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA4D/AAhNQeVo7QWfdAAAAAElFTkSuQmCC
EOF
check "the fixture decoded to a 64x64 RGBA png" "PNG image data, 64 x 64" \
	"$(file -b "$img" | cut -d, -f1-2)"

# The rc under test. Colours are literals here rather than theme keys: the
# expectations below are written against these six values, and a theme edit
# must not be able to redden this file.
#
# Every cell is declared INSIDE the bar closure, which is what makes MUT a live
# read: a cell built once outside would capture the boot value and the mutation
# leg would assert nothing. Placement is fixed spacing boxes, so where the
# cells land is the compositor's answer.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
local ui = kiln.ui

IMG = os.getenv("PAINT_IMG")
MUT = nil
FONT = nil
ELLIP = nil
CLIPW = 90

local BAR, INK = "#000000", "#ffffff"

-- One string for every font cell, long enough that a weight change moves the
-- measured width by more than the half-up rounding core.box applies, and mixed
-- case so the change is in the glyphs rather than in one wide letter.
local STR = "Handgloves and quartz"

-- Section 4's strings. LONG must overflow CLIPW several times over, so that
-- where the truncation lands is never in doubt; SHORT must fit inside it with
-- room, because the control it serves is that a run which fits is untouched.
local LONG = "Handgloves and quartz and rather more besides"
local SHORT = "Hi"

screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
	ui.bar(s, { edge = "top", h = 48, color = BAR }, function()
		-- radius at half the smaller side: a disc.
		ui.box({ id = "disc", w = 40, h = 40, radius = 20, color = INK })
		ui.box({ w = 8, h = 8 })
		-- the same box bordered instead of filled: a ring.
		ui.box({ id = "ring", w = 40, h = 40, radius = 20,
			border = { width = 3, color = INK } })
		ui.box({ w = 8, h = 8 })
		ui.image(IMG, { id = "plain", w = 40, h = 40 })
		ui.box({ w = 8, h = 8 })
		ui.image(IMG, { id = "red", w = 40, h = 40, recolor = "#ff0000" })
		ui.box({ w = 8, h = 8 })
		ui.image(IMG, { id = "green", w = 40, h = 40, recolor = "#00ff00" })
		ui.box({ w = 8, h = 8 })
		-- recolour and a corner clip at once: the clip is set before the
		-- recolour, so one must not eat the other.
		ui.image(IMG, { id = "round", w = 40, h = 40, radius = 20,
			recolor = "#ff0000" })
		ui.box({ w = 8, h = 8 })
		ui.image(IMG, { id = "faded", w = 40, h = 40, recolor = "#ff000080" })
		ui.box({ w = 8, h = 8 })
		-- a zero-alpha ink is no ink, not an invisible one.
		ui.image(IMG, { id = "zero", w = 40, h = 40, recolor = "#ff000000" })
		ui.box({ w = 8, h = 8 })
		ui.image(IMG, { id = "mut", w = 40, h = 40, recolor = MUT })
	end)

	-- The font cells get a bar of their own, because a fitted box only reports
	-- the measure while it has room to: four runs of this length sharing the top
	-- bar with section 2's cells would overflow it, and Clay shrinks a fit box
	-- that does not fit. Their own full-width row keeps every width a measure.
	ui.bar(s, { edge = "bottom", h = 48, color = BAR }, function()
		-- Same string, same size, three declarations of the face: absent,
		-- named explicitly, and a different weight. All in ONE frame, which is
		-- what also makes this a measure-cache leg.
		ui.box({ id = "reg", w = "fit", h = "fit" }, function()
			ui.text(STR, { size = 14, color = INK })
		end)
		ui.box({ w = 8, h = 8 })
		ui.box({ id = "same", w = "fit", h = "fit" }, function()
			ui.text(STR, { size = 14, color = INK, font = "Sans" })
		end)
		ui.box({ w = 8, h = 8 })
		ui.box({ id = "bold", w = "fit", h = "fit" }, function()
			ui.text(STR, { size = 14, color = INK, font = "Sans Bold" })
		end)
		ui.box({ w = 8, h = 8 })
		ui.box({ id = "mfont", w = "fit", h = "fit" }, function()
			ui.text(STR, { size = 14, color = INK, font = FONT })
		end)
	end)

	-- Section 4's cells, in a bar of their own for section 3's reason and one
	-- more: the unclipped control overflows its box on purpose, so it needs
	-- empty space to its right rather than a neighbour to paint over.
	--
	-- Each clipped cell is a FIXED width, which is what makes it a bound the
	-- text cannot negotiate with: a fit or grow cell would size itself to the
	-- string and there would be nothing to truncate.
	ui.bar(s, { edge = "bottom", h = 48, color = BAR }, function()
		-- The subject. The fit wrapper is how the text's MEASURE is readable at
		-- all (a text leaf takes no id), and it reports the unclipped width
		-- because a clipping parent does not compress its children.
		ui.box({ id = "eclip", w = CLIPW, h = "fit",
			clip = { horizontal = true } }, function()
			ui.box({ id = "efit", w = "fit", h = "fit" }, function()
				ui.text(LONG, { size = 14, color = INK,
					wrap = "none", ellipsize = ELLIP })
			end)
		end)
		ui.box({ w = 8, h = 8 })
		-- The wrap control, text declared directly so Clay's own wrapping is
		-- what decides the cell's height. Same flag, different wrap mode.
		ui.box({ id = "wclip", w = 90, h = "fit",
			clip = { horizontal = true } }, function()
			ui.text(LONG, { size = 14, color = INK,
				wrap = "words", ellipsize = ELLIP })
		end)
		ui.box({ w = 8, h = 8 })
		-- A run that FITS its clip. Nothing overflows, so nothing may be
		-- truncated: this is the leg that catches an ellipsis fired by a
		-- rounding pixel rather than by real overflow.
		ui.box({ id = "fclip", w = 90, h = "fit",
			clip = { horizontal = true } }, function()
			ui.text(SHORT, { size = 14, color = INK,
				wrap = "none", ellipsize = ELLIP })
		end)
		ui.box({ w = 8, h = 8 })
		-- Same overflow, NO clip. The flag has no bound to work from here, so
		-- this cell must be untouched however the flag is set. Last in the bar,
		-- because its text overflows into whatever follows it.
		ui.box({ id = "nclip", w = 90, h = "fit" }, function()
			ui.text(LONG, { size = 14, color = INK,
				wrap = "none", ellipsize = ELLIP })
		end)
	end)
end)
EOF

# No subshell: $! must be kiln itself, or cleanup kills a wrapper and orphans
# the compositor to init.
cd "$repo"
# XDG_CACHE_HOME is redirected because section 5 renders into the asset cache
# and counts what is there. Pointed at the developer's real one it would both
# read a warm cache and leave files behind.
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	XDG_CONFIG_HOME="$cfg" XDG_CACHE_HOME="$work/cache" PAINT_IMG="$img" \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

check "the compositor booted" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"

sname=$(eval_kiln 'return screen.all()[1].name')

# core.box answers in LOGICAL px and a capture is DEVICE px. They coincide only
# at scale 1, so that is asserted rather than assumed; the 2x leg near the end
# does the conversion explicitly. One output at the layout origin also keeps
# Clay's boxes and the buffer on the same coordinates.
check "scale is 1 (device px == logical px for the probes)" "1" \
	"$(eval_kiln "return core.output.list()[1].scale")"

# --- one decode, read BEFORE the first capture.
#
# The decode cache keys on the path string alone, so eight cells on one path are
# one entry however they are coloured; this pins that the ink did not leak into
# that key. It cannot fail from a raster-side defect, and it is read here
# because core.screenshot interns its own full-frame readback under a fresh key
# per call, which would swamp the number.
gauge() { grep 'solve #' "$log" | tail -1 | sed 's/.*rnodes=/rnodes=/'; }
field() { gauge | tr ' ' '\n' | sed -n "s/^$1=//p"; }
check "one decode for eight cells on one path (16 KB, ARGB32 64x64)" "16" \
	"$(field images_kb)"

# --- the frame.
solves() { grep -c 'solve #' "$log" || true; }
sname_q="$sname"

# Force one solve and wait for it. Split out of shoot because a box leg needs
# the solve and not the capture, and the capture is the expensive half.
resolve() {
	before=$(solves)
	eval_kiln 'core.dirty()' >/dev/null
	spin=0
	while [ "$(solves)" -le "$before" ] && [ "$spin" -lt 40 ]; do
		sleep 0.1
		spin=$((spin + 1))
	done
}

shoot() { # outfile
	resolve
	# The screenshot verb hands back the last COMMITTED frame, so the first
	# capture is a throwaway that forces the upload and the second is the one
	# read. A capture taken straight after a mutation reads the old buffer.
	eval_kiln "core.screenshot('$sname_q', '$work/force.png')" >/dev/null
	sleep 0.4
	eval_kiln "core.screenshot('$sname_q', '$1')" >/dev/null
	sleep 0.5
}

box() { # id -> "x y w h"
	eval_kiln "
local b = core.box('$1')
return b == nil and '- - - -' or
  string.format('%d %d %d %d', b.x, b.y, b.width, b.height)"
}

shoot "$work/a.png"
check "the capture is a png at the output resolution" "PNG image data" \
	"$(file -b "$work/a.png" | cut -d, -f1)"

if command -v magick >/dev/null 2>&1; then
	im=magick
elif command -v convert >/dev/null 2>&1; then
	im=convert
else
	im=""
fi

if [ -z "$im" ]; then
	note "ImageMagick not installed; skipping every pixel leg"
else
	px() { # file x y -> RRGGBB
		"$im" "$1" -format "%[hex:p{$2,$3}]" info: 2>/dev/null | head -c 6
	}
	# at: file id dx dy -> the pixel dx,dy inside that element's solved box.
	at() {
		set -- "$1" "$2" "$3" "$4" $(box "$2")
		px "$1" "$((${5} + $3))" "$((${6} + $4))"
	}

	# =============================================================
	# Section 1: the shapes that already work.
	#
	# radius 20 on a 40x40 box clamps to half the smaller side, so the outer
	# edge is a circle centred at (20,20). (2,2) sits at radius 24.7, which is
	# 4.7 px outside it: a rounded rect that merely had soft corners would still
	# be lit there.
	check "a 40x40 radius-20 box is a disc: the centre is filled" "FFFFFF" \
		"$(at "$work/a.png" disc 20 20)"
	check "a 40x40 radius-20 box is a disc: the corner is cut away" "000000" \
		"$(at "$work/a.png" disc 2 2)"

	# The bordered variant. Three points, because two would not separate a ring
	# from a disc: (20,1) is at radius 18.5, inside the 17-to-20 band with 1.5 px
	# clear of either edge; (20,8) is at radius 11.5, well inside the hole; the
	# centre is the hole.
	check "the bordered variant is an annulus: the band is inked" "FFFFFF" \
		"$(at "$work/a.png" ring 20 1)"
	check "the bordered variant is an annulus: inside the band is hollow" \
		"000000" "$(at "$work/a.png" ring 20 8)"
	check "the bordered variant is an annulus: the centre is hollow" "000000" \
		"$(at "$work/a.png" ring 20 20)"
	check "the bordered variant is an annulus: the corner is cut away" \
		"000000" "$(at "$work/a.png" ring 2 2)"

	# =============================================================
	# Section 2: recolour.
	#
	# The fixture is opaque on its left half only, so x+10 lands in the image
	# and x+30 lands in its transparent half. Every cell is asserted at both:
	# the second point is what a "fill the box" implementation fails.
	check "an untouched image keeps its own colours" "40C0F0" \
		"$(at "$work/a.png" plain 10 20)"
	check "an untouched image keeps its transparency" "000000" \
		"$(at "$work/a.png" plain 30 20)"

	check "a recoloured image takes the ink" "FF0000" \
		"$(at "$work/a.png" red 10 20)"
	check "a recolour is a stencil, not a fill (the clear half stays clear)" \
		"000000" "$(at "$work/a.png" red 30 20)"

	# A second ink on the SAME path: one decode, two different rasters.
	check "a second ink on the same path rasters separately" "00FF00" \
		"$(at "$work/a.png" green 10 20)"
	check "the second ink is a stencil too" "000000" \
		"$(at "$work/a.png" green 30 20)"

	# The corner clip is set before the ink and must survive it.
	check "a recoloured image still gets its corner clip: inked inside" \
		"FF0000" "$(at "$work/a.png" round 10 20)"
	check "a recoloured image still gets its corner clip: cut outside" \
		"000000" "$(at "$work/a.png" round 2 2)"

	# A partial-alpha ink composites over what is behind it. Asserted as a
	# strict inequality rather than a computed constant: it must be neither the
	# bar nor the full ink.
	faded=$(at "$work/a.png" faded 10 20)
	fr=$(printf '%d' "0x$(printf '%s' "$faded" | cut -c1-2)")
	note "a half-alpha ink reads $faded"
	if [ "$fr" -gt 0 ] && [ "$fr" -lt 255 ] && \
		[ "$(printf '%s' "$faded" | cut -c3-6)" = "0000" ]; then
		printf 'ok   a half-alpha ink composites over the bar\n     (%s)\n' \
			"$faded"
	else
		printf 'FAIL a half-alpha ink neither composited nor stayed red\n     got %s\n' \
			"$faded"
		fail=1
	fi

	# A zero-alpha ink is dropped before the renderer ever sees it, so the cell
	# is untouched rather than invisible.
	check "a zero-alpha ink is no ink at all" "40C0F0" \
		"$(at "$work/a.png" zero 10 20)"

	# The untouched path, byte for byte. Printed rather than pinned: a hash in
	# this file would go stale on any cairo or gdk-pixbuf bump. The comparison
	# is between a run before the renderer change and a run after it.
	#
	# RAW pixels, not a re-encoded png: the png writer stamps tIME and
	# date:create into the output, so hashing that hashes the clock and every
	# run disagrees with every other for no reason at all.
	set -- $(box plain)
	plain_sha=$("$im" "$work/a.png" -crop "$3x$4+$1+$2" +repage -depth 8 \
		rgba:- | sha256sum | cut -c1-16)
	note "untouched-image raw-pixel sha256: $plain_sha (compare across the change)"

	# And the same bytes at a cell that asked for a zero-alpha ink: the solver
	# dropped it, so this must be indistinguishable from the untouched cell
	# rather than merely close to it.
	set -- $(box zero)
	check "a zero-alpha ink is pixel-identical to no ink" "$plain_sha" \
		"$("$im" "$work/a.png" -crop "$3x$4+$1+$2" +repage -depth 8 rgba:- \
			| sha256sum | cut -c1-16)"

	# --- the mutation. A live cell whose ink changes must re-raster; the
	# renderer compares the command it kept against the one it just got, and an
	# ink missing from that comparison leaves a stale buffer on screen while
	# every readback reports the new value.
	eval_kiln "MUT = '#ff0000'" >/dev/null
	shoot "$work/b.png"
	check "changing a live cell's ink re-rasters it" "FF0000" \
		"$(at "$work/b.png" mut 10 20)"

	eval_kiln "MUT = nil" >/dev/null
	shoot "$work/c.png"
	check "clearing a live cell's ink re-rasters it back" "40C0F0" \
		"$(at "$work/c.png" mut 10 20)"

	# --- a non-unit scale. The ink is applied under the same transform that
	# scales the image into its box, so it is worth one leg at 2x. Boxes stay
	# logical; the sample point is doubled here and nowhere else.
	eval_kiln "core.output.set_scale('$sname', 2)" >/dev/null
	sleep 0.5
	shoot "$work/d.png"
	set -- $(box red)
	check "a recoloured image survives a 2x output scale" "FF0000" \
		"$(px "$work/d.png" "$(((($1 + 10)) * 2))" "$(((($2 + 20)) * 2))")"
	eval_kiln "core.output.set_scale('$sname', 1)" >/dev/null
	sleep 0.5
fi

# =============================================================
# Section 3: the font table.
#
# Boxes, not pixels, and OUTSIDE the ImageMagick guard for that reason. Clay
# fits a box to what the measure callback answered and this declaration adds no
# padding, so core.box on a fitted wrapper IS the measurement. The defect this
# section exists to catch is a face that reaches the raster without reaching the
# measure: text that draws bold and wraps as if it were not.

# --- the intern boundary, before any geometry.
check "a font description interns to a number" "number" \
	"$(eval_kiln 'return type(core.font("Sans Bold"))')"

# An id is write-once: the same description must come back as the same id, or
# every declare would append and the table would fill from one live widget.
check "the same description interns to the same id" "same" \
	"$(eval_kiln '
local a, b = core.font("Sans Bold"), core.font("Sans Bold")
return a == b and "same" or ("differ:" .. a .. "/" .. b)')"

# Entry 0 is the boot default. Clay passes fontId 0 for the debug view's own
# text, so 0 has to keep meaning a real face whatever a theme does.
check "the theme default is entry 0" "0" \
	"$(eval_kiln 'return core.font(require("kiln.state").theme.font)')"

# Size lives in `size`, on its own channel, set absolutely per output scale. A
# description carrying one would be silently overridden, so it is refused.
check "a description carrying a size is refused, and says where size lives" \
	"refused" \
	"$(eval_kiln '
local ok, e = pcall(core.font, "Sans Bold 14")
if ok then return "accepted" end
return tostring(e):match("size") and "refused" or ("wrong reason: " .. tostring(e))')"

# A family nothing on the system provides is NOT an error: Pango substitutes.
# Pinned so a typo stays a visual bug rather than a dead session.
check "an unknown family substitutes rather than failing" "number" \
	"$(eval_kiln 'return type(core.font("NoSuchFamilyXYZ"))')"

# --- the leg that matters.
#
# Same string, same size, one frame, two faces. Clay hashes fontId into its
# measure cache key, so the two cannot collide there; if the widths agree anyway
# then the face reached the raster and not the measure, which is the whole
# defect. Asserted as strictly wider rather than merely different, so a face
# that resolved to something absurd fails too.
resolve
note "measured widths: $(eval_kiln '
local r, s, b = core.box("reg"), core.box("same"), core.box("bold")
return string.format("reg=%s same=%s bold=%s",
  r and r.width or "nil", s and s.width or "nil", b and b.width or "nil")')"

check "a weight change alters the MEASURED width, not just the raster" "wider" \
	"$(eval_kiln '
local r, b = core.box("reg"), core.box("bold")
if r == nil or b == nil then return "missing" end
if r.width == b.width then return "same:" .. r.width end
return b.width > r.width and "wider" or ("narrower:" .. b.width .. "/" .. r.width)')"

# The control: naming the default face explicitly is the default face. This is
# what proves interning the theme default did not quietly pick a second face.
check "naming the default face measures identically to omitting it" "same" \
	"$(eval_kiln '
local r, s = core.box("reg"), core.box("same")
if r == nil or s == nil then return "missing" end
return r.width == s.width and "same" or ("differ:" .. r.width .. "/" .. s.width)')"

# --- the mutation. A live leaf whose face changes must re-measure AND
# re-raster, and must land on the SAME id the static cell got: an intern that
# appended per declare would drift here while every readback looked right.
eval_kiln 'FONT = "Sans Bold"' >/dev/null
resolve
check "a live leaf's face change re-measures to the bold width" "match" \
	"$(eval_kiln '
local m, b = core.box("mfont"), core.box("bold")
if m == nil or b == nil then return "missing" end
return m.width == b.width and "match" or ("differ:" .. m.width .. "/" .. b.width)')"

eval_kiln 'FONT = nil' >/dev/null
resolve
check "clearing it re-measures back to the default width" "match" \
	"$(eval_kiln '
local m, r = core.box("mfont"), core.box("reg")
if m == nil or r == nil then return "missing" end
return m.width == r.width and "match" or ("differ:" .. m.width .. "/" .. r.width)')"

# --- the paired raster control. The boxes above prove the measure moved; this
# proves the glyphs did too, so a table wired into the measure alone also fails.
if [ -n "$im" ]; then
	shoot "$work/f.png"
	crop() { # id -> raw-pixel sha of that element's box
		set -- $(box "$1")
		"$im" "$work/f.png" -crop "$3x$4+$1+$2" +repage -depth 8 rgba:- \
			| sha256sum | cut -c1-16
	}
	reg_sha=$(crop reg)
	check "the two faces rasterize differently too" "differ" \
		"$([ "$reg_sha" != "$(crop bold)" ] && echo differ || echo same)"
	# The default face, byte for byte. Printed rather than pinned: a hash here
	# would go stale on any pango or fontconfig bump. The comparison is between
	# a run before the change and a run after it.
	note "default-face raw-pixel sha256: $reg_sha (compare across the change)"
fi

# =============================================================
# Section 4: ellipsis.
#
# The bound a truncated run is truncated TO is the only interesting question
# here, because nothing in a text declaration carries it: a text element is
# sized to its own glyphs and its render command reports that same width, so
# there is no "available width" anywhere on the declaration side to read. What
# does bound it is the clip its parent declared, and that is a fact about the
# CLIP rather than about the text.
#
# So these legs come in two halves. The box legs assert that turning truncation
# on moves no layout at all, which is what makes it a raster property. The pixel
# legs assert it happened, and each is paired with a cell that must NOT change:
# a run that fits its clip, and a run that overflows with no clip to stop it.

# --- what the solver does with a clipped run, asserted rather than assumed,
# because the whole design rests on it: a clipping parent leaves its children at
# full size instead of compressing them to fit, so an overflowing run stays one
# long line and the clip is what cuts it.
resolve
check "a clipping parent does not compress its child: the run measures wider than its bound" \
	"wider" "$(eval_kiln '
local c, f = core.box("eclip"), core.box("efit")
if c == nil or f == nil then return "missing" end
return f.width > c.width and "wider" or ("bounded:" .. f.width .. "/" .. c.width)')"
check "so a clipped run stays ONE line whatever its wrap mode is" "same" \
	"$(eval_kiln '
local w, f = core.box("wclip"), core.box("efit")
if w == nil or f == nil then return "missing" end
return w.height == f.height and "same" or ("differ:" .. w.height .. "/" .. f.height)')"

# --- the flag moves nothing. Captured as whole boxes, so a shift in position
# fails as loudly as a change of size.
e_off=$(box eclip)
f_off=$(box efit)
w_off=$(box wclip)
eval_kiln 'ELLIP = true' >/dev/null
resolve
check "truncation leaves the clipping cell's solved box alone" "$e_off" \
	"$(box eclip)"
check "truncation leaves the MEASURED width alone" "$f_off" "$(box efit)"
check "truncation leaves the wrap control's box alone" "$w_off" "$(box wclip)"
eval_kiln 'ELLIP = nil' >/dev/null
resolve

if [ -n "$im" ]; then
	# Raw pixels, never png:-, which stamps a timestamp and makes the hash
	# track the wall clock instead of the image.
	shaxy() { # file x y w h -> raw-pixel sha of that rectangle
		"$im" "$1" -crop "$4x$5+$2+$3" +repage -depth 8 rgba:- \
			| sha256sum | cut -c1-16
	}
	# The clipped region of a cell, which for a truncated run is the whole of
	# what it is allowed to paint.
	shacell() { # file id -> sha
		set -- "$1" $(box "$2")
		shaxy "$1" "$2" "$3" "$4" "$5"
	}

	shoot "$work/e0.png"
	e0_clip=$(shacell "$work/e0.png" eclip)
	e0_words=$(shacell "$work/e0.png" wclip)
	e0_fits=$(shacell "$work/e0.png" fclip)
	e0_noclip=$(shacell "$work/e0.png" nclip)
	# The fixed-width window for the narrowing leg below. Cropping each state to
	# its own box would compare two different-sized rectangles, which always
	# differ; a window narrower than either clip compares like for like.
	set -- $(box eclip)
	ex=$1; ey=$2; eh=$4
	e0_win=$(shaxy "$work/e0.png" "$ex" "$ey" 60 "$eh")

	# CONTROL, first: two captures of one unchanged frame must be identical, or
	# every comparison below is measuring capture noise.
	shoot "$work/e0b.png"
	check "CONTROL: two captures of the same frame are byte-identical" "same" \
		"$([ "$e0_clip" = "$(shacell "$work/e0b.png" eclip)" ] \
			&& echo same || echo differ)"

	eval_kiln 'ELLIP = true' >/dev/null
	shoot "$work/e1.png"

	check "truncating an overflowing run changes what it paints" "differ" \
		"$([ "$e0_clip" != "$(shacell "$work/e1.png" eclip)" ] \
			&& echo differ || echo same)"

	# The clip is what bounds a run, so the wrap mode cannot be what decides
	# whether it truncates. Pins the solver fact the box legs asserted above.
	check "a words-wrapped run truncates too: the clip decides, not the wrap mode" \
		"differ" \
		"$([ "$e0_words" != "$(shacell "$work/e1.png" wclip)" ] \
			&& echo differ || echo same)"

	# The two cells that must not move. The first is the rounding guard: the
	# measure reports logical px and the raster works in device px, so a run
	# that exactly fits must not lose its tail to a half pixel.
	check "a run that FITS its clip is untouched" "same" \
		"$([ "$e0_fits" = "$(shacell "$work/e1.png" fclip)" ] \
			&& echo same || echo differ)"
	check "a run that overflows with NO clip is untouched (no bound, no ellipsis)" \
		"same" \
		"$([ "$e0_noclip" = "$(shacell "$work/e1.png" nclip)" ] \
			&& echo same || echo differ)"

	# --- narrowing the clip alone. The text's own solved box does not move when
	# CLIPW changes (only the scissor does), so a renderer that keyed its raster
	# on the solved box alone would keep the wider buffer and simply crop it,
	# leaving the truncation mark sliced in half. Compared through the fixed
	# window, and paired with the box leg that proves the measure held still.
	e1_win=$(shaxy "$work/e1.png" "$ex" "$ey" 60 "$eh")
	f_wide=$(box efit)
	eval_kiln 'CLIPW = 60' >/dev/null
	shoot "$work/e2.png"
	check "narrowing the clip alone re-truncates the run" "differ" \
		"$([ "$e1_win" != "$(shaxy "$work/e2.png" "$ex" "$ey" 60 "$eh")" ] \
			&& echo differ || echo same)"
	check "and narrowing it did not re-measure the run" "$f_wide" "$(box efit)"

	eval_kiln 'CLIPW = 90' >/dev/null
	resolve
	# Printed rather than pinned, for the same reason as section 3's: a hash
	# here would go stale on any pango or fontconfig bump. What a reader
	# compares is one run before the change against one run after it.
	note "truncated-run raw-pixel sha256: $(shacell "$work/e1.png" eclip) (compare across the change)"
	eval_kiln 'ELLIP = nil' >/dev/null
	resolve
fi

# =============================================================
# Section 5: generated assets.
#
# The declaration layer can name an image and cannot make one, so a ramp
# arrives as a file. What has to hold is that the file is addressed by its
# CONTENT and rendered ONCE: a name that only correlates with the pixels serves
# a stale picture forever, and a second render per frame is a fork per frame.
#
# Nothing here needs the frame, so these legs run against the module rather
# than the compositor's output. The one pixel leg reads the generated FILE, not
# a capture, because "the document rendered blank" is the failure the whole
# nil-is-an-answer contract is built around and no path comparison can see it.

RAMP='linear:0,0:64,0:0,#ff0000:1,#0000ff'

# --- content addressing.
check "the same spec yields the same path" "same" \
	"$(eval_kiln "
local a = require(\"kiln.asset\")
local p = a.gradient(\"$RAMP\", 64, 64)
local q = a.gradient(\"$RAMP\", 64, 64)
if p == nil then return \"nil\" end
return p == q and \"same\" or (\"differ:\" .. p .. \"/\" .. q)")"

# The digest is over the document, so a colour nobody put in the NAME still
# names a different file. This is the leg that fails when a key is built from
# the caller's label alone.
check "changing one stop changes the path" "differ" \
	"$(eval_kiln "
local a = require(\"kiln.asset\")
local p = a.gradient(\"$RAMP\", 64, 64)
local q = a.gradient(\"linear:0,0:64,0:0,#ff0000:1,#00ff00\", 64, 64)
if p == nil or q == nil then return \"nil\" end
return p ~= q and \"differ\" or \"same\"")"

# The size is part of the document too, and it is the input a caller is most
# likely to vary while holding everything else still.
check "changing the size changes the path" "differ" \
	"$(eval_kiln "
local a = require(\"kiln.asset\")
local p = a.gradient(\"$RAMP\", 64, 64)
local q = a.gradient(\"$RAMP\", 64, 32)
if p == nil or q == nil then return \"nil\" end
return p ~= q and \"differ\" or \"same\"")"

gpath=$(eval_kiln "
local a = require(\"kiln.asset\")
return a.gradient(\"$RAMP\", 64, 64) or \"nil\"")

check "the render produced a png at the size asked for" "PNG image data 64 x 64" \
	"$(file -b "$gpath" 2>/dev/null | cut -d, -f1-2 | tr -d ',')"

# --- the one pixel leg, and it runs HERE because the leg below destroys the
# file it reads.
#
# Every path leg would pass on a document that rasterized to nothing: the name
# is right, the file exists, the size is right. Only the pixels say whether it
# is a ramp, so the two ends are read and must differ, and the middle must be
# neither of them.
if [ -n "$im" ]; then
	g_left=$(px "$gpath" 1 32)
	g_right=$(px "$gpath" 62 32)
	check "the ramp's two ends differ" "differ" \
		"$([ "$g_left" != "$g_right" ] && echo differ || echo same)"
	mid=$(px "$gpath" 32 32)
	check "and its middle is neither end" "between" \
		"$([ "$mid" != "$g_left" ] && [ "$mid" != "$g_right" ] \
			&& echo between || echo flat)"
fi

# --- exactly one render, proved by destroying the output.
#
# A mtime read would be at the mercy of filesystem granularity and a fork count
# has nowhere to be read from, but a re-render is the ONLY thing that could
# overwrite these bytes. Asking again must not.
#
# This pins the warm path, which is the one that would cost a fork per frame.
# The cold path (a file already on disk from a previous session) is the
# readable() check inside request, and it is what the two sessions of the
# battery itself exercise.
printf 'SENTINEL' > "$gpath"
svg_count_before=$(ls -1 "$work"/cache/kiln/assets/*.svg 2>/dev/null | wc -l)
check "asking again re-renders nothing" "SENTINEL" \
	"$(eval_kiln "
local a = require(\"kiln.asset\")
a.gradient(\"$RAMP\", 64, 64)
return \"\"" >/dev/null; cat "$gpath")"
# A separate claim, and NOT a second witness for the one above: a re-render
# writes the same content-addressed name, so this count cannot move on one. It
# moves when the second ask keys somewhere ELSE, which is what a digest that is
# not a pure function of the document looks like.
check "and the second ask keyed to the same document" "$svg_count_before" \
	"$(ls -1 "$work"/cache/kiln/assets/*.svg 2>/dev/null | wc -l)"

# --- a miss is an answer, and it is remembered.
check "a key nothing rendered is nil, both times" "nil/nil" \
	"$(eval_kiln '
local a = require("kiln.asset")
local p = a.path("no-such-key-00000000")
local q = a.path("no-such-key-00000000")
return tostring(p) .. "/" .. tostring(q)')"

# --- the batch protocol, which is the reason this is three calls and not one.
# Twenty glyphs are one process only if the requests can pile up before the
# flush, so a flush folded into request would pass every leg above and cost
# twenty forks at boot.
check "two requests and one flush render both" "yes/yes" \
	"$(eval_kiln '
local a = require("kiln.asset")
local d = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\">" ..
	"<rect width=\"8\" height=\"8\" fill=\"%s\"/></svg>"
local k1 = a.request("batch1", 8, 8, d:format("#123456"))
local k2 = a.request("batch2", 8, 8, d:format("#654321"))
a.flush()
local function got(k) return a.path(k) ~= nil and "yes" or "no" end
return got(k1) .. "/" .. got(k2)')"

# --- refusals. A spec the caller got wrong is a config mistake and says so;
# nil is reserved for a render that did not happen.
check "a malformed spec raises" "raised" \
	"$(eval_kiln '
local a = require("kiln.asset")
return pcall(a.gradient, "linear:nonsense", 8, 8) and "accepted" or "raised"')"
check "a radial spec is refused BY NAME, not silently dropped" "named" \
	"$(eval_kiln '
local a = require("kiln.asset")
local ok, e = pcall(a.gradient, { type = "radial", from = {0,0,0},
	to = {8,8,8}, stops = { {0,"#ff0000"}, {1,"#0000ff"} } }, 8, 8)
if ok then return "accepted" end
return tostring(e):match("linear") and "named" or ("wrong reason: " .. tostring(e))')"

# --- the decimal that has to survive a locale.
#
# Every other number in a generated document is an integer on purpose, because
# the float conversions go through sprintf and one locale formatting a decimal
# comma produces a blank picture. Opacity is the one fraction that cannot be
# avoided, so its assembly from two integers around a literal dot is asserted
# rather than trusted.
apath=$(eval_kiln '
local a = require("kiln.asset")
return a.gradient("linear:0,0:8,0:0,#ff000080:1,#0000ffff", 8, 8) or "nil"')
adoc="${apath%.png}.svg"
check "an alpha stop writes a dotted opacity" "1" \
	"$(grep -c 'stop-opacity="0\.[0-9][0-9][0-9]"' "$adoc" 2>/dev/null || true)"
check "and no number in the document carries a comma" "0" \
	"$(grep -co '[0-9],[0-9]' "$adoc" 2>/dev/null || true)"

# The pattern is "error in '", not "bus error in": the config's on_error
# override is what prints. KILN_BUS_PROBE=1 raises one real error through the
# bus pcall, so this leg MUST go red under it, which is what proves the grep can
# see a swallowed handler error at all.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("paintprobe", function() error("injected") end)
b:emit("paintprobe")' >/dev/null
fi

check "no bus errors, no tree/scene divergence, no duplicate ids" "0" \
	"$(grep -cE "error in '|tree==scene:|DUPLICATE" "$log" || true)"
check "no image decode errors" "0" \
	"$(grep -c 'image decode failed' "$log" || true)"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true

if [ "$fail" = "0" ]; then echo PASS; else echo FAIL; fi
exit "$fail"
