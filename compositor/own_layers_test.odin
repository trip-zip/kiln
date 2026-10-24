package compositor

import vm "../lua_runtime"
import p "../protocols"
import sh "../shells"
import wl "../wayland"
import "core:testing"

layer_test_server :: proc(output := true) -> ^Server {
	s := shell_test_server()
	s.layer_shell = sh.layer_shell_create(s.display)
	wl.listen(&s.layer_shell.events.new_surface, &s.new_layer, layer_added)
	if output {
		o := new(Output)
		o.server, o.handle = s, foreign_test_output(s)
		append(&s.outputs, o)
	}
	return s
}
layer_test_finish :: proc(s: ^Server) {
	o: ^Output
	if len(s.outputs) > 0 {o = s.outputs[0]}
	wl.unlisten(&s.new_layer)
	shell_test_finish(s)
	if o != nil {free(o)}
}
layer_test_create :: proc(
	c: ^Extension_Client,
	version: u32 = 4,
	output: u32 = 0,
	layer: u32 = 2,
) -> []u8 {
	extension_bind(c, "zwlr_layer_shell_v1", version, 17)
	extension_send(c, []u32{5, 12 << 16, 11, 17, 32 << 16, 18, 11, output, layer, 4, 0x726162})
	return extension_pump(c)
}
layer_test_initial :: proc(
	t: ^testing.T,
	s: ^Server,
	c: ^Extension_Client,
	width: u32 = 64,
	height: u32 = 48,
) -> u32 {
	extension_send(c, []u32{18, 16 << 16, width, height, 11, 8 << 16 | 6})
	events := extension_pump(c)
	testing.expect(
		t,
		extension_event(events, 18, 0) == nil,
		"only compositor policy schedules a configure",
	)
	l := s.layers[0]
	testing.expect(t, l.handle.initialized && l.handle.initial_commit && !l.mapped)
	runtime_layer_configure(s, l.id, width, height)
	events = extension_pump(c)
	configure := extension_event(events, 18, 0); assert(configure != nil)
	return wl.word_read(configure, 8)
}
layer_test_map :: proc(c: ^Extension_Client, serial: u32) {
	shell_test_buffer(c)
	extension_send(c, []u32{18, 12 << 16 | 6, serial, 11, 20 << 16 | 1, 22, 0, 0, 11, 8 << 16 | 6})
	extension_pump(c)
}

@(test)
owned_layer_configure_ack_commit_state_and_remap :: proc(t: ^testing.T) {
	s := layer_test_server(); defer layer_test_finish(s)
	c := shell_test_client(s); defer wl.connection_close(&c.peer)
	layer_test_create(&c)
	l := s.layers[0]; native := l.handle
	testing.expect(
		t,
		native.output == s.outputs[0].handle && !l.explicit_output && native.namespace == "bar",
	)
	testing.expect(t, !native.initialized && native.idle == nil)
	serial := layer_test_initial(t, s, &c)
	testing.expect_value(t, serial, u32(1))
	a := sh.layer_configure(native, 100, 80); b := sh.layer_configure(native, 120, 90)
	testing.expect(t, a == b && a == 2)
	events := extension_pump(&c)
	configure := extension_event(events, 18, 0); assert(configure != nil)
	testing.expect(
		t,
		extension_event_count(events, 18, 0) == 1 &&
		wl.word_read(configure, 12) == 120 &&
		wl.word_read(configure, 16) == 90,
	)
	extension_send(
		&c,
		[]u32 {
			18,
			12 << 16 | 6,
			b,
			18,
			12 << 16 | 1,
			13,
			18,
			12 << 16 | 2,
			30,
			18,
			24 << 16 | 3,
			2,
			3,
			4,
			5,
			18,
			12 << 16 | 4,
			2,
			18,
			12 << 16 | 8,
			3,
		},
	)
	extension_pump(&c)
	testing.expect(
		t,
		native.current.anchor == 0 &&
		native.current.layer == 2 &&
		native.current.configure_serial == 0,
	)
	testing.expect(t, native.pending.configure_serial == b && native.pending.actual_width == 120)
	shell_test_buffer(&c)
	extension_send(&c, []u32{11, 20 << 16 | 1, 22, 0, 0, 11, 8 << 16 | 6}); extension_pump(&c)
	testing.expect(
		t,
		l.mapped &&
		native.surface.mapped &&
		native.current.layer == 3 &&
		native.current.anchor == 13,
	)
	testing.expect(
		t,
		native.current.margin.top == 2 &&
		native.current.margin.right == 3 &&
		native.current.margin.bottom == 4 &&
		native.current.margin.left == 5,
	)
	testing.expect(
		t,
		native.current.exclusive_zone == 30 &&
		native.current.keyboard_interactive == 2 &&
		native.current.actual_width == 120,
	)
	testing.expect(
		t,
		s.events[len(s.events) - 1].name == "commit" && s.events[len(s.events) - 1].layer == 3,
		"set_layer reaches compositor policy on commit",
	)
	extension_send(&c, []u32{11, 8 << 16 | 6}); extension_pump(&c)
	testing.expect_value(t, native.current.committed, u32(0))
	extension_send(&c, []u32{11, 20 << 16 | 1, 0, 0, 0, 11, 8 << 16 | 6})
	events = extension_pump(&c)
	testing.expect(
		t,
		!l.mapped &&
		!native.initialized &&
		!native.initial_commit &&
		extension_event(events, 18, 0) == nil,
	)
	testing.expect(
		t,
		native.pending.desired_width == 0 &&
		native.pending.anchor == 0 &&
		native.pending.layer == 2,
	)
	serial = layer_test_initial(t, s, &c)
	extension_send(
		&c,
		[]u32{18, 12 << 16 | 6, serial, 11, 20 << 16 | 1, 22, 0, 0, 11, 8 << 16 | 6},
	); extension_pump(&c)
	testing.expect(t, l.mapped && l.epoch == 2)
}

@(test)
owned_layer_closed_resource_is_inert_and_disconnect_removes_owner :: proc(t: ^testing.T) {
	for scenario in 0 ..< 4 {
		s := layer_test_server(); defer layer_test_finish(s)
		c := shell_test_client(s); defer wl.connection_close(&c.peer)
		layer_test_create(&c)
		serial := layer_test_initial(t, s, &c)
		if scenario != 2 {layer_test_map(&c, serial)}
		l := s.layers[0].handle
		switch scenario {
		case 0:
			sh.layer_configure(l, 100, 80)
			sh.layer_close(l)
			extension_send(
				&c,
				[]u32 {
					18,
					12 << 16 | 1,
					0xffffffff,
					18,
					12 << 16 | 4,
					99,
					18,
					12 << 16 | 8,
					99,
					18,
					12 << 16 | 6,
					0,
					18,
					16 << 16,
					0,
					0,
					11,
					8 << 16 | 6,
				},
			)
			events := extension_pump(&c)
			testing.expect(
				t,
				extension_event(events, 18, 1) != nil &&
				extension_event(events, 18, 0) == nil &&
				extension_event(events, 1, 0) == nil,
			)
			testing.expect(t, wl.client_get_object(c.client, 18).data == nil && len(s.layers) == 0)
			extension_send(&c, []u32{18, 8 << 16 | 7, 11, 8 << 16})
			testing.expect(t, extension_event(extension_pump(&c), 1, 0) == nil)
		case 1:
			wl.connection_close(&c.peer); extension_pump(&c)
		case 2:
			sh.layer_configure(l, 100, 80)
			extension_send(&c, []u32{18, 8 << 16 | 7, 11, 8 << 16})
			events := extension_pump(&c)
			testing.expect(
				t,
				extension_event(events, 18, 1) == nil && extension_event(events, 1, 0) == nil,
			)
		case 3:
			extension_send(&c, []u32{17, 8 << 16 | 1, 18, 12 << 16 | 8, 0, 11, 8 << 16 | 6})
			testing.expect(
				t,
				extension_event(extension_pump(&c), 1, 0) == nil &&
				l.current.layer == 0 &&
				l.owner == nil,
			)
			wl.connection_close(&c.peer); extension_pump(&c)
		}
		testing.expect_value(t, len(s.layers), 0)
	}
}

@(test)
owned_layer_protocol_errors_and_version_gates :: proc(t: ^testing.T) {
	for scenario in 0 ..< 14 {
		s := layer_test_server(); defer layer_test_finish(s)
		c := shell_test_client(s); defer wl.connection_close(&c.peer)
		created := layer_test_create(
			&c,
			1 if scenario == 11 || scenario == 12 else 4,
			0,
			9 if scenario == 10 else 2,
		)
		if scenario == 10 {
			err := extension_event(created, 1, 0); assert(err != nil)
			testing.expect(
				t,
				wl.word_read(err, 8) == 17 &&
				wl.word_read(err, 12) == u32(p.Zwlr_Layer_Shell_V1_Error.invalid_layer),
			); continue
		}
		object, code := u32(18), u32(p.Zwlr_Layer_Surface_V1_Error.invalid_surface_state)
		switch scenario {
		case 0, 1:
			extension_send(
				&c,
				[]u32 {
					18,
					16 << 16,
					0 if scenario == 0 else 64,
					0 if scenario == 1 else 48,
					11,
					8 << 16 | 6,
				},
			)
			code = u32(p.Zwlr_Layer_Surface_V1_Error.invalid_size)
		case 2:
			extension_send(&c, []u32{18, 12 << 16 | 1, 16})
			code = u32(p.Zwlr_Layer_Surface_V1_Error.invalid_anchor)
		case 3:
			extension_send(&c, []u32{18, 12 << 16 | 8, 4})
			object, code = 17, u32(p.Zwlr_Layer_Shell_V1_Error.invalid_layer)
		case 4, 11:
			extension_send(&c, []u32{18, 12 << 16 | 4, 2 if scenario == 11 else 3})
			code = u32(p.Zwlr_Layer_Surface_V1_Error.invalid_keyboard_interactivity)
		case 5:
			extension_send(&c, []u32{18, 12 << 16 | 6, 0})
		case 6:
			serial := layer_test_initial(t, s, &c)
			extension_send(&c, []u32{18, 12 << 16 | 6, serial, 18, 12 << 16 | 6, serial})
		case 7, 8:
			if scenario == 8 {layer_test_initial(t, s, &c)}
			shell_test_buffer(&c)
			extension_send(
				&c,
				[]u32{18, 16 << 16, 64, 48, 11, 20 << 16 | 1, 22, 0, 0, 11, 8 << 16 | 6},
			)
		case 9:
			extension_send(&c, []u32{18, 12 << 16 | 9, 1}); object, code = 1, 1
		case 10:
		case 12:
			extension_send(&c, []u32{18, 12 << 16 | 8, 0}); object, code = 1, 1
		case 13:
			extension_send(&c, []u32{17, 8 << 16 | 1, 18, 12 << 16 | 8, 4})
		}
		shell_test_error(t, &c, object, code)
		testing.expect_value(t, len(s.layers), 0)
	}
}

@(test)
owned_layer_creation_output_policy_and_serial_wrap :: proc(t: ^testing.T) {
	for scenario in 0 ..< 4 {
		s := layer_test_server(scenario != 0); defer layer_test_finish(s)
		c := shell_test_client(s); defer wl.connection_close(&c.peer)
		if scenario == 1 {extension_bind(&c, "wl_output", 4, 19)}
		events := layer_test_create(&c, 4, 19 if scenario == 1 else 0)
		if scenario == 0 {
			testing.expect(t, extension_event(events, 18, 1) != nil && len(s.layers) == 0)
			continue
		}
		l := s.layers[0]
		if scenario == 1 {
			testing.expect(t, l.explicit_output && l.handle.output == s.outputs[0].handle)
			remove_layer_output(s, s.outputs[0])
			testing.expect(
				t,
				len(s.layers) == 0 && extension_event(extension_pump(&c), 18, 1) != nil,
			)
		} else if scenario == 2 {
			l.handle.serial = max(u32)
			testing.expect_value(t, layer_test_initial(t, s, &c), u32(1))
		} else {
			popup_test_parent(t, &c)
			extension_send(&c, []u32{17, 32 << 16, 14, 6, 0, 2, 4, 0x726162})
			shell_test_error(t, &c, 17, u32(p.Zwlr_Layer_Shell_V1_Error.already_constructed))
		}
	}
}

@(test)
owned_layer_anchor_zero_axes_and_exclusive_state :: proc(t: ^testing.T) {
	for vertical in ([2]bool{false, true}) {
		s := layer_test_server(); defer layer_test_finish(s)
		c := shell_test_client(s); defer wl.connection_close(&c.peer)
		layer_test_create(&c)
		extension_send(
			&c,
			[]u32 {
				18,
				12 << 16 | 1,
				7 if vertical else 13,
				18,
				12 << 16 | 2,
				30,
				18,
				24 << 16 | 3,
				2,
				3,
				4,
				5,
			},
		)
		width, height := u32(40 if vertical else 0), u32(0 if vertical else 30)
		layer_test_initial(t, s, &c, width, height)
		l := s.layers[0]
		testing.expect(
			t,
			l.handle.current.exclusive_zone == 30 &&
			l.handle.current.anchor == (7 if vertical else 13),
		)
		r: vm.Runtime
		testing.expect(t, vm.init(&r)); defer vm.destroy(&r)
		r.data = s; r.configure_layer = runtime_layer_configure
		reply := vm.evaluate(
			&r,
			`package.path='lua/?.lua;lua/?/init.lua;'..package.path
local k={defaults={}};require('kiln.layers')(k,function()end,function()end)
core.set_event_handler(function(e)
 local l={handle=e.handle,screen={name='TEST',width=400,height=300},desired_w=e.width,desired_h=e.height,anchors=e.anchors,margin=e.margin,exclusive=e.exclusive}
 k.defaults.layer(l)
 assert(require('kiln.layout').strut_edge(l)==(e.width==0 and 'top' or 'left'))
end)
return 'ready'`,
		)
		testing.expect_value(t, reply, "ready\n"); delete(reply)
		testing.expect(t, vm.deliver(&r, &s.events[len(s.events) - 1]))
		e := extension_event(extension_pump(&c), 18, 0); assert(e != nil)
		testing.expect(
			t,
			wl.word_read(e, 12) == (40 if vertical else 392) &&
			wl.word_read(e, 16) == (294 if vertical else 30),
		)
	}
}
