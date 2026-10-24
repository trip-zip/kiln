package gles

import "../gbm"
import wlr "../wlroots"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import gl "vendor:OpenGL"
import egl "vendor:egl"

@(test)
render_node_lookup_matches_drm_device :: proc(t: ^testing.T) {
	entries, err := os.read_all_directory_by_path("/dev/dri", context.temp_allocator)
	cards, renders: int
	for entry in entries {
		if strings.has_prefix(entry.name, "card") {cards += 1}
		if strings.has_prefix(entry.name, "renderD") {renders += 1}
	}
	if err != nil || cards == 0 || renders == 0 {
		fmt.println("SKIP render node lookup: /dev/dri has no card/render pair")
		return
	}
	for entry in entries {
		if !strings.has_prefix(entry.name, "card") && !strings.has_prefix(entry.name, "renderD") {continue}
		device: posix.stat_t
		if !testing.expect(t, posix.stat(fmt.ctprintf("/dev/dri/%s", entry.name), &device) == .OK) {continue}
		directory := drm_directory(device.st_rdev)
		node, ok := render_node(directory)
		if !testing.expect(t, ok) {continue}
		if node == "" && strings.has_prefix(entry.name, "card") {
			fmt.printf("Render node lookup: %s has no render node\n", entry.name)
			continue
		}
		if !testing.expect(t, node != "") {continue}
		if strings.has_prefix(entry.name, "renderD") {testing.expect_value(t, node, entry.name)}
		render, source_device, render_device: posix.stat_t
		testing.expect(t, posix.stat(fmt.ctprintf("/dev/dri/%s", node), &render) == .OK)
		testing.expect(t, posix.stat(fmt.ctprintf("%s/..", directory), &source_device) == .OK)
		testing.expect(t, posix.stat(fmt.ctprintf("%s/..", drm_directory(render.st_rdev)), &render_device) == .OK)
		testing.expect_value(t, source_device.st_dev, render_device.st_dev)
		testing.expect_value(t, source_device.st_ino, render_device.st_ino)
		fmt.printf("Render node lookup: /dev/dri/%s -> %s -> /dev/dri/%s (same device)\n", entry.name, directory, node)
	}
}

@(test)
lost_renderer_rejects_gpu_work :: proc(t: ^testing.T) {
	r := Renderer{lost = true}
	b := Buffer{renderer = &r, width = 1, height = 1}
	_, ok := begin(&b)
	testing.expect(t, !ok)
	p := Pass{buffer = &b}
	testing.expect(t, !submit(&p))
	pixels: [4]u8
	testing.expect(t, !read_region(&r, &b, &pixels[0], 4, {0, 0, 1, 1}))
	tex := Texture{renderer = &r}
	testing.expect(t, !upload(&tex, nil, true))
	native: wlr.wlr_buffer
	testing.expect(t, import_buffer(&r, &native) == nil)
	gamma: Gamma
	testing.expect(t, !gamma_update(&r, &gamma, nil))
	fmt.println("Lost renderer: begin, submit, readback, upload, import and gamma reject work before calling GL")
}

Test_Pixels :: struct {
	base:   wlr.wlr_buffer,
	pixels: [16]u8,
}

test_impl := wlr.wlr_buffer_impl {
	destroy               = test_destroy,
	begin_data_ptr_access = test_access,
	end_data_ptr_access   = test_end,
}

test_destroy :: proc "c" (b: ^wlr.wlr_buffer) {
	context = runtime.default_context()
	wlr.buffer_finish(b)
}

test_end :: proc "c" (b: ^wlr.wlr_buffer) {
	context = runtime.default_context()
}

test_access :: proc "c" (
	b: ^wlr.wlr_buffer,
	flags: u32,
	data: ^rawptr,
	format: ^u32,
	stride: ^c.size_t,
) -> bool {
	context = runtime.default_context()
	data^ = &(^Test_Pixels)(b).pixels[0]
	format^ = gbm.XRGB8888
	stride^ = 8
	return true
}

@(test)
rect_texture_damage_and_readback :: proc(t: ^testing.T) {
	fd: i32 = -1
	for i in 128 ..< 256 {
		fd = i32(posix.open(fmt.ctprintf("/dev/dri/renderD%d", i), {.RDWR, .CLOEXEC}))
		if fd >= 0 {break}
	}
	if fd < 0 {
		fmt.println("SKIP GLES: no render node opens")
		return
	}
	defer posix.close(posix.FD(fd))
	r := create(fd)
	if !testing.expect(t, r != nil, "GBM EGL renderer") {return}
	defer destroy(r)
	if has(string(egl.QueryString(r.display, egl.EXTENSIONS)), "EGL_EXT_create_context_robustness") &&
	   has(string(cstring(gl.GetString(gl.EXTENSIONS))), "GL_KHR_robustness") {
		strategy: i32
		gl.GetIntegerv(gl.RESET_NOTIFICATION_STRATEGY, &strategy)
		testing.expect_value(t, strategy, i32(gl.LOSE_CONTEXT_ON_RESET))
		testing.expect(t, r.reset_status != nil)
		fmt.printf("GLES robustness: GL reset notification strategy 0x%x (LOSE_CONTEXT_ON_RESET)\n", strategy)
	}
	mods := [1]u64{0}
	b := buffer_create(r, 16, 12, gbm.XRGB8888, mods[:])
	if !testing.expect(t, b != nil, "GBM framebuffer") {return}
	defer buffer_destroy(b)
	pixels: Test_Pixels
	pixels.pixels = {0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0}
	wlr.wlr_buffer_init(&pixels.base, &test_impl, 2, 2)
	defer {
		if !pixels.base.dropped {wlr.wlr_buffer_drop(&pixels.base)}
	}
	tex := import_buffer(r, &pixels.base)
	if !testing.expect(t, tex != nil) {return}
	testing.expect(t, tex == import_buffer(r, &pixels.base), "cache identity")
	p, ok := begin(b)
	testing.expect(t, ok)
	clear(&p, Box{0, 0, 16, 12})
	clips := [1]Box{{0, 0, 16, 12}}
	rect(&p, Box{1, 2, 4, 3}, {1, 0, 0, 1}, clips[:])
	texture(&p, tex, FBox{0, 0, 2, 2}, Box{8, 4, 2, 2}, clips[:])
	testing.expect(t, submit(&p))
	out: [16 * 12 * 4]u8
	testing.expect(t, read(r, b, &out[0], 64))
	testing.expect_value(t, out[(2 * 16 + 1) * 4 + 2], u8(255))
	testing.expect_value(t, out[(1 * 16 + 1) * 4 + 2], u8(0))
	testing.expect_value(t, out[(4 * 16 + 8) * 4 + 2], u8(255))
	testing.expect_value(t, out[(5 * 16 + 8) * 4], u8(255))
	testing.expect_value(t, out[(4 * 16 + 8) * 4 + 3], u8(255))
	// Corner colors distinguish both quarter turns and all four reflected transforms.
	expected := [8][4]u8 {
		{0, 0, 255, 255},
		{0, 255, 0, 255},
		{255, 255, 255, 255},
		{255, 0, 0, 255},
		{0, 255, 0, 255},
		{0, 0, 255, 255},
		{255, 0, 0, 255},
		{255, 255, 255, 255},
	}
	for color, tr in expected {
		p, ok = begin(b)
		testing.expect(t, ok)
		texture(&p, tex, FBox{0, 0, 2, 2}, Box{8, 4, 2, 2}, clips[:], i32(tr))
		testing.expect(t, submit(&p))
		testing.expect(t, read(r, b, &out[0], 64))
		for v, i in color {testing.expect_value(t, out[(4 * 16 + 8) * 4 + i], v)}
	}
	copy(pixels.pixels[0:4], []u8{255, 255, 0, 0})
	damage := [1]Box{{0, 0, 1, 1}}
	update(r, &pixels.base, damage[:])
	p, ok = begin(b)
	testing.expect(t, ok)
	texture(&p, tex, FBox{0, 0, 2, 2}, Box{8, 4, 2, 2}, clips[:])
	testing.expect(t, submit(&p))
	testing.expect(t, read(r, b, &out[0], 64))
	testing.expect_value(t, out[(4 * 16 + 8) * 4], u8(255))
	testing.expect_value(t, out[(4 * 16 + 8) * 4 + 1], u8(255))
	testing.expect_value(t, out[(4 * 16 + 9) * 4 + 1], u8(255))
	rgba: [16 * 12 * 4]u8
	r.bgra = false
	testing.expect(t, read(r, b, &rgba[0], 64))
	testing.expect_value(t, rgba, out)
	// The same output LUT survives repeated passes; changing and clearing it changes pixels.
	gamma: Gamma
	defer gamma_finish(&gamma)
	table := [6]u16{65535, 0, 65535, 0, 65535, 0}
	testing.expect(t, gamma_update(r, &gamma, table[:]))
	name, storage := gamma.name, raw_data(gamma.table)
	testing.expect(t, gamma_update(r, &gamma, table[:]))
	testing.expect_value(t, gamma.name, name)
	testing.expect_value(t, raw_data(gamma.table), storage)
	for _ in 0 ..< 2 {
		p, ok = begin(b, gamma)
		testing.expect(t, ok)
		rect(&p, Box{0, 0, 4, 4}, {1, 0, 0, 1}, clips[:])
		testing.expect(t, submit(&p))
		testing.expect(t, read(r, b, &out[0], 64))
		testing.expect_value(t, out[0], u8(255))
		testing.expect_value(t, out[1], u8(255))
		testing.expect_value(t, out[2], u8(0))
	}
	table = {0, 65535, 0, 65535, 0, 65535}
	testing.expect(t, gamma_update(r, &gamma, table[:]))
	p, ok = begin(b, gamma)
	testing.expect(t, ok)
	rect(&p, Box{0, 0, 4, 4}, {1, 0, 0, 1}, clips[:])
	testing.expect(t, submit(&p))
	testing.expect(t, read(r, b, &out[0], 64))
	testing.expect_value(t, out[0], u8(0))
	testing.expect_value(t, out[1], u8(0))
	testing.expect_value(t, out[2], u8(255))
	testing.expect(t, gamma_update(r, &gamma, nil))
	testing.expect(t, gamma.name == 0 && len(gamma.table) == 0)

	texture_retain(tex)
	wlr.wlr_buffer_drop(&pixels.base)
	testing.expect_value(t, len(r.textures), 0)
	testing.expect(t, tex.buffer == nil && tex.pins == 1)
	texture_release(tex)
}

@(test)
gamma_and_transform_inverses :: proc(t: ^testing.T) {
	lut := gamma_lut([]u16{0, 65535, 32768, 65535, 65535, 0})
	defer delete(lut)
	testing.expect_value(t, lut[0], u8(0))
	testing.expect_value(t, lut[1], u8(128))
	testing.expect_value(t, lut[2], u8(255))
	testing.expect_value(t, lut[4], u8(255))
	for tr: i32 = 0; tr < 8; tr += 1 {
		testing.expect_value(t, transform_compose(tr, transform_invert(tr)), i32(0))
		v := point(.2, .7, tr)
		v = point(v[0], v[1], transform_invert(tr))
		testing.expect(t, abs(v[0] - .2) < .00001 && abs(v[1] - .7) < .00001)
	}
}
