package compositor

import wl "../wayland"
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

foreign import cursor_test_lib "system:wlroots-0.20"
foreign cursor_test_lib {
	wlr_headless_backend_create :: proc(loop: ^wl.Loop) -> ^wlr.wlr_backend ---
	wlr_headless_add_output :: proc(backend: ^wlr.wlr_backend, width, height: u32) -> ^wlr.wlr_output ---
	wlr_output_layout_remove :: proc(layout: ^wlr.wlr_output_layout, output: ^wlr.wlr_output) ---
}

@(test)
cursor_position_preserves_layout_mapping_without_rendering :: proc(t: ^testing.T) {
	s := Server{display = wl.create()}
	defer wl.destroy(s.display)
	defer wl.destroy_clients(s.display)
	s.backend = wlr_headless_backend_create(s.display.loop)
	defer wlr.wlr_backend_destroy(s.backend)
	s.layout = wlr.wlr_output_layout_create(s.display)
	defer wlr.wlr_output_layout_destroy(s.layout)
	s.cursor = wlr.wlr_cursor_create()
	defer wlr.wlr_cursor_destroy(s.cursor)
	s.seat = wlr.wlr_seat_create(s.display, "position-test")
	left := wlr_headless_add_output(s.backend, 100, 100)
	right := wlr_headless_add_output(s.backend, 80, 60)
	for output in ([]^wlr.wlr_output{left, right}) {
		state: wlr.wlr_output_state
		wlr.wlr_output_state_init(&state)
		wlr.wlr_output_state_set_enabled(&state, true)
		testing.expect(t, wlr.wlr_output_commit_state(output, &state))
		wlr.wlr_output_state_finish(&state)
	}
	wlr.wlr_output_layout_add(s.layout, left, -100, 10)
	wlr.wlr_output_layout_add(s.layout, right, 50, 30)
	cursor_position(&s, 30, 40)
	testing.expect_value(t, s.cursor.x, f64(50))
	testing.expect_value(t, s.cursor.y, f64(40))
	cursor_position(&s, -50, 20)
	testing.expect_value(t, s.cursor.x, f64(-50))
	cursor_position(&s, transmute(f64)u64(0x7ff8000000000000), 35)
	testing.expect_value(t, s.cursor.x, f64(-50))
	testing.expect_value(t, s.cursor.y, f64(35))
	o := Output{handle = right, lifetime = 1}
	append(&s.outputs, &o)
	defer delete(s.outputs)
	pointer := wlr.wlr_pointer{output_name = right.name}
	x, y := cursor_absolute_position(&s, &pointer, 0.25, 0.5)
	testing.expect_value(t, x, f64(70))
	testing.expect_value(t, y, f64(60))
	pointer.output_name = nil
	x, y = cursor_absolute_position(&s, &pointer, 0.5, 0.5)
	testing.expect_value(t, x, f64(15))
	testing.expect_value(t, y, f64(60))
	s.seat.pointer_state.sx, s.seat.pointer_state.sy = 5, 5
	cursor_hint(&s, 15, 10)
	testing.expect_value(t, s.cursor.x, f64(-40))
	testing.expect_value(t, s.cursor.y, f64(40))
	cursor_hint(&s, 10000, 10000)
	testing.expect_value(t, s.cursor.x, f64(-40))
	wlr_output_layout_remove(s.layout, left)
	cursor_position(&s, s.cursor.x, s.cursor.y)
	testing.expect_value(t, s.cursor.x, f64(50))
	wlr_output_layout_remove(s.layout, right)
	cursor_position(&s, 999, 999)
	testing.expect_value(t, s.cursor.x, f64(50))
	testing.expect(t, left.swapchain == nil && right.swapchain == nil)
}
