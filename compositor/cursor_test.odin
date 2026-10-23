package compositor

import sp "../scene_paint"
import wlr "../wlroots"
import "core:testing"
import "base:runtime"

@(test)
cursor_requires_pointer_device :: proc(t: ^testing.T) {
	cursor := wlr.wlr_cursor{x = 10, y = 10}
	handle := wlr.wlr_output{scale = 1}
	o := Output{}
	o.handle = &handle
	o.paint.handle = &handle
	o.paint.bounds = {0, 0, 100, 100}
	o.paint.width, o.paint.height, o.paint.scale = 100, 100, 1
	s := Server{cursor = &cursor, cursor_named = true, cursor_name = "default"}
	s.cursor_manager = wlr.wlr_xcursor_manager_create(nil, 24)
	if !testing.expect(t, s.cursor_manager != nil) {return}
	defer wlr.wlr_xcursor_manager_destroy(s.cursor_manager)
	defer sp.output_finish(&o.paint)
	defer delete(s.outputs)
	defer delete(s.pointers)
	append(&s.outputs, &o)
	cursor_sync(&s)
	testing.expect(t, o.paint.cursor.pixels == nil, "no pointer means no cursor raster")
	p := new(Pointer, runtime.default_context().allocator)
	p.server = &s
	append(&s.pointers, p)
	cursor_sync(&s)
	testing.expect(t, o.paint.cursor.pixels != nil, "attaching a pointer shows the image")
	pointer_destroy(&p.destroy, nil)
	testing.expect_value(t, len(s.pointers), 0)
	testing.expect(t, o.paint.cursor.pixels == nil, "removing the last pointer hides the image")
}
