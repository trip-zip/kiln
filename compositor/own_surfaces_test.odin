package compositor

import "../buffers"

import sf "../surfaces"
import rg "../region"
import wl "../wayland"
import p "../protocols"
import "core:testing"
import "core:sys/posix"

surface_client :: proc(s: ^Server) -> Extension_Client {
	c := extension_client(s)
	for id in u32(7)..=30 { extension_send(&c,[]u32{1,12<<16,id}); extension_pump(&c) }
	return c
}
surface_server :: proc() -> ^Server {
	s := extension_server()
	assert(sf.subcompositor_create(s.display)!=nil && sf.viewporter_create(s.display)!=nil && sf.fractional_scale_create(s.display)!=nil)
	formats := [2]u32{0x34325241,0x34325258}
	assert(buffers.shm_create(s.display,2,formats[:])!=nil)
	return s
}
surface_role := sf.Role{name="test",no_object=true}
surface_object_role := sf.Role{name="test-object"}
@(test)
owned_surface_errors_and_cursor_size_exemption :: proc(t: ^testing.T) {
	for scenario in 0..<6 {
		s := surface_server(); defer extension_finish(s)
		c := surface_client(s); defer wl.connection_close(&c.peer)
		surface := sf.of(wl.client_get_object(c.client,6))
		code: u32
		switch scenario {
		case 0: extension_send(&c,[]u32{6,12<<16|8,0}); code = u32(p.Wl_Surface_Error.invalid_scale)
		case 1: extension_send(&c,[]u32{6,12<<16|7,8}); code = u32(p.Wl_Surface_Error.invalid_transform)
		case 2: extension_send(&c,[]u32{6,20<<16|1,0,1,0}); code = u32(p.Wl_Surface_Error.invalid_offset)
		case 3,4,5:
			if scenario==3 { assert(sf.set_role(surface,&surface_role,nil,0)) }
			if scenario==4 { assert(cursor_test_role(surface)) }
			shell_test_buffer(&c,63,47)
			extension_send(&c,[]u32{6,12<<16|8,2,6,20<<16|1,22,0,0,6,8<<16|6})
			code = u32(p.Wl_Surface_Error.invalid_size)
		}
		if scenario<4 { shell_test_error(t,&c,6,code) } else {
			testing.expect(t,extension_event(extension_pump(&c),1,0)==nil)
			testing.expect(t,surface.current.width==31 && surface.current.height==23)
		}
	}
}
cursor_test_role :: proc(s: ^sf.Surface) -> bool {
	return sf.set_role(s,&cursor_size_role,nil,0)
}
cursor_size_role := sf.Role{name="wl_pointer-cursor",no_object=true}
@(test)
owned_surface_buffer_release_regions_offsets_and_callbacks :: proc(t: ^testing.T) {
	s := surface_server(); defer extension_finish(s)
	c := surface_client(s); defer wl.connection_close(&c.peer)
	surface := sf.of(wl.client_get_object(c.client,6)); shell_test_buffer(&c)
	for _ in 0..<2 {
		extension_send(&c,[]u32{6,20<<16|1,22,0,0,6,8<<16|6})
		events := extension_pump(&c)
		testing.expect(t,extension_event(events,22,0)!=nil && surface.current.buffer==nil && sf.has_buffer(surface),"single buffer is released at every commit")
	}
	extension_send(&c,[]u32{5,12<<16|1,7,7,24<<16|1,2,3,12,14,7,24<<16|2,5,6,2,3,6,12<<16|5,7,7,8<<16,6,16<<16|10,4,5,6,12<<16|3,8,6,8<<16|6})
	extension_pump(&c)
	testing.expect(t,rg.contains_point(&surface.input_region,3,4) && !rg.contains_point(&surface.input_region,5,7))
	testing.expect(t,surface.current.dx==4 && surface.current.dy==5)
	extension_send(&c,[]u32{6,8<<16|6,6,12<<16|3,9,6,8<<16|6}); extension_pump(&c)
	testing.expect(t,surface.current.dx==0 && surface.current.dy==0 && len(surface.current.frame_callbacks)==2)
	wl.resource_destroy(wl.client_get_object(c.client,8))
	now := posix.timespec{tv_sec=2,tv_nsec=123000000}; sf.frame_done(surface,&now)
	events := extension_pump(&c); done := extension_event(events,9,0)
	testing.expect(t,done!=nil && wl.word_read(done,8)==2123 && len(surface.current.frame_callbacks)==0)
	extension_send(&c,[]u32{6,12<<16|5,0,6,20<<16|1,22,0,0,22,8<<16,6,8<<16|6}); extension_pump(&c)
	testing.expect(t,!sf.has_buffer(surface) && surface.current.width==0 && rg.empty(&surface.input_region),"destroyed pending buffer becomes a null attach")
}
@(test)
owned_subsurfaces_cache_order_positions_desync_and_input :: proc(t: ^testing.T) {
	s := surface_server(); defer extension_finish(s)
	c := surface_client(s); defer wl.connection_close(&c.peer)
	extension_bind(&c,"wl_subcompositor",1,7)
	extension_send(&c,[]u32{5,12<<16,8,5,12<<16,9,7,20<<16|1,10,8,6,7,20<<16|1,11,9,6})
	extension_pump(&c); shell_test_buffer(&c)
	parent := sf.of(wl.client_get_object(c.client,6)); a := sf.of(wl.client_get_object(c.client,8)); b := sf.of(wl.client_get_object(c.client,9))
	extension_send(&c,[]u32{8,20<<16|1,22,0,0,8,8<<16|6,9,20<<16|1,22,0,0,9,8<<16|6,10,16<<16|1,10,12,11,16<<16|1,15,18})
	extension_pump(&c)
	testing.expect(t,len(a.cached)==1 && a.current.width==0 && len(parent.current.above)==0)
	extension_send(&c,[]u32{6,20<<16|1,22,0,0,6,8<<16|6}); extension_pump(&c); sf.map_(parent)
	testing.expect(t,a.mapped && b.mapped && len(a.cached)==0 && parent.current.above[0].x==10)
	x,y: f64
	testing.expect(t,sf.at(parent,16,19,&x,&y)==b && x==1 && y==1)
	extension_send(&c,[]u32{10,12<<16|2,9,10,16<<16|1,20,22}); extension_pump(&c)
	testing.expect(t,sf.at(parent,16,19,&x,&y)==b && parent.current.above[0].x==10)
	extension_send(&c,[]u32{6,8<<16|6}); extension_pump(&c)
	testing.expect(t,parent.current.above[1].sub.surface==a && parent.current.above[1].x==20)
	extension_send(&c,[]u32{8,16<<16|10,3,4,8,8<<16|6,8,16<<16|10,5,6,8,8<<16|6}); extension_pump(&c)
	testing.expect_value(t,len(a.cached),2)
	extension_send(&c,[]u32{10,8<<16|5}); extension_pump(&c)
	testing.expect(t,len(a.cached)==0 && a.current.dx==5 && a.current.dy==6)
	extension_send(&c,[]u32{10,12<<16|3,6,6,8<<16|6}); extension_pump(&c)
	testing.expect_value(t,len(parent.current.below),1)
	// Client disconnect can destroy resources out of order.
	wl.resource_destroy(a.resource)
	testing.expect(t,wl.client_get_object(c.client,10).data==nil && len(parent.current.below)==0)
	wl.resource_destroy(parent.resource)
	testing.expect(t,!b.mapped && b.subsurface==nil && wl.client_get_object(c.client,11).data==nil)
}
@(test)
owned_viewport_validation_and_inert_lifetime :: proc(t: ^testing.T) {
	for scenario in 0..<7 {
		s := surface_server(); defer extension_finish(s)
		c := surface_client(s); defer wl.connection_close(&c.peer)
		extension_bind(&c,"wp_viewporter",1,7)
		extension_send(&c,[]u32{7,16<<16|1,8,6}); extension_pump(&c)
		code,object := u32(0),u32(8)
		switch scenario {
		case 0: extension_send(&c,[]u32{8,24<<16|1,0,0,0,256})
		case 1: extension_send(&c,[]u32{8,16<<16|2,0,4})
		case 2: extension_send(&c,[]u32{8,24<<16|1,0,0,384,256,6,8<<16|6}); code=1
		case 3:
			shell_test_buffer(&c); extension_send(&c,[]u32{8,24<<16|1,63*256,0,2*256,256,6,20<<16|1,22,0,0,6,8<<16|6}); code=2
		case 4: extension_send(&c,[]u32{6,8<<16,8,16<<16|2,10,10}); code=3
		case 5: extension_send(&c,[]u32{7,16<<16|1,9,6}); object=7
		case 6:
			shell_test_buffer(&c); extension_send(&c,[]u32{8,24<<16|1,0,0,16*256,12*256,8,16<<16|2,40,30,6,20<<16|1,22,0,0,6,8<<16|6}); extension_pump(&c)
			surface:=sf.of(wl.client_get_object(c.client,6)); testing.expect(t,surface.current.width==40 && surface.current.height==30)
			extension_send(&c,[]u32{8,8<<16,6,8<<16|6}); extension_pump(&c)
			testing.expect(t,surface.current.width==64 && surface.current.height==48 && !surface.current.viewport.has_src); continue
		}
		shell_test_error(t,&c,object,code)
	}
}
@(test)
owned_scale_role_recreation_and_late_output_bind :: proc(t: ^testing.T) {
	s := surface_server(); defer extension_finish(s)
	c := surface_client(s); defer wl.connection_close(&c.peer)
	surface:=sf.of(wl.client_get_object(c.client,6))
	sf.notify_scale(surface,1.25)
	extension_bind(&c,"wp_fractional_scale_manager_v1",1,7)
	extension_send(&c,[]u32{7,16<<16|1,8,6})
	e:=extension_event(extension_pump(&c),8,0); testing.expect(t,e!=nil && wl.word_read(e,8)==150)
	sf.notify_scale(surface,1.5); e=extension_event(extension_pump(&c),8,0); testing.expect(t,e!=nil && wl.word_read(e,8)==180)
	sf.notify_scale(surface,1.5); testing.expect(t,extension_event(extension_pump(&c),8,0)==nil)
	extension_send(&c,[]u32{8,8<<16}); extension_pump(&c)
	extension_send(&c,[]u32{7,16<<16|1,8,6}); e=extension_event(extension_pump(&c),8,0); testing.expect(t,e!=nil && wl.word_read(e,8)==180)
	for _ in 0..<2 {
		assert(sf.set_role(surface,&surface_object_role,nil,0))
		r:=wl.resource_create(c.client,&p.wl_callback,1,9); sf.set_role_object(surface,r); wl.resource_destroy(r)
		testing.expect(t,surface.role==&surface_object_role && surface.role_resource==nil)
	}
	testing.expect(t,!sf.set_role(surface,&surface_role,nil,0))
	o:=foreign_test_output(s)
	sf.enter(surface,o); sf.enter(surface,o)
	events:=extension_bind(&c,"wl_output",4,10)
	e=extension_event(events,6,u32(p.Wl_Surface_Event.enter)); testing.expect(t,e!=nil && wl.word_read(e,8)==10)
	events=extension_bind(&c,"wl_output",4,11)
	e=extension_event(events,6,u32(p.Wl_Surface_Event.enter)); testing.expect(t,e!=nil && wl.word_read(e,8)==11)
	sf.leave(surface,o); events=extension_pump(&c)
	count:=0
	for at:=0; at+8<=len(events); at+=int(wl.word_read(events,at+4)>>16) { if wl.word_read(events,at)==6 && wl.word_read(events,at+4)&0xffff==1 { count+=1 } }
	testing.expect_value(t,count,2)
}

@(test)
owned_nested_sync_captures_parent_state_and_releases_descendants :: proc(t: ^testing.T) {
	s:=surface_server(); defer extension_finish(s)
	c:=surface_client(s); defer wl.connection_close(&c.peer)
	extension_bind(&c,"wl_subcompositor",1,7)
	extension_send(&c,[]u32{5,12<<16,8,5,12<<16,9,7,20<<16|1,10,8,6,7,20<<16|1,11,9,8,11,8<<16|5}); extension_pump(&c)
	shell_test_buffer(&c)
	parent:=sf.of(wl.client_get_object(c.client,6)); a:=sf.of(wl.client_get_object(c.client,8)); b:=sf.of(wl.client_get_object(c.client,9))
	extension_send(&c,[]u32{9,20<<16|1,22,0,0,9,8<<16|6,11,16<<16|1,10,20,8,20<<16|1,22,0,0,8,8<<16|6,11,16<<16|1,30,40}); extension_pump(&c)
	testing.expect(t,len(a.cached)==1 && len(b.cached)==1)
	extension_send(&c,[]u32{6,20<<16|1,22,0,0,6,8<<16|6}); extension_pump(&c); sf.map_(parent)
	testing.expect(t,b.mapped && len(b.cached)==0,"a desynchronized descendant inherits its ancestor's synchronization")
	testing.expect(t,a.current.above[0].x==10 && a.current.above[0].y==20,"cached positions are independent of later requests")
	extension_send(&c,[]u32{8,8<<16|6,6,8<<16|6}); extension_pump(&c)
	testing.expect(t,a.current.above[0].x==30 && a.current.above[0].y==40)
 extension_send(&c,[]u32{9,16<<16|10,7,8,9,8<<16|6,10,8<<16|5}); extension_pump(&c)
 testing.expect(t,len(b.cached)==0 && b.current.dx==7 && b.current.dy==8,"desync releases inherited cached state without another child commit")

}
@(test)
owned_surface_role_and_extension_duplicates_are_errors :: proc(t: ^testing.T) {
	for scenario in 0..<4 {
		s:=surface_server(); defer extension_finish(s)
		c:=surface_client(s); defer wl.connection_close(&c.peer)
		object,code:=u32(7),u32(0)
		switch scenario {
		case 0:
			extension_bind(&c,"wp_fractional_scale_manager_v1",1,7)
			extension_send(&c,[]u32{7,16<<16|1,8,6,7,16<<16|1,9,6})
		case 1:
			extension_bind(&c,"wl_subcompositor",1,7)
			extension_send(&c,[]u32{7,20<<16|1,8,6,6}); code=1
		case 2:
			extension_bind(&c,"wl_subcompositor",1,7)
			extension_send(&c,[]u32{5,12<<16,8,7,20<<16|1,9,8,6,9,12<<16|2,8}); object=9
		case 3:
			surface:=sf.of(wl.client_get_object(c.client,6)); assert(sf.set_role(surface,&surface_object_role,nil,0))
			r:=wl.resource_create(c.client,&p.wl_callback,1,7); sf.set_role_object(surface,r)
			testing.expect(t,!sf.set_role(surface,&surface_object_role,surface.resource,17)); object,code=6,17
		}
		shell_test_error(t,&c,object,code)
	}
}
