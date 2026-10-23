package scene_paint

import "../gbm"
import "../gles"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"
import "core:fmt"

Target :: struct {
	base:    wlr.wlr_buffer,
	buffer:  ^gles.Buffer,
	release: wl.Listener,
}

target_impl := wlr.wlr_buffer_impl {
	destroy    = target_destroy,
	get_dmabuf = target_dmabuf,
}

target_destroy :: proc "c" (base: ^wlr.wlr_buffer) {
	context = runtime.default_context()
	t := (^Target)(base)
	context.allocator = t.buffer.renderer.allocator
	wl.unlisten(&t.release)
	wlr.buffer_finish(base)
	gles.buffer_destroy(t.buffer)
	free(t)
}

target_dmabuf :: proc "c" (base: ^wlr.wlr_buffer, attrs: ^wlr.wlr_dmabuf_attributes) -> bool {
	context = runtime.default_context()
	b := (^Target)(base).buffer
	attrs^ = {
		width    = b.width,
		height   = b.height,
		format   = b.format,
		modifier = b.modifier,
		n_planes = b.n_planes,
	}
	for p, i in b.planes {attrs.fd[i], attrs.stride[i], attrs.offset[i] = p.fd, p.stride, p.offset}
	return true
}

target_released :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	wl.owner(listener, Target, "release").buffer.available = true
}

target_drop :: proc(b: ^gles.Buffer) {
	wlr.wlr_buffer_drop(&(^Target)(b.owner).base)
}

acquire_target :: proc(o: ^Output, width, height: i32) -> ^wlr.Render_Buffer {
	formats := wlr.primary_formats(o.handle, wlr.WLR_BUFFER_CAP_DMABUF)
	offered := [1]u64{0}
	for format in ([]u32{gbm.XRGB8888, gbm.ARGB8888}) {
		mods: []u64
		if formats == nil || formats.len == 0 {
			if format != gbm.XRGB8888 {continue}
			mods = offered[:]
		} else {
			for f in formats.formats[:formats.len] {
				if f.format == format {
					mods = f.modifiers[:f.len]
					break
				}
			}
		}
		mods = gles.modifiers(o.renderer, format, mods)
		if len(mods) == 0 {continue}
		b := gles.acquire(&o.swapchain, o.renderer, width, height, format, mods)
		if b == nil {
			if len(o.swapchain.buffers) > 0 {return nil}
			continue
		}
		if b.owner == nil {
			t := new(Target)
			t.buffer = b
			b.owner = t
			b.release = target_drop
			wlr.wlr_buffer_init(&t.base, &target_impl, width, height)
			wl.listen(&t.base.events.release, &t.release, target_released)
		}
		return wlr.buffer_retain(&(^Target)(b.owner).base)
	}
	fmt.eprintf("GLES: no available target for %s %dx%d\n", o.handle.name, width, height)
	return nil
}

target_buffer :: proc(buffer: ^wlr.Render_Buffer) -> ^gles.Buffer {
	if buffer == nil {return nil}
	return (^Target)(buffer).buffer
}

prepare_output :: proc(o: ^Output, state: ^wlr.wlr_output_state, width, height: i32) -> bool {
	b := acquire_target(o, width, height)
	if b == nil {return false}
	defer wlr.buffer_release(b)
	pass, ok := gles.begin(target_buffer(b))
	if !ok {return false}
	gles.clear(&pass, gles.Box{0, 0, width, height})
	if !gles.submit(&pass) {return false}
	wlr.output_buffer(state, b)
	return true
}

commit_target :: proc(o: ^Output, state: ^wlr.wlr_output_state) -> bool {
	if wlr.wlr_output_commit_state(o.handle, state) {return true}
	b := target_buffer(state.buffer)
	if b != nil {fmt.eprintf("GLES commit failed: format 0x%x modifier 0x%x\n", b.format, b.modifier)}
	return false
}
