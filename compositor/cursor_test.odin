package compositor

import st "../seat"
import vm "../lua_runtime"
import "../layout"

import wl "../wayland"
import sp "../scene_paint"
import wlr "../wlroots"
import "core:testing"
import "base:runtime"

@(test)
cursor_requires_pointer_device :: proc(t: ^testing.T) {

	handle := wlr.wlr_output{scale = 1}
	o := Output{}
	o.handle = &handle
	o.paint.handle = &handle
	o.paint.bounds = {0, 0, 100, 100}
	o.paint.width, o.paint.height, o.paint.scale = 100, 100, 1
	s := Server{cursor_x = 10, cursor_y = 10, cursor_named = true, cursor_name = "default"}
	s.cursor_manager = st.xcursor_manager_create(nil, 24)
	if !testing.expect(t, s.cursor_manager != nil) {return}
	defer st.xcursor_manager_destroy(s.cursor_manager)
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
	s.seat = st.create(s.display, "position-test")
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
	testing.expect_value(t, s.cursor_x, f64(50))
	testing.expect_value(t, s.cursor_y, f64(40))
	cursor_position(&s, -50, 20)
	testing.expect_value(t, s.cursor_x, f64(-50))
	cursor_position(&s, transmute(f64)u64(0x7ff8000000000000), 35)
	testing.expect_value(t, s.cursor_x, f64(-50))
	testing.expect_value(t, s.cursor_y, f64(35))
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
	testing.expect_value(t, s.cursor_x, f64(-40))
	testing.expect_value(t, s.cursor_y, f64(40))
	cursor_hint(&s, 10000, 10000)
	testing.expect_value(t, s.cursor_x, f64(-40))
	wlr_output_layout_remove(s.layout, left)
	cursor_position(&s, s.cursor_x, s.cursor_y)
	testing.expect_value(t, s.cursor_x, f64(50))
	wlr_output_layout_remove(s.layout, right)
	cursor_position(&s, 999, 999)
	testing.expect_value(t, s.cursor_x, f64(50))
	testing.expect(t, left.swapchain == nil && right.swapchain == nil)
}

@(test)
mapped_pointer_relative_motion_stays_on_its_output :: proc(t: ^testing.T) {
 s:=Server{display=wl.create()}
 defer destroy(&s)
 s.seat=st.create(s.display,"mapped-pointer")
 s.backend=wlr_headless_backend_create(s.display.loop)
 s.layout=wlr.wlr_output_layout_create(s.display)
 testing.expect(t,vm.init(&s.lua))
 left:=wlr_headless_add_output(s.backend,100,100)
 right:=wlr_headless_add_output(s.backend,100,100)
 for handle,i in ([]^wlr.wlr_output{left,right}) {
  state:wlr.wlr_output_state; wlr.wlr_output_state_init(&state)
  wlr.wlr_output_state_set_enabled(&state,true)
  testing.expect(t,wlr.wlr_output_commit_state(handle,&state)); wlr.wlr_output_state_finish(&state)
  wlr.wlr_output_layout_add(s.layout,handle,i32(i)*100,0)
 }
 o:=Output{handle=left,lifetime=41}
 testing.expect(t,layout.init(&o.ui)); defer layout.destroy(&o.ui)
 append(&s.outputs,&o)
 defer { clear(&s.outputs) }
 pointer:=wlr.wlr_pointer{output_name=left.name}
 device:=Pointer{server=&s}
 input:=wlr.wlr_pointer_motion_event{pointer=&pointer,time_msec=123,delta_x=150,delta_y=20}
 s.cursor_x,s.cursor_y=50,50
 cursor_motion(&device.motion,&input)
 testing.expect_value(t,s.events[0].motion_output,u64(41))
 wl.remove_source(s.event_source); drain_pending(&s)
 testing.expect_value(t,s.cursor_x,100.0-1.0/256)
 testing.expect_value(t,s.cursor_y,f64(70))
 absolute:=wlr.wlr_pointer_motion_absolute_event{pointer=&pointer,time_msec=124,x=0.25,y=0.5}
 cursor_absolute(&device.absolute,&absolute)
 wl.remove_source(s.event_source); drain_pending(&s)
 testing.expect_value(t,s.cursor_x,f64(25)); testing.expect_value(t,s.cursor_y,f64(50))
 absolute.x=1; cursor_absolute(&device.absolute,&absolute)
 wl.remove_source(s.event_source); drain_pending(&s)
 testing.expect_value(t,s.cursor_x,100.0-1.0/256)
 pointer.output_name=nil; input.delta_x=50; input.delta_y=0
 cursor_motion(&device.motion,&input)
 testing.expect_value(t,s.events[0].motion_output,u64(0))
 wl.remove_source(s.event_source); drain_pending(&s)
 testing.expect_value(t,s.cursor_x,150.0-1.0/256)
}
