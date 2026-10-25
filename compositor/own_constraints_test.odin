package compositor

import st "../seat"
import ext "../extensions"
import wl "../wayland"
import wlr "../wlroots"
import sp "../scene_paint"
import vm "../lua_runtime"
import "core:testing"

constraint_test_setup :: proc(t: ^testing.T) -> (^Server,Extension_Client) {
	s:=shell_test_server(); assert(init_constraints(s))
	c:=shell_test_client(s); popup_test_parent(t,&c)
	extension_bind(&c,"zwp_pointer_constraints_v1",1,14)
	extension_send(&c,[]u32{5,12<<16|1,15,15,24<<16|1,0,0,20,20})
	extension_pump(&c)
	return s,c
}
constraint_test_request :: proc(c: ^Extension_Client, locked: bool, lifetime: u32, id: u32=16, region: u32=15) -> []u8 {
	extension_send(c,[]u32{14,28<<16|(1 if locked else 2),id,6,4,region,lifetime})
	return extension_pump(c)
}
@(test)
owned_constraints_regions_commit_lifetimes_and_duplicate_error :: proc(t: ^testing.T) {
	for lifetime in ([]u32{1,2}) {
		s,c:=constraint_test_setup(t); defer shell_test_finish(s); defer wl.connection_close(&c.peer)
		extension_focus(s,&c)
		events:=constraint_test_request(&c,false,lifetime)
		testing.expect(t,extension_event(events,16,0)!=nil && s.active_constraint!=nil)
		constraint:=s.active_constraint
		dx,dy:=st.constraint_confine(constraint,5,5,40,10)
		testing.expect_value(t,dx,15.0-1.0/256); testing.expect_value(t,dy,f64(10))
		extension_send(&c,[]u32{5,12<<16|1,17,17,24<<16|1,0,0,8,8,16,12<<16|1,17,17,8<<16})
		extension_pump(&c)
		testing.expect(t,st.constraint_contains(constraint,15,15),"set_region waits for surface commit and copies the region")
		extension_send(&c,[]u32{6,8<<16|6}); extension_pump(&c)
		testing.expect(t,!st.constraint_contains(constraint,15,15) && st.constraint_contains(constraint,7,7))
		st.pointer_notify_clear_focus(s.seat); events=extension_pump(&c)
		testing.expect(t,extension_event(events,16,1)!=nil && s.active_constraint==nil)
		extension_focus(s,&c); events=extension_pump(&c)
		testing.expect(t,(s.active_constraint!=nil)==(lifetime==2))
		if lifetime==1 { testing.expect(t,constraint.defunct); constraint_test_request(&c,true,2,18,0) }
		extension_send(&c,[]u32{14,28<<16|2,19,6,4,0,2})
		shell_test_error(t,&c,14,1)
	}
}
@(test)
owned_lock_delivers_relative_motion_and_committed_hint_on_release :: proc(t: ^testing.T) {
	s,c:=constraint_test_setup(t); defer shell_test_finish(s); defer wl.connection_close(&c.peer)
	s.relative=ext.relative_create(s.display)
	other:=extension_client(s); defer wl.connection_close(&other.peer)
	for client in ([]^Extension_Client{&c,&other}) {
		if client==&other { for id in u32(7)..=17 { extension_send(client,[]u32{1,12<<16,id}); extension_pump(client) } }
		extension_bind(client,"zwp_relative_pointer_manager_v1",1,18)
		extension_send(client,[]u32{18,16<<16|1,19,4}); extension_pump(client)
	}
	s.backend=wlr_headless_backend_create(s.display.loop)
	handle:=wlr_headless_add_output(s.backend,100,100)
	state:wlr.wlr_output_state; wlr.wlr_output_state_init(&state)
	wlr.wlr_output_state_set_enabled(&state,true); assert(wlr.wlr_output_commit_state(handle,&state)); wlr.wlr_output_state_finish(&state)
	s.layout=wlr.wlr_output_layout_create(s.display); wlr.wlr_output_layout_add(s.layout,handle,0,0)
	o:=Output{server=s,handle=handle,lifetime=1}
	append(&s.outputs,&o)
	o.paint.bounds={0,0,100,100}; o.paint.scale=1
	append(&o.paint.parts,sp.Part{kind=.Client,id=s.views[0].id,surface=data_surface(&c),box={0,0,64,48}})
	defer sp.output_finish(&o.paint)
	st.pointer_notify_enter(s.seat,data_surface(&c),5,5); s.cursor_x,s.cursor_y=5,5
	constraint_test_request(&c,true,2)
	constraint:=s.active_constraint; assert(constraint!=nil)
	extension_send(&c,[]u32{16,16<<16|1,12*256,13*256}); extension_pump(&c)
	testing.expect(t,!constraint.current.cursor_hint.enabled)
	extension_send(&c,[]u32{6,8<<16|6}); extension_pump(&c)
	testing.expect(t,constraint.current.cursor_hint.enabled && constraint.current.cursor_hint.x==12)
	e:=vm.Event{native=.DeviceMotion,time=100,dx=30,dy=20,ux=31,uy=21}
	device_motion(s,&e)
	testing.expect(t,s.cursor_x==5 && s.cursor_y==5)
	events:=extension_pump(&c)
	testing.expect(t,extension_event(events,19,0)!=nil && extension_event(events,4,2)==nil)
	testing.expect(t,extension_event(extension_pump(&other),19,0)==nil)
	extension_send(&c,[]u32{16,8<<16}); extension_pump(&c)
	testing.expect(t,s.active_constraint==nil && s.cursor_x==12 && s.cursor_y==13,"deactivation applies the committed cursor hint")
}
@(test)
owned_constraint_input_intersection_empty_region_and_teardown :: proc(t: ^testing.T) {
	s,c:=constraint_test_setup(t); defer shell_test_finish(s); defer wl.connection_close(&c.peer)
	extension_focus(s,&c); constraint_test_request(&c,false,2,16,0)
	constraint:=s.active_constraint; assert(constraint!=nil)
	testing.expect(t,st.constraint_contains(constraint,63,47) && !st.constraint_contains(constraint,64,48))
	extension_send(&c,[]u32{5,12<<16|1,17,6,12<<16|5,17,6,8<<16|6})
	extension_pump(&c)
	testing.expect(t,s.active_constraint==nil && len(constraint.region)==0,"an empty input region cannot activate")
	extension_send(&c,[]u32{6,12<<16|5,0,6,8<<16|6}); extension_pump(&c)
	testing.expect(t,s.active_constraint!=nil,"persistent constraint can activate when the committed region permits it")
	extension_send(&c,[]u32{16,12<<16|1,17,6,8<<16|6}); extension_pump(&c)
	testing.expect(t,s.active_constraint==nil && len(constraint.region)==0,"an explicit empty constraint region is not the default region")
	extension_send(&c,[]u32{16,12<<16|1,0}); extension_pump(&c)
	testing.expect(t,s.active_constraint==nil,"resetting to the input region waits for commit")
	extension_send(&c,[]u32{6,8<<16|6}); extension_pump(&c)
	testing.expect(t,s.active_constraint!=nil)
	s.pointer_grabbed=true; constraint_sync(s)
	testing.expect(t,s.active_constraint==nil)
	s.pointer_grabbed=false; constraint_sync(s)
	testing.expect(t,s.active_constraint!=nil)
	st.destroy(s.seat); s.seat=nil
	testing.expect(t,constraint.defunct && len(s.constraint_owners)==0)
	extension_send(&c,[]u32{16,12<<16|1,0,16,8<<16})
	testing.expect(t,extension_event(extension_pump(&c),1,0)==nil,"requests on defunct resources remain harmless")
}
