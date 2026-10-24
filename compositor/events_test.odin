package compositor

import sh "../shells"


import vm "../lua_runtime"
import wl "../wayland"
import wlr "../wlroots"
import "core:strings"
import "core:testing"

@(test)
queued_snapshots_replay_order_and_shutdown :: proc(t: ^testing.T) {
	s: Server
	s.display = wl.create()
	testing.expect(t, s.display != nil)
	testing.expect(t, vm.init(&s.lua))
	reply := vm.evaluate(
		&s.lua,
		"events={};core.set_event_handler(function(e) events[#events+1]=e;collectgarbage('collect') end)",
	)
	delete(reply)

	title := strings.clone_to_cstring("first")
	defer delete(title)
	toplevel := sh.Toplevel {
		geometry = {0, 0, 30, 40},
		title  = string(title),
		app_id = "test",
	}

	view := View {
		server   = &s,
		protocol = &toplevel,
		id       = 7,
		mapped   = true,
	}
	append(&s.views, &view)
	queue_client(&view, "map")
	(([^]u8)(title))[0] = 'X'
	queue_client(&view, "metadata")
	runtime_replay(&s)
	queue_event(
		&s,
		vm.Event{class = "input", name = "motion", px = 1, output = "old", has_output = true},
	)
	queue_event(
		&s,
		vm.Event{class = "input", name = "motion", px = 2, output = "new", has_output = true},
	)
	queue_event(&s, vm.Event{class = "input", name = "button", pressed = true})
	queue_event(&s, vm.Event{class = "input", name = "motion", px = 3})
	testing.expect_value(t, len(s.events), 6)
	reply = vm.evaluate(&s.lua, "return #events")
	testing.expect_value(t, reply, "0\n")
	delete(reply)
	wl.remove_source(s.event_source)
	drain_pending(&s)
	testing.expect_value(t, len(s.events), 0)
	reply = vm.evaluate(
		&s.lua,
		`assert(events[1].name=='map' and events[1].title=='first')
assert(events[2].name=='metadata' and events[2].title=='Xirst')
assert(events[3].name=='map' and events[3].handle==7)
assert(events[4].name=='motion' and events[4].x==2 and events[4].screen=='new')
assert(events[5].name=='button' and events[6].x==3)
return #events`,
	)
	testing.expect_value(t, reply, "6\n")
	delete(reply)
	queue_client(&view, "metadata")
	queue_event(&s, vm.Event{class = "output", name = "remove", output = "gone"})
	testing.expect(t, s.event_source != nil && len(s.events) == 2)
	// No compositor resources refer to this stack view; only snapshots remain.
	clear(&s.views)
	destroy(&s)
	testing.expect(t, s.shutting_down && s.lua.state == nil)
}

@(test)
size_facts_change_once_without_dirtying :: proc(t: ^testing.T) {
	s := Server {
		display = wl.create(),
	}
	testing.expect(t, s.display != nil)
	defer destroy(&s)
	output: Output

	toplevel := sh.Toplevel {
		geometry = {0, 0, 100, 80},
	}
	view := View {
		server   = &s,
		protocol = &toplevel,
		mapped   = true,
		output   = &output,
		id       = 5,
	}
	for _ in 0 ..< 10 {record_size(&view)}
	testing.expect_value(t, len(s.events), 1)
	testing.expect_value(t, s.events[0].name, "commit_size")
	testing.expect_value(t, s.events[0].width, 100)
	toplevel.geometry.width = 200
	record_size(&view)
	testing.expect_value(t, len(s.events), 2)
	testing.expect_value(t, s.events[1].width, 200)
	testing.expect(t, !output.dirty)
	view.mapped = false
	toplevel.geometry.width = 300
	record_size(&view)
	testing.expect_value(t, len(s.events), 2)
}

@(test)
pointer_motion_precedes_enter_and_keeps_optional_fields :: proc(t: ^testing.T) {
	s := Server {
		display        = wl.create(),
		pointer_client = 7,
	}
	testing.expect(t, s.display != nil)
	defer destroy(&s)
	s.layout = wlr.wlr_output_layout_create(s.display)
	s.cursor = wlr.wlr_cursor_create()
	s.cursor_manager = wlr.wlr_xcursor_manager_create(nil, 24)
	s.seat = wlr.wlr_seat_create(s.display, "test")
	testing.expect(
		t,
		s.layout != nil && s.cursor != nil && s.cursor_manager != nil && s.seat != nil,
	)
	pointer_motion(&s, 1)
	testing.expect_value(t, len(s.events), 2)
	testing.expect_value(t, s.events[0].name, "motion")
	testing.expect_value(t, s.events[1].name, "pointer_enter")
	testing.expect(
		t,
		!s.events[0].has_output && s.events[0].handle == 0 && s.events[1].handle == 0,
	)
	pointer_motion(&s, 2)
	pointer_motion(&s, 3)
	testing.expect_value(t, len(s.events), 3)
	testing.expect_value(t, s.events[2].name, "motion")
}

@(test)
keyboard_teardown_does_not_access_destroyed_runtime :: proc(t: ^testing.T) {
	s := Server {
		shutting_down = true,
	}
	kb := Keyboard {
		server = &s,
	}
	keyboard_key(&kb.key, nil)
	keyboard_modifiers(&kb.modifiers, nil)
	testing.expect_value(t, len(s.events), 0)
}

@(test)
queued_claim_transitions_and_owned_text :: proc(t: ^testing.T) {
	s := Server {
		display = wl.create(),
	}
	testing.expect(t, s.display != nil)
	defer destroy(&s)
	s.layout = wlr.wlr_output_layout_create(s.display)
	s.cursor = wlr.wlr_cursor_create()
	s.cursor_manager = wlr.wlr_xcursor_manager_create(nil, 24)
	s.seat = wlr.wlr_seat_create(s.display, "queue")
	s.buttons = make(map[u32]bool)
	s.buttons[272] = true
	s.lua.data = &s
	s.lua.grab_keyboard, s.lua.grab_pointer = runtime_grab_keyboard, runtime_grab_pointer
	testing.expect(t, vm.init(&s.lua))
	reply := vm.evaluate(
		&s.lua,
		`package.path='lua/?.lua;lua/?/init.lua;'..package.path
K=require('kiln')
B=0
TEXT=''
AXIS=0
K.key{key='F1',press=function() B=B+1 end}
K.key{key='F6',press=function()
 G=K.keygrabber{key=function(e) if e.key=='Escape' then G:stop() else TEXT=TEXT..e.utf8 end end}
end}
K.key{key='F7',press=function()
 M=K.mousegrabber{button=function(e) if not e.pressed then M:stop() end end}
end}
K.on('input::axis',function(e) if e._claimed then AXIS=AXIS+1 end end)`,
	)
	delete(reply)
	queue_event(
		&s,
		vm.Event{class = "input", name = "key", key = "F6", pressed = true, keyboard = 1},
	)
	text := strings.clone("a")
	queue_event(
		&s,
		vm.Event {
			class = "input",
			name = "key",
			key = "a",
			utf8 = text,
			pressed = true,
			keyboard = 1,
		},
	)
	delete(text)
	queue_event(
		&s,
		vm.Event{class = "input", name = "key", key = "Escape", pressed = true, keyboard = 1},
	)
	queue_event(
		&s,
		vm.Event{class = "input", name = "key", key = "F1", pressed = true, keyboard = 1},
	)
	queue_event(
		&s,
		vm.Event{class = "input", name = "key", key = "F7", pressed = true, keyboard = 1},
	)
	wl.remove_source(s.event_source)
	drain_pending(&s)
	reply = vm.evaluate(&s.lua, "return TEXT,B,G.active,M")
	testing.expect_value(t, reply, "a\t0\tfalse\tnil\n")
	delete(reply)
	queue_event(
		&s,
		vm.Event{class = "input", name = "key", key = "F1", pressed = true, keyboard = 1},
	)
	queue_event(
		&s,
		vm.Event{class = "input", name = "key", key = "F7", pressed = true, keyboard = 1},
	)
	queue_event(
		&s,
		vm.Event {
			class = "input",
			name = "button",
			button = 1,
			pressed = false,
			native = .Button,
			code = 272,
		},
	)
	queue_event(&s, vm.Event{class = "input", name = "axis", native = .Axis, dy = 1})
	wl.remove_source(s.event_source)
	drain_pending(&s)
	reply = vm.evaluate(&s.lua, "return B,M.active,AXIS")
	testing.expect_value(t, reply, "1\tfalse\t1\n")
	delete(reply)
}

@(test)
replay_uses_current_hints_parent_and_map_lifetime :: proc(t: ^testing.T) {
	s: Server
	s.display = wl.create()
	testing.expect(t, vm.init(&s.lua))
	defer destroy(&s)

	parent_top := sh.Toplevel {
		geometry = {0, 0, 60, 70},
	}
	top := sh.Toplevel {
		geometry = {0, 0, 60, 70},
		parent = &parent_top,
		current = {fullscreen = true},
		requested = {maximized = true, minimized = true},
	}

	parent := View {
		server   = &s,
		id       = 1,
		protocol = &parent_top,
		mapped   = true,
	}
	view := View {
		server    = &s,
		id        = 2,
		protocol  = &top,
		mapped    = true,
		map_epoch = 1,
	}
	append(&s.views, &parent, &view)
	defer clear(&s.views)
	queue_client(&view, "map", true)
	testing.expect_value(t, len(s.events), 1)
	e := &s.events[0]
	testing.expect(
		t,
		e.fullscreen && !e.maximized && !e.minimized && e.parent == 1 && valid_map(&s, e),
	)
	view.mapped = false
	testing.expect(t, !valid_map(&s, e))
	view.mapped = true
	view.map_epoch += 1
	testing.expect(t, !valid_map(&s, e))
	queue_client(&view, "map")
	testing.expect(t, s.events[1].maximized && s.events[1].minimized && !s.events[1].fullscreen)
	// Real facts remain queued in order; only obsolete map snapshots are ignored.
	queue_client(&view, "metadata")
	queue_client(&view, "unmap")
	queue_client(&view, "destroy")
	expect_eval(
		t,
		&s,
		"seen={};core.set_event_handler(function(e) seen[#seen+1]=e.name end)",
		"\n",
	)
	testing.expect(t, wl.dispatch(s.display, 0))
	expect_eval(t, &s, "return table.concat(seen,',')", "map,metadata,unmap,destroy\n")
	clear(&s.views)
	append(&s.views, &view, &parent)
	runtime_replay(&s)
	testing.expect_value(t, len(s.events), 2)
	testing.expect_value(t, s.events[0].handle, u32(1))
	testing.expect_value(t, s.events[1].parent, u32(1))
}
