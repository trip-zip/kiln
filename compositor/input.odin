package compositor

import bk "../backend"
import out "../outputs"
import sf "../surfaces"
import st "../seat"
import sh "../shells"
import sp "../scene_paint"
import keys "../keymap"
import vm "../lua_runtime"
import pam "../pam"
import wl "../wayland"
import "base:runtime"

Keyboard :: struct {
	server:                  ^Server,
	id:                      u64,
	consumed:                map[u32]bool,
	using keyboard:          st.Keyboard,
	compose:                 ^keys.Compose,
	key_event, modifiers_event, destroy_event: wl.Listener,
}

update_capabilities :: proc(s: ^Server) {
	capabilities: u32 = 1 // Keep pointer requests available before a device is attached.
	if len(s.keyboards) > 0 {capabilities |= 2}
	st.set_capabilities(s.seat, capabilities)
}

input_added :: proc (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "new_input")
	device := (^bk.Device)(data)
	switch device.kind {
	case .Keyboard:
		km, ok := keys.create_default()
		if !ok {
			fail(s, "Failed to create keyboard map")
			return
		}
		defer keys.destroy(km)
		handle := bk.keyboard_of(device)
		kb := new(Keyboard)
		st.keyboard_init(&kb.keyboard, handle)
		if !st.keyboard_set_keymap(&kb.keyboard, km) {
			st.keyboard_finish(&kb.keyboard); free(kb)
			fail(s, "Failed to set keyboard map")
			return
		}
		st.keyboard_set_repeat_info(&kb.keyboard, 25, 600)
		kb.server, kb.handle = s, handle
		s.next_keyboard += 1
		kb.id = s.next_keyboard
		kb.compose = keys.compose_default()
		kb.consumed = make(map[u32]bool)
		append(&s.keyboards, kb)
		wl.listen(&kb.events.key, &kb.key_event, keyboard_key)
		wl.listen(&kb.events.modifiers, &kb.modifiers_event, keyboard_modifiers)
		wl.listen(&kb.events.destroy, &kb.destroy_event, keyboard_destroy)
		st.set_keyboard(s.seat, &kb.keyboard)
		update_capabilities(s)
		runtime_focus(s, s.requested_focus)
	case .Pointer:
		handle := bk.pointer_of(device)
		p := new(Pointer)
		p.server, p.device = s, device
		s.next_pointer += 1
		p.id = s.next_pointer
		append(&s.pointers, p)
		wl.listen(&device.events.destroy, &p.destroy, pointer_destroy)
		wl.listen(&handle.events.motion, &p.motion, cursor_motion)
		wl.listen(&handle.events.motion_absolute, &p.absolute, cursor_absolute)
		wl.listen(&handle.events.button, &p.button, cursor_button)
		wl.listen(&handle.events.axis, &p.axis, cursor_axis)
		wl.listen(&handle.events.frame, &p.frame, cursor_frame)
		map_pointers(s)
		cursor_sync(s)
	}
}

keyboard_key :: proc (listener: ^wl.Listener, data: rawptr) {
	kb := wl.owner(listener, Keyboard, "key_event")
	// Backend teardown releases held keys after Lua has been destroyed.
	if kb.server.shutting_down {return}
	idle_activity(kb.server)
	event := (^bk.Key_Event)(data)
	if kb.server.lock_owner == .External {
		queue_event(
			kb.server,
			vm.Event {
				native = .Key,
				keyboard = kb.id,
				time = event.time_msec,
				code = event.keycode,
				pressed = event.state == 1,
			},
		)
		return
	}
	mods := keys.modifier_mask(kb.state)
	syms := keys.symbols(kb.state, event.keycode)
	if native_vt(kb.server, syms, mods, event.state == 1) {
		kb.consumed[event.keycode] = true
		return
	}
	chords := keys.chord_symbols(kb.state, event.keycode, mods)
	matched := false
	for actual, i in syms {
		sym := actual
		if i < len(chords) {sym = chords[i]}
		matched = matched || keys.bound(kb.server.lua.bindings, sym, mods)
	}
	for actual, i in syms {
		sym := actual
		if i < len(chords) {sym = chords[i]}
		name_buf: [128]u8
		utf8_buf: [256]u8
		name, _ := keys.describe(sym, name_buf[:], utf8_buf[:])
		utf8 := keys.text(
			kb.compose,
			actual,
			event.state == 1,
			utf8_buf[:],
			kb.state,
			event.keycode,
		)
		fact := vm.Event {
			class    = "input",
			name     = "key",
			keysym   = sym,
			key      = name,
			utf8     = utf8,
			mods     = mods,
			pressed  = event.state == 1,
			keyboard = kb.id,
			time     = event.time_msec,
			code     = event.keycode,
			blocked  = (event.state == 1 && matched) || kb.server.keyboard_grabbed,
			claimed  = kb.server.keyboard_grabbed,
		}
		if kb.server.lock_owner == .Native {
			fact.class = "session"
			fact.blocked = false
			fact.claimed = false
		}
		if i == len(syms) - 1 {fact.native = .Key}
		queue_event(kb.server, fact)
		if fact.class == "session" {pam.clear_secret(utf8_buf[:])}
	}
	if len(syms) == 0 {
		queue_event(
			kb.server,
			vm.Event {
				native = .Key,
				keyboard = kb.id,
				time = event.time_msec,
				code = event.keycode,
				pressed = event.state == 1,
				blocked = kb.server.keyboard_grabbed,
			},
		)
	}
}

keyboard_modifiers :: proc (listener: ^wl.Listener, data: rawptr) {
	kb := wl.owner(listener, Keyboard, "modifiers_event")
	if kb.server.shutting_down {return}
	m := kb.modifiers
	queue_event(
		kb.server,
		vm.Event {
			native = .Modifiers,
			keyboard = kb.id,
			mask = {m.depressed, m.latched, m.locked, m.group},
			blocked = kb.server.keyboard_grabbed,
		},
	)
}

keyboard_destroy :: proc (listener: ^wl.Listener, data: rawptr) {
	kb := wl.owner(listener, Keyboard, "destroy_event")
	s := kb.server
	wl.unlisten(&kb.key_event)
	wl.unlisten(&kb.modifiers_event)
	wl.unlisten(&kb.destroy_event)
	for other, i in s.keyboards {
		if other == kb {
			ordered_remove(&s.keyboards, i)
			break
		}
	}
	if len(s.keyboards) > 0 {st.set_keyboard(s.seat, &s.keyboards[0].keyboard)}
	update_capabilities(s)
	delete(kb.consumed)
	keys.compose_destroy(kb.compose)
	free(kb)
}

hit_test :: proc(s: ^Server, x, y: f64) -> (surface: ^sf.Surface, view: ^View, sx, sy: f64) {
	handle := out.layout_output_at(s.layout, x, y)
	for output in s.outputs {
		if output.handle != handle || !output.handle.enabled {continue}
		id: u32
		surface, id, sx, sy = sp.client_at(&output.paint, x - f64(output.x), y - f64(output.y))
		for live in s.views {
			if live.id == id && live.mapped {
				view = live
				break
			}
		}
		break
	}
	return
}

pointer_motion :: proc(s: ^Server, time_msec: u32) {
	cursor_sync(s)
	if locked(s) {return}
	drag_position(s)
	queue_pointer(
		s,
		vm.Event {
			name = "motion",
			native = .Motion,
			time = time_msec,
			blocked = s.pointer_grabbed,
			claimed = s.pointer_grabbed,
		},
	)
	if !s.pointer_grabbed {
		surface, view, _, _ := hit_test(s, s.cursor_x, s.cursor_y)
		if !popup_pointer_allowed(s, surface) {surface, view = nil, nil}
		handle: u32
		if surface != nil && view != nil {handle = view.id}
		if handle != s.pointer_client {
			s.pointer_client = handle
			queue_event(s, vm.Event{class = "input", name = "pointer_enter", handle = handle})
		}
	}
}
// A published overlay may change the native target without moving the pointer.
pointer_refresh_at :: proc(
	s: ^Server,
	time_msec: u32,
	x, y: f64,
	reset_cursor := true,
	send_motion := true,
) {
	if locked(s) || s.pointer_grabbed {return}
	surface, view, sx, sy := hit_test(s, x, y)
	if !popup_pointer_allowed(s, surface) {surface, view = nil, nil}
	// Finish motion for the old focus before leave. Relative-only events can
	// otherwise stay pending in XWayland and move its cursor on the next enter.
	if s.seat.pointer_state.focused_surface != surface {st.pointer_notify_frame(s.seat)}
	handle: u32
	if view != nil && surface != nil {handle = view.id}
	if handle != s.pointer_client {
		s.pointer_client = handle
		queue_event(s, vm.Event{class = "input", name = "pointer_enter", handle = handle})
	}
	if surface == nil {
		if reset_cursor {runtime_cursor(s, "default")}
		st.pointer_notify_clear_focus(s.seat)
	} else {
		st.pointer_notify_enter(s.seat, surface, sx, sy)
		if send_motion {st.pointer_notify_motion(s.seat, time_msec, sx, sy)} else if s.seat.pointer_state.focused_surface == surface &&
		   (s.seat.pointer_state.sx != sx || s.seat.pointer_state.sy != sy) {
			// A published move changes client-local coordinates too. Updating only
			// the seat cache would suppress the next real motion as a duplicate.
			st.pointer_notify_motion(s.seat, time_msec, sx, sy)
			st.pointer_notify_frame(s.seat)
		}
	}
}

cursor_motion :: proc (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Pointer, "motion").server
	idle_activity(s)
	if locked(s) {return}
	event := (^bk.Motion_Event)(data)
	queue_event(
		s,
		vm.Event {
			native = .DeviceMotion,
			time = event.time_msec,
			pointer_device = pointer_id(s, &event.pointer.base),
			motion_output = pointer_output(s, event.pointer),
			dx = event.delta_x,
			dy = event.delta_y,
			ux = event.unaccel_dx,
			uy = event.unaccel_dy,
		},
	)
}

cursor_absolute :: proc (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Pointer, "absolute").server
	idle_activity(s)
	if locked(s) {return}
	event := (^bk.Motion_Absolute_Event)(data)
	x, y := cursor_absolute_position(s, event.pointer, event.x, event.y)
	queue_event(
		s,
		vm.Event {
			native = .DeviceMotion,
			time = event.time_msec,
			pointer_device = pointer_id(s, &event.pointer.base),
			motion_output = pointer_output(s, event.pointer),
			absolute = true,
			px = x,
			py = y,
		},
	)
}

cursor_button :: proc (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Pointer, "button").server
	idle_activity(s)
	event := (^bk.Button_Event)(data)
	if locked(s) {
		if event.state == 0 {delete_key(&s.buttons, event.button)}
		return
	}
	button := event.button
	switch button {
	case 272:
		button = 1
	case 274:
		button = 2
	case 273:
		button = 3
	}
	queue_pointer(
		s,
		vm.Event {
			name = "button",
			button = button,
			pressed = event.state == 1,
			native = .Button,
			time = event.time_msec,
			code = event.button,
			blocked = s.pointer_grabbed,
			claimed = s.pointer_grabbed,
		},
	)
}

cursor_axis :: proc (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Pointer, "axis").server
	idle_activity(s)
	if locked(s) {return}
	event := (^bk.Axis_Event)(data)
	fact := vm.Event {
		name        = "axis",
		native      = .Axis,
		time        = event.time_msec,
		blocked     = s.pointer_grabbed,
		claimed     = s.pointer_grabbed,
		orientation = event.orientation,
		delta       = event.delta,
		discrete    = event.delta_discrete,
		source      = event.source,
		direction   = event.relative_direction,
	}
	if event.orientation == 0 {fact.dy = event.delta} else {fact.dx = event.delta}
	queue_pointer(s, fact)
}

cursor_frame :: proc (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Pointer, "frame").server
	queue_event(
		s,
		vm.Event{native = .Frame, blocked = s.pointer_grabbed, claimed = s.pointer_grabbed},
	)
}

request_cursor :: proc (listener: ^wl.Listener, data: rawptr) {
	s := wl.owner(listener, Server, "request_cursor")
	event := (^st.Cursor_Event)(data)
	if !locked(s) && !s.pointer_grabbed &&
	   event.seat_client == s.seat.pointer_state.focused_client {
		s.cursor_named = false
		cursor_surface_set(s, event.surface, event.hotspot_x, event.hotspot_y)
	}
}

init_input :: proc(s: ^Server) -> bool {
	s.buttons = make(map[u32]bool)
	s.seat = st.create(s.display, "seat0")
	if s.seat == nil {return false}
	s.cursor_manager = st.xcursor_manager_create(nil, 24)
	if s.cursor_manager == nil {return false}
	wl.listen(&s.seat.events.request_set_cursor, &s.request_cursor, request_cursor)
	wl.listen(&s.backend.events.new_input, &s.new_input, input_added)
	update_capabilities(s)
	return true
}

queue_pointer :: proc(s: ^Server, fact: vm.Event) {
	e := fact
	pointer_fact(s, &e)
	queue_event(s, e)
}

pointer_fact :: proc(s: ^Server, e: ^vm.Event) {
	e.class = "input"
	e.px, e.py = s.cursor_x, s.cursor_y
	e.has_output = false
	e.output = ""
	e.handle = 0
	if output := out.layout_output_at(s.layout, e.px, e.py); output != nil {
		e.has_output = true
		e.output = string(output.name)
	}
	surface, view, _, _ := hit_test(s, e.px, e.py)
	if !popup_pointer_allowed(s, surface) {surface, view = nil, nil}
	e.native_surface = surface != nil
	if surface != nil && view != nil {e.handle = view.id}
	if kb := st.get_keyboard(s.seat); kb != nil {e.mods = keys.modifier_mask(kb.state)}
}

pointer_refresh :: proc(s: ^Server, time_msec: u32) {
	pointer_refresh_at(s, time_msec, s.cursor_x, s.cursor_y)
}

pointer_target_refresh :: proc(s: ^Server) {
	if s == nil || s.layout == nil || s.seat == nil || s.shutting_down {return}
	pointer_refresh_at(s, 0, s.cursor_x, s.cursor_y, false, false)
}

pointer_id :: proc(s: ^Server, device: ^bk.Device) -> u64 {
	for p in s.pointers {
		if p.device == device {return p.id}
	}
	return 0
}

pointer_output :: proc(s: ^Server, pointer: ^bk.Pointer) -> u64 {
	if pointer.output_name != "" {
		for o in s.outputs {
			if string(o.handle.name) == string(pointer.output_name) {return o.lifetime}
		}
	}
	return 0
}

valid_motion :: proc(s: ^Server, e: ^vm.Event) -> bool {
	if e.pointer_device != 0 {
		found := false
		for p in s.pointers {
			if p.id == e.pointer_device {
				found = true
				break
			}
		}
		if !found {return false}
	}
	if e.motion_output != 0 {
		for o in s.outputs {
			if o.lifetime == e.motion_output {return o.handle.enabled}
		}
		return false
	}
	return true
}

popup_pointer_allowed :: proc(s: ^Server, surface: ^sf.Surface) -> bool {
	client := sh.grab_client(s.shell)
	return client == nil || (surface != nil && surface.resource.client == client)
}
popup_press :: proc(s: ^Server, surface: ^sf.Surface) -> bool {
	if popup_pointer_allowed(s, surface) {return false}
	sh.grab_dismiss(s.shell)
	return true
}
popup_grab_changed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "popup_grab")
	surface := sh.grab_surface(s.shell)
	if surface != nil {
		if !s.popup_grab_active {
			s.popup_previous = s.seat.keyboard_state.focused_surface
			if s.popup_previous !=
			   nil {wl.listen(&s.popup_previous.events.destroy, &s.popup_previous_destroy, popup_previous_gone)}
			s.popup_grab_active = true
		}
		enter_surface(s, surface)
	} else if s.popup_grab_active {
		previous := s.popup_previous
		wl.unlisten(&s.popup_previous_destroy)
		s.popup_previous, s.popup_grab_active = nil, false
		if !locked(s) && !s.shutting_down {
			if previous !=
			   nil {enter_surface(s, previous)} else {st.keyboard_notify_clear_focus(s.seat)}
		}
	}
	pointer_target_refresh(s)
}
popup_previous_gone :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "popup_previous_destroy")
	wl.unlisten(&s.popup_previous_destroy)
	s.popup_previous = nil
}
