#!/bin/sh
# The freshness battery: what is ON SCREEN must be what the model says, and it
# must be there NOW.
#
#   scripts/freshness-test.sh
#
# Three past defects share one shape: every structural probe passes, the model
# is correct, and the frame is still wrong. The structural parity battery cannot
# see any of them, because it asks the tree what it contains and never asks the
# screen what it shows.
#
#   draw order       a z tie let the backdrop sort above the whole in-flow tree,
#                    so the bar was painted over. core.box and core.hits both
#                    answered correctly the entire time. Only a PIXEL sees this.
#   output change    the `output change` event was dropped on the floor, so a
#                    runtime set_mode/set_scale left layer surfaces answering the
#                    old geometry until an unrelated dirty arrived.
#   property writes  a raw property write emitted property:: and marked
#                    nothing dirty, so the desktop kept a pre-mutation frame for
#                    up to a full clock tick. This is the trap that invalidates
#                    probes written the obvious way: mutate, screenshot, capture
#                    the OLD frame, conclude the mutation did nothing.
#
# The staleness legs all follow one rule: MUTATE, then screenshot WITHOUT a
# core.dirty and without waiting out a clock tick. A leg that dirties by hand is
# testing the renderer, not the runtime, and would have passed on the bug.
#
# Boots kilnrc.lua, which carries the bar, taglist and backdrop these legs are
# about, headless, one output.
#
# Needs: a built ./build/kiln. The pixel legs need ImageMagick and skip
# gracefully without it; the signal and byte-compare legs always run.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
rc="$repo/kilnrc.lua"
work="$(mktemp -d /tmp/kiln-freshness-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
wall="$work/wall.png"
kiln_pid=""

# A 64x64 solid #FF00FF PNG. The draw-order probe below boots the backdrop with
# THIS as its wallpaper, so the colour the backdrop is made of appears nowhere
# in the theme and no coincidence can make the discriminator pass. Decoded
# inline so the battery stays self-contained.
base64 -d > "$wall" <<'B64'
iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAATElEQVR42u3PMQkAAAwDsPo33Uno
PQjEQNL0tQgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgILAdB
p+HSRtACMAAAAABJRU5ErkJggg==
B64

demo_pid=""
cleanup() {
	[ -n "$demo_pid" ] && kill "$demo_pid" 2>/dev/null || true
	[ -n "$kiln_pid" ] && kill "$kiln_pid" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

fail=0
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   %s\n     (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s\n     expected %s\n     got      %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

eval_kiln() { KILN_SOCK="$sock" "$repo/scripts/kiln-eval" "$1"; }

im=""
if command -v magick > /dev/null 2>&1; then
	im="$(command -v magick)"
elif command -v convert > /dev/null 2>&1; then
	im="$(command -v convert)"
fi

# One pixel, as six hex digits. Coordinates are DEVICE pixels: the screenshot is
# the output's buffer, so a scaled output needs logical * scale before it lands
# here. This battery pins scale 1 and asserts it, rather than doing that math.
px() { # file x y
	"$im" "$1" -format "%[hex:p{$2,$3}]" info: 2>/dev/null | head -c 6
}

# No subshell around the boot: $! must be the kiln process itself, so cleanup's
# kill lands on it and not a wrapping shell that would orphan kiln to init.
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	KILN_WALLPAPER="$wall" \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

check "the compositor booted" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"

name="$(eval_kiln 'return core.output.list()[1].name')"
check "one headless output, named" "yes" \
	"$([ -n "$name" ] && echo yes || echo no)"
check "scale is 1 (device px == logical px for the probes below)" "1" \
	"$(eval_kiln 'return core.output.list()[1].scale')"

# =====================================================================
# Draw order: the bar strip is not the backdrop.
#
# The strip is derived, never hardcoded: the workarea's top edge IS the bottom
# of the reserved chrome, so rows above it are the bar and a row below it is
# backdrop. A z tie once let the backdrop sort above the in-flow tree and paint
# the strip flat, while every structural probe still passed.

if [ -z "$im" ]; then
	echo "info the draw-order probe needs ImageMagick; skipped"
else
	shot="$work/bar.png"
	eval_kiln "core.screenshot('$name', '$shot')" >/dev/null
	sleep 1

	box="$(eval_kiln "local b = core.box('workarea:$name')
if b == nil then return 'absent' end
return math.floor(b.x + b.width / 2) .. ' ' .. math.floor(b.y) .. ' ' ..
	math.floor(b.y + b.height / 2)")"
	check "the workarea box resolves (the bar reserved its strut)" "yes" \
		"$([ "$box" != "absent" ] && [ -n "$box" ] && echo yes || echo no)"

	cx="$(echo "$box" | cut -d' ' -f1)"
	top="$(echo "$box" | cut -d' ' -f2)"
	mid="$(echo "$box" | cut -d' ' -f3)"

	check "the bar reserved a non-zero strip" "yes" \
		"$([ "${top:-0}" -gt 0 ] 2>/dev/null && echo yes || echo no)"

	# THE DRAW-ORDER ASSERT, made against the whole strip rather than one
	# pixel. A single sample is not enough: the bar's widget rows and the
	# desktop happen to share a theme color, so a probe can land on a matching
	# pixel in a perfectly healthy bar (it did, while this battery was written).
	#
	# The strip must not be flat, and it must contain NO backdrop pixel at all.
	# The backdrop is a magenta wallpaper here, not a theme color, which is what
	# makes the second half of that a real question. Comparing the strip's
	# dominant color against the sampled desktop color, as this leg first did,
	# only discriminated while the backdrop was itself broken: with the
	# background band occluded the desktop showed the runtime's bg2 rather than
	# the backdrop's own bg, so the two happened to differ. Once a config's
	# backdrop actually reached the frame the desktop became th.bg, kilnrc paints
	# its bar th.bg as well, and the row failed on a healthy bar. A color the
	# theme never uses cannot fail that way in either direction.
	sw="$(eval_kiln 'return screen.all()[1].width or 0')"
	crop="${sw}x${top}+0+0"
	strip_uniq="$("$im" "$shot" -crop "$crop" +repage -unique-colors \
		-format "%w" info: 2>/dev/null)"
	strip_wall="$("$im" "$shot" -crop "$crop" +repage -format %c -depth 8 \
		histogram:info: 2>/dev/null | grep -ci '#FF00FF' || true)"
	back_px="#$(px "$shot" "$cx" "$mid")"

	check "draw order: the bar strip is not a solid fill" "yes" \
		"$([ "${strip_uniq:-0}" -gt 1 ] 2>/dev/null && echo yes || echo no)"
	# Non-vacuity: the backdrop has to be reaching the frame somewhere, or "no
	# wallpaper pixel in the strip" would pass on a compositor drawing nothing.
	check "draw order: the backdrop reaches the desktop (the probe is real)" "#FF00FF" \
		"$back_px"
	check "draw order: no backdrop pixel reaches the bar strip" "0" "${strip_wall:-x}"
fi

# =====================================================================
# Output change: a runtime mode change is answered, not dropped.
#
# The dispatch handled `output add` and `output remove` only. Note this leg does
# NOT install its own event handler: replacing the dispatcher would test the
# harness instead of the branch. It listens on the screen class bus, which is
# what the branch actually reaches.

eval_kiln '_G.__chg = 0
screen.on("changed", function(s) _G.__chg = _G.__chg + 1 end)
return "installed"' >/dev/null

eval_kiln "core.output.set_mode('$name', 1280, 720)" >/dev/null
sleep 0.6

check "output change: set_mode reaches the runtime as a screen changed signal" "1" \
	"$(eval_kiln 'return _G.__chg')"
check "output change: the mode took (list() reports it)" "1280 720" \
	"$(eval_kiln 'local o = core.output.list()[1]
return o.width .. " " .. o.height')"

# The re-declare must have happened by now WITHOUT anyone dirtying by hand: the
# screen's own geometry is re-seeded from C on each declare, so a stale
# screen.width means no declare ran.
check "output change: the screen re-declared at the new geometry" "1280 720" \
	"$(eval_kiln 'local s = screen.all()[1]
return (s.width or 0) .. " " .. (s.height or 0)')"

if [ -n "$im" ]; then
	shot2="$work/mode.png"
	eval_kiln "core.screenshot('$name', '$shot2')" >/dev/null
	sleep 1
	check "output change: the frame is at the new mode, not the old one" "yes" \
		"$(file -b "$shot2" | grep -q '1280 x 720' && echo yes || echo no)"
fi

# =====================================================================
# Property writes: a raw property write re-declares, with no hand dirty.
#
# The rule for both legs: write the property, then screenshot. No core.dirty,
# no sleeping out a clock tick. When the write does not mark anything dirty the
# second capture is byte-identical to the first, because nothing re-declared.

if [ -z "$im" ]; then
	echo "info the property-write frame compare needs ImageMagick; skipped"
else
	before="$work/p0.png"
	eval_kiln "core.screenshot('$name', '$before')" >/dev/null
	sleep 1

	# tag.name: the taglist renders it, for EVERY tag, not just the selected
	# one. Nothing dirtied on this write.
	check "property writes: a tag to rename exists" "yes" \
		"$(eval_kiln 'local s = screen.all()[1]
return (s.tags[1] ~= nil) and "yes" or "no"')"
	eval_kiln 'screen.all()[1].tags[1].name = "ZZZZ"' >/dev/null
	sleep 0.6
	after="$work/p1.png"
	eval_kiln "core.screenshot('$name', '$after')" >/dev/null
	sleep 1

	if cmp -s "$before" "$after"; then
		printf 'FAIL property writes: `t.name = ...` re-declares without a hand dirty\n'
		printf '     the frame is byte-identical after the write: nothing marked dirty\n'
		fail=1
	else
		printf 'ok   property writes: `t.name = ...` re-declares without a hand dirty\n     (frame changed)\n'
	fi

	# t.selected = true: the exact probe shape that reads a stale frame when the
	# write does not dirty. `selected` is derived from the screen's selection,
	# so this leg asserts the write LANDS at all before it asserts the frame
	# moved.
	eval_kiln 'local s = screen.all()[1]
s.selected_tags = { s.tags[1] }
return "reset"' >/dev/null
	sleep 0.6
	sel0="$work/s0.png"
	eval_kiln "core.screenshot('$name', '$sel0')" >/dev/null
	sleep 1

	check "property writes: tag 2 starts unselected" "false" \
		"$(eval_kiln 'return tostring(screen.all()[1].tags[2].selected)')"
	eval_kiln 'screen.all()[1].tags[2].selected = true' >/dev/null
	sleep 0.6
	check "property writes: t.selected = true actually selects the tag" "true" \
		"$(eval_kiln 'return tostring(screen.all()[1].tags[2].selected)')"

	sel1="$work/s1.png"
	eval_kiln "core.screenshot('$name', '$sel1')" >/dev/null
	sleep 1
	if cmp -s "$sel0" "$sel1"; then
		printf 'FAIL property writes: `t.selected = true` re-declares without a hand dirty\n'
		printf '     the frame is byte-identical after the write: nothing marked dirty\n'
		fail=1
	else
		printf 'ok   property writes: `t.selected = true` re-declares without a hand dirty\n     (frame changed)\n'
	fi
fi

# =====================================================================
# The background band through the protocol path.
#
# layout.lua maps the zwlr background layer into the same band the wallpaper
# recipe declares in (layer_band). Before the root's fill joined the band, an
# opaque plane at z 0 covered all of it, so every wallpaper daemon's surface
# was invisible and no battery looked. This leg maps a real layer-shell client
# on the background layer and asserts its pixels reach the frame.
#
# The tie semantic is asserted, not implied: the protocol surface declares
# after the config's own backdrop at the same band z, so the stable sort puts
# the daemon's surface over the recipe wallpaper.
#
# Residual gap, named: gtk4-layer-shell stands in for a wallpaper daemon
# (swaybg walks the identical zwlr path but is not installed here), and
# seat-driven interaction with a layer surface stays TTY-manual (headless has
# no input devices).

demo="$(command -v gtk4-layer-demo || true)"
if [ -z "$im" ] || [ -z "$demo" ]; then
	echo "info the protocol-path probe needs ImageMagick and gtk4-layer-demo; skipped"
else
	wldisp="$(grep -o 'WAYLAND_DISPLAY=[^ ]*' "$log" | head -1 | cut -d= -f2)"

	box="$(eval_kiln "local b = core.box('workarea:$name')
if b == nil then return 'absent' end
return math.floor(b.x + b.width / 2) .. ' ' .. math.floor(b.y + b.height / 2)")"
	dx="$(echo "$box" | cut -d' ' -f1)"
	dy="$(echo "$box" | cut -d' ' -f2)"

	pre="$work/proto0.png"
	eval_kiln "core.screenshot('$name', '$pre')" >/dev/null
	sleep 1
	# Non-vacuity: the band is visible via the NATIVE path before the client
	# maps, or a changed pixel below could not be attributed to the client.
	check "wallpaper: the recipe wallpaper holds the desktop before the client" \
		"FF00FF" "$(px "$pre" "$dx" "$dy")"

	WAYLAND_DISPLAY="$wldisp" "$demo" -l background -a lrtb \
		> "$work/demo.log" 2>&1 &
	demo_pid=$!
	sleep 3

	post="$work/proto1.png"
	eval_kiln "core.screenshot('$name', '$post')" >/dev/null
	sleep 1
	check "wallpaper: the background-layer surface is in the hit list" "yes" \
		"$(eval_kiln "for _, n in ipairs(core.hits('$name', $dx, $dy)) do
	if n.name == 'layer' then return 'yes' end
end
return 'no'")"
	check "wallpaper: its pixels reach the frame (it takes the band tie)" "yes" \
		"$([ "$(px "$post" "$dx" "$dy")" != "FF00FF" ] && echo yes || echo no)"

	kill "$demo_pid" 2>/dev/null || true
	demo_pid=""
fi

eval_kiln 'core.quit()' >/dev/null 2>&1 || true

if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
