package compositor

import cairo "../cairo"
import images "../images"
import readback "../readback"
import sp "../scene_paint"
import "core:fmt"

runtime_screenshot :: proc(data: rawptr, name: string, path: cstring) -> string {
	s := (^Server)(data)
	if s.lua.declaring {return ""}
	for o in s.outputs {
		if string(o.handle.name) != name || !o.handle.enabled {continue}
		// Coverage is synchronous even if lock engagement and this capture share
		// one Lua call. Never run the Lua declaration or event loop recursively.
		if locked(s) {lock_cover(s)}
		draw := sp.get_scene_output(s.scene, o.handle)
		if draw == nil {return ""}
		if locked(s) && !sp.output_commit(draw) {return ""}
		surface, ok := readback.capture(sp.target_buffer(draw.last), o.handle, s.gles)
		if !ok {return ""}
		s.screenshot_seq += 1
		key := fmt.aprintf("screenshot:%d", s.screenshot_seq)
		defer delete(key)
		entry := images.put_capture(&s.lua.images, key, surface)
		if path != nil && cairo.cairo_surface_write_to_png(surface.handle, path) != 0 {
			fmt.eprintf("screenshot: PNG write failed for %s\n", path)
		}
		return entry.path
	}
	return ""
}
