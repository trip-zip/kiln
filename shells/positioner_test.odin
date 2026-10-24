package shells

import wlr "../wlroots"
import "core:testing"

@(test)
positioner_constraints_at_each_output_edge :: proc(t: ^testing.T) {
	Case :: struct {
		anchor, gravity:                    u32,
		rect:                               wlr.Box,
		raw, flip, slide, resize:           wlr.Box,
		flip_flag, slide_flag, resize_flag: u32,
	}
	cases := []Case {
		{
			3,
			3,
			{10, 140, 20, 20},
			{-90, 110, 100, 80},
			{30, 110, 100, 80},
			{0, 110, 100, 80},
			{0, 110, 10, 80},
			4,
			1,
			16,
		},
		{
			4,
			4,
			{370, 140, 20, 20},
			{390, 110, 100, 80},
			{270, 110, 100, 80},
			{300, 110, 100, 80},
			{390, 110, 10, 80},
			4,
			1,
			16,
		},
		{
			1,
			1,
			{190, 10, 20, 20},
			{150, -70, 100, 80},
			{150, 30, 100, 80},
			{150, 0, 100, 80},
			{150, 0, 100, 10},
			8,
			2,
			32,
		},
		{
			2,
			2,
			{190, 270, 20, 20},
			{150, 290, 100, 80},
			{150, 190, 100, 80},
			{150, 220, 100, 80},
			{150, 290, 100, 10},
			8,
			2,
			32,
		},
	}
	for c in cases {
		r := Positioner_Rules {
			width       = 100,
			height      = 80,
			anchor      = c.anchor,
			gravity     = c.gravity,
			anchor_rect = c.rect,
		}
		testing.expect_value(t, positioner_unconstrain(r, {0, 0, 400, 300}), c.raw)
		for adjustment, i in ([4]u32{c.flip_flag, c.slide_flag, c.resize_flag, c.flip_flag | c.slide_flag | c.resize_flag}) {
			r.adjustment = adjustment
			expected := c.flip if i == 0 || i == 3 else c.slide if i == 1 else c.resize
			testing.expect_value(t, positioner_unconstrain(r, {0, 0, 400, 300}), expected)
		}
	}
	// Oversize boxes need slide before resize, and a failed flip must preserve the initial box.
	r := Positioner_Rules {
		width       = 500,
		height      = 400,
		anchor_rect = {190, 140, 20, 20},
		adjustment  = 63,
	}
	testing.expect_value(t, positioner_unconstrain(r, {0, 0, 400, 300}), wlr.Box{0, 0, 400, 300})
	r = {
		width       = 100,
		height      = 80,
		anchor_rect = {410, 310, 20, 20},
		anchor      = 8,
		gravity     = 8,
		adjustment  = 63,
	}
	testing.expect_value(
		t,
		positioner_unconstrain(r, {0, 0, 400, 300}),
		wlr.Box{300, 220, 100, 80},
	)
	r.adjustment = 48
	testing.expect_value(
		t,
		positioner_unconstrain(r, {0, 0, 400, 300}),
		wlr.Box{430, 330, 100, 80},
	)
}

@(test)
positioner_anchors_gravities_offsets_and_parent_hints :: proc(t: ^testing.T) {
	axis := [9][2]i32{{0, 0}, {0, -1}, {0, 1}, {-1, 0}, {1, 0}, {-1, -1}, {-1, 1}, {1, -1}, {1, 1}}
	for anchor in u32(0) ..= 8 {for gravity in u32(0) ..= 8 {
			r := Positioner_Rules {
				width            = 100,
				height           = 80,
				anchor_rect      = {180, 130, 40, 40},
				anchor           = anchor,
				gravity          = gravity,
				offset_x         = 7,
				offset_y         = -9,
				reactive         = true,
				parent_width     = 400,
				parent_height    = 300,
				parent_configure = 99,
			}
			testing.expect_value(
				t,
				positioner_geometry(r),
				wlr.Box {
					157 + axis[anchor][0] * 20 + axis[gravity][0] * 50,
					101 + axis[anchor][1] * 20 + axis[gravity][1] * 40,
					100,
					80,
				},
			)
		}}
}
