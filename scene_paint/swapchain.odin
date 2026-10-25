package scene_paint

import out "../outputs"
import "../gbm"
import "../gles"
import "core:fmt"

acquire_target :: proc(o: ^Output, width, height: i32) -> ^gles.Buffer {
	if len(o.handle.formats) == 0 {
		_, formats, _, ok := gles.buffer_formats(o.renderer)
		if !ok { return nil }; out.set_formats(o.handle,formats)
	}
	for format in ([]u32{gbm.XRGB8888, gbm.ARGB8888}) {
		mods: []u64
		for f in o.handle.formats { if f.format == format { mods = f.modifiers; break } }
		mods = gles.modifiers(o.renderer, format, mods)
		if len(mods) == 0 {continue}
		b := gles.acquire(&o.swapchain, o.renderer, width, height, format, mods)
		if b == nil {
			if len(o.swapchain.buffers) > 0 {return nil}
			continue
		}
		return b
	}
	fmt.eprintf("GLES: no available target for %s %dx%d\n", o.handle.name, width, height)
	return nil
}

prepare_output :: proc(o: ^Output, state: ^out.State, width, height: i32) -> bool {
	b := acquire_target(o, width, height)
	if b == nil {return false}
	defer gles.buffer_release(b)
	pass, ok := gles.begin(b)
	if !ok {return false}
	gles.clear(&pass, gles.Box{0, 0, width, height})
	if !gles.submit(&pass) {return false}
	out.set_buffer(state, b)
	return true
}

commit_target :: proc(o: ^Output, state: ^out.State) -> bool {
	if out.commit(o.handle, state) {return true}
	b := state.buffer
	if b != nil {fmt.eprintf("GLES commit failed: format 0x%x modifier 0x%x\n", b.format, b.modifier)}
	return false
}
