package scene_paint

import images "../images"
import layout "../layout"
import paint "../paint"
import wlr "../wlroots"
import "core:c"
import "core:testing"

@(test)
ring_tiles_preserve_holes_and_release_buffers :: proc(t: ^testing.T) {
	before, bytes := live_buffers, live_bytes

	fonts: paint.Fonts
	defer paint.destroy_fonts(&fonts)
	command := layout.Command {
		1,
		{0, 0, 40, 40},
		layout.Border{{1, 1, 1, 1}, {20, 20, 20, 20}, {3, 3, 3, 3}},
		{},
	}
	n, ok := create(command, &fonts)
	testing.expect(t, ok)
	testing.expect_value(t, len(n.buffers), 4)
	testing.expect_value(t, n.bytes, 40 * 40 * 4)
	for point in ([][2]f64{{2, 2}, {20, 8}, {20, 20}}) {
		testing.expect(t, fixture_alpha(n, i32(point[0]), i32(point[1])) == 0)
	}
	testing.expect(t, fixture_alpha(n, 20, 1) > 0)
	b := n.buffers[0]
	var_data: rawptr
	format: u32
	stride: c.size_t
	testing.expect(
		t,
		!wlr.wlr_buffer_begin_data_ptr_access(&b.base, 2, &var_data, &format, &stride),
	)
	testing.expect(
		t,
		wlr.wlr_buffer_begin_data_ptr_access(&b.base, 1, &var_data, &format, &stride),
	)
	testing.expect_value(t, format, 0x34325241)
	testing.expect_value(t, stride, 80)
	wlr.wlr_buffer_end_data_ptr_access(&b.base)
	wlr.wlr_buffer_lock(&b.base)
	destroy(n)
	testing.expect_value(t, live_buffers, before + 1)
	wlr.wlr_buffer_unlock(&b.base)
	testing.expect_value(t, live_buffers, before)
	testing.expect_value(t, live_bytes, bytes)
	command.box = {0, 0, 1200, 700}
	n, ok = create(command, &fonts)
	testing.expect(t, ok)
	testing.expect_value(t, n.bytes, 4 * 20 * 20 * 4)
	destroy(n)
	// Oversized widths must not overlap translucent straight edges.
	command.box = {0, 0, 5, 3}
	command.content = layout.Border{{1, 1, 1, 0.5}, {999, 1, 0, 99}, {65535, 65535, 65535, 65535}}
	n, ok = create(command, &fonts)
	testing.expect(t, ok)
	destroy(n)
	testing.expect_value(t, live_buffers, before)
	testing.expect_value(t, live_bytes, bytes)
}

@(test)
image_raster_owns_pixels_after_decode_release :: proc(t: ^testing.T) {
	before, bytes := live_buffers, live_bytes

	decoded, valid := paint.create(40, 40)
	testing.expect(t, valid)
	testing.expect(t, paint.shape(decoded, {0, 1, 0, 0.5}, {20, 20, 20, 20}, 40, 40))
	entry := images.Entry {
		surface    = decoded,
		generation = 1,
	}
	command := layout.Command {
		1,
		{0, 0, 40, 40},
		layout.Image{&entry, 1, true, {1, 0, 0, 0.5}, {}},
		{},
	}
	fonts: paint.Fonts
	defer paint.destroy_fonts(&fonts)
	n, ok := create(command, &fonts)
	testing.expect(t, ok)
	paint.destroy(decoded)
	entry.surface = {}
	testing.expect(t, fixture_alpha(n, 1, 1) == 0)
	testing.expect(t, fixture_alpha(n, 20, 20) > 0)
	testing.expect_value(t, len(n.buffers), 1)
	s := n.buffers[0].surface
	pixel := (cast([^]u32)paint.data(s))[20 * 40 + 20]
	testing.expect(t, (pixel >> 24) >= 63 && (pixel >> 24) <= 65)
	testing.expect(t, ((pixel >> 16) & 255) >= 63 && ((pixel >> 16) & 255) <= 65)
	testing.expect_value(t, pixel & 65535, 0)
	destroy(n)
	testing.expect_value(t, live_buffers, before)
	testing.expect_value(t, live_bytes, bytes)
}

@(test)
cropped_pixels_keep_source_coordinates :: proc(t: ^testing.T) {

	fonts: paint.Fonts
	defer paint.destroy_fonts(&fonts)
	cmd := layout.Command {
		1,
		{0, 0, 40, 40},
		layout.Rectangle{{1, 1, 1, 1}, {20, 20, 20, 20}},
		{{15, 0, 25, 40}, true, true},
	}
	n, ok := create(cmd, &fonts)
	testing.expect(t, ok)
	defer destroy(n)
	update(n, cmd)
	testing.expect(t, fixture_alpha(n, 16, 2) > 0)
	testing.expect(t, fixture_alpha(n, 14, 20) == 0)
	testing.expect(t, fixture_alpha(n, 39, 2) == 0)
	testing.expect_value(t, update(n, cmd), 0)
	cmd.clip.box.width = 0
	update(n, cmd)
	testing.expect(t, fixture_alpha(n, 20, 20) == 0)
	cmd.clip = {}
	update(n, cmd)
	testing.expect(t, fixture_alpha(n, 14, 20) > 0)
	testing.expect_value(t, len(n.buffers), 1)
}

@(test)
fractional_edges_raster_keys_and_crop_density :: proc(t: ^testing.T) {

	fonts: paint.Fonts
	defer paint.destroy_fonts(&fonts)
	for scale in ([3]f32{1, 1.5, 2}) {
		for x in ([4]i32{-3, 0, 1, 3}) {
			testing.expect_value(
				t,
				device_span(x, 13, scale) + device_span(x + 13, 15, scale),
				device_span(x, 28, scale),
			)
			cmd := layout.Command {
				1,
				{f32(x), 0, 41, 40},
				layout.Rectangle{{1, 1, 1, 1}, {20, 20, 20, 20}},
				{},
			}
			n, ok := create(cmd, &fonts, scale)
			testing.expect(t, ok)
			testing.expect_value(t, n.buffers[0].surface.width, device_span(x, 41, scale))
			testing.expect(t, reusable(n, cmd, scale))
			moved := cmd
			moved.box.x += 1
			testing.expect_value(t, reusable(n, moved, scale), scale != 1.5)
			cmd.clip = {{f32(x + 15), 0, 25, 40}, true, true}
			update(n, cmd)
			testing.expect_value(t, n.buffers[0].source_x, device_span(x, 15, scale))
			testing.expect_value(
				t,
				n.buffers[0].source_scale_x,
				f64(device_span(x + 15, 25, scale)) / 25,
			)
			testing.expect_value(t, update(n, cmd), 0)
			destroy(n)
		}
	}
}

@(test)
fractional_edges_match_native_float_multiplication :: proc(t: ^testing.T) {
	// wlroots rounds a float product, not a double product of float operands.
	testing.expect_value(t, device_edge(5, 1.3), 7)
	testing.expect_value(t, device_edge(-5, 1.3), -7)
	testing.expect_value(t, device_span(5, 5, 1.3), 6)
}

// Pixel assertions preserve the raster contract without making it an input path.
fixture_alpha :: proc(n: ^Node, x, y: i32) -> u8 {
	if len(n.parts) > 0 && !n.parts[0].initialized {update(n, n.command)}
	for part in n.parts {
		if !contains(part.visible, f64(x), f64(y)) {continue}
		if part.kind == .Solid {return u8(part.color[3] * 255)}
		b := part.pixels
		return paint.alpha(
			b.surface,
			x - part.visible.x + b.source_x,
			y - part.visible.y + b.source_y,
		)
	}
	return 0
}
