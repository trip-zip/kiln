package compositor

import sp "../scene_paint"

import "../keymap"
import vm "../lua_runtime"
import pam "../pam"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"

Keyboard :: struct {
	server:                  ^Server,
	id:                      u64,
	consumed:                map[u32]bool,
	handle:                  ^wlr.wlr_keyboard,
	compose:                 ^keymap.Compose,
	key, modifiers, destroy: wl.Listener,
}

update_capabilities :: proc(s: ^Server) {
	capabilities: u32 = 1 // Keep pointer requests available before a device is attached.
	if len(s.keyboards) > 0 {capabilities |= 2}
	wlr.wlr_seat_set_capabilities(s.seat, capabilities)
}

input_added :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "new_input")
	device := (^wlr.wlr_input_device)(data)
	switch device.type {
	case wlr.WLR_INPUT_DEVICE_KEYBOARD:
		km, ok := keymap.create_default()
		if !ok {
			fail(s, "Failed to create keyboard map")
			return
		}
		defer keymap.destroy(km)
		handle := wlr.wlr_keyboard_from_input_device(device)
		if !wlr.wlr_keyboard_set_keymap(handle, km) {
			fail(s, "Failed to set keyboard map")
			return
		}
		wlr.wlr_keyboard_set_repeat_info(handle, 25, 600)
		kb := new(Keyboard)
		kb.server, kb.handle = s, handle
		s.next_keyboard += 1
		kb.id = s.next_keyboard
		kb.compose = keymap.compose_default()
		kb.consumed = make(map[u32]bool)
		append(&s.keyboards, kb)
		wl.listen(&handle.events.key, &kb.key, keyboard_key)
		wl.listen(&handle.events.modifiers, &kb.modifiers, keyboard_modifiers)
		wl.listen(&handle.base.events.destroy, &kb.destroy, keyboard_destroy)
		wlr.wlr_seat_set_keyboard(s.seat, handle)
		update_capabilities(s)
		runtime_focus(s, s.requested_focus)
	case wlr.WLR_INPUT_DEVICE_POINTER:
		wlr.wlr_cursor_attach_input_device(s.cursor, device)
		p := new(Pointer)
		p.server, p.device = s, device
		s.next_pointer += 1
		p.id = s.next_pointer
		append(&s.pointers, p)
		wl.listen(&device.events.destroy, &p.destroy, pointer_destroy)
		map_pointers(s)
		cursor_sync(s)
	}
}

keyboard_key :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	kb := wl.owner(listener, Keyboard, "key")
	// Backend teardown releases held keys after Lua has been destroyed.
	if kb.server.shutting_down {return}
	idle_activity(kb.server)
	event := (^wlr.wlr_keyboard_key_event)(data)
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
	mods := wlr.wlr_keyboard_get_modifiers(kb.handle)
	syms := keymap.symbols(kb.handle.xkb_state, event.keycode)
	if native_vt(kb.server, syms, mods, event.state == 1) {
		kb.consumed[event.keycode] = true
		return
	}
	chords := keymap.chord_symbols(kb.handle.xkb_state, event.keycode, mods)
	matched := false
	for actual, i in syms {
		sym := actual
		if i < len(chords) {sym = chords[i]}
		matched = matched || keymap.bound(kb.server.lua.bindings, sym, mods)
	}
	for actual, i in syms {
		sym := actual
		if i < len(chords) {sym = chords[i]}
		name_buf: [128]u8
		utf8_buf: [256]u8
		name, _ := keymap.describe(sym, name_buf[:], utf8_buf[:])
		utf8 := keymap.text(
			kb.compose,
			actual,
			event.state == 1,
			utf8_buf[:],
			kb.handle.xkb_state,
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

keyboard_modifiers :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	kb := wl.owner(listener, Keyboard, "modifiers")
	if kb.server.shutting_down {return}
	m := kb.handle.modifiers
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

keyboard_destroy :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	kb := wl.owner(listener, Keyboard, "destroy")
	s := kb.server
	wl.unlisten(&kb.key)
	wl.unlisten(&kb.modifiers)
	wl.unlisten(&kb.destroy)
	for other, i in s.keyboards {
		if other == kb {
			ordered_remove(&s.keyboards, i)
			break
		}
	}
	if len(s.keyboards) > 0 {wlr.wlr_seat_set_keyboard(s.seat, s.keyboards[0].handle)}
	update_capabilities(s)
	delete(kb.consumed)
	keymap.compose_destroy(kb.compose)
	free(kb)
}

hit_test :: proc(s: ^Server, x, y: f64) -> (surface: ^wlr.wlr_surface, view: ^View, sx, sy: f64) {
	handle := wlr.wlr_output_layout_output_at(s.layout, x, y)
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
		surface, view, _, _ := hit_test(s, s.cursor.x, s.cursor.y)
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
	// Finish motion for the old focus before leave. Relative-only events can
	// otherwise stay pending in XWayland and move its cursor on the next enter.
	if s.seat.pointer_state.focused_surface != surface {wlr.wlr_seat_pointer_notify_frame(s.seat)}
	handle: u32
	if view != nil && surface != nil {handle = view.id}
	if handle != s.pointer_client {
		s.pointer_client = handle
		queue_event(s, vm.Event{class = "input", name = "pointer_enter", handle = handle})
	}
	if surface == nil {
		if reset_cursor {runtime_cursor(s, "default")}
		wlr.wlr_seat_pointer_notify_clear_focus(s.seat)
	} else {
		wlr.wlr_seat_pointer_notify_enter(s.seat, surface, sx, sy)
		if send_motion {wlr.wlr_seat_pointer_notify_motion(s.seat, time_msec, sx, sy)} else if s.seat.pointer_state.focused_surface == surface &&
		   (s.seat.pointer_state.sx != sx || s.seat.pointer_state.sy != sy) {
			// A published move changes client-local coordinates too. Updating only
			// the seat cache would suppress the next real motion as a duplicate.
			wlr.wlr_seat_pointer_notify_motion(s.seat, time_msec, sx, sy)
			wlr.wlr_seat_pointer_notify_frame(s.seat)
		}
	}
}

cursor_motion :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "cursor_motion")
	idle_activity(s)
	if locked(s) {return}
	event := (^wlr.wlr_pointer_motion_event)(data)
	queue_event(
		s,
		vm.Event {
			native = .DeviceMotion,
			time = event.time_msec,
			pointer_device = pointer_id(s, &event.pointer.base),
			dx = event.delta_x,
			dy = event.delta_y,
			ux = event.unaccel_dx,
			uy = event.unaccel_dy,
		},
	)
}

cursor_absolute :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "cursor_absolute")
	idle_activity(s)
	if locked(s) {return}
	event := (^wlr.wlr_pointer_motion_absolute_event)(data)
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

cursor_button :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "cursor_button")
	idle_activity(s)
	event := (^wlr.wlr_pointer_button_event)(data)
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

cursor_axis :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "cursor_axis")
	idle_activity(s)
	if locked(s) {return}
	event := (^wlr.wlr_pointer_axis_event)(data)
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

cursor_frame :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "cursor_frame")
	queue_event(
		s,
		vm.Event{native = .Frame, blocked = s.pointer_grabbed, claimed = s.pointer_grabbed},
	)
}

request_cursor :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "request_cursor")
	event := (^wlr.wlr_seat_pointer_request_set_cursor_event)(data)
	if !locked(s) && !s.pointer_grabbed &&
	   event.seat_client == s.seat.pointer_state.focused_client {
		s.cursor_named = false
		cursor_surface_set(s, event.surface, event.hotspot_x, event.hotspot_y)
	}
}

request_selection :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "request_selection")
	event := (^wlr.wlr_seat_request_set_selection_event)(data)
	wlr.wlr_seat_set_selection(s.seat, event.source, event.serial)
}

init_input :: proc(s: ^Server) -> bool {
	s.buttons = make(map[u32]bool)
	s.seat = wlr.wlr_seat_create(s.display, "seat0")
	if s.seat == nil {return false}
	s.cursor = wlr.wlr_cursor_create()
	if s.cursor == nil {return false}
	s.cursor_manager = wlr.wlr_xcursor_manager_create(nil, 24)
	if s.cursor_manager == nil {return false}
	wl.listen(&s.cursor.events.motion, &s.cursor_motion, cursor_motion)
	wl.listen(&s.cursor.events.motion_absolute, &s.cursor_absolute, cursor_absolute)
	wl.listen(&s.cursor.events.button, &s.cursor_button, cursor_button)
	wl.listen(&s.cursor.events.axis, &s.cursor_axis, cursor_axis)
	wl.listen(&s.cursor.events.frame, &s.cursor_frame, cursor_frame)
	wl.listen(&s.seat.events.request_set_cursor, &s.request_cursor, request_cursor)
	wl.listen(&s.seat.events.request_set_selection, &s.request_selection, request_selection)
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
	e.px, e.py = s.cursor.x, s.cursor.y
	e.has_output = false
	e.output = ""
	e.handle = 0
	if output := wlr.wlr_output_layout_output_at(s.layout, e.px, e.py); output != nil {
		e.has_output = true
		e.output = string(output.name)
	}
	surface, view, _, _ := hit_test(s, e.px, e.py)
	e.native_surface = surface != nil
	if surface != nil && view != nil {e.handle = view.id}
	if kb := wlr.wlr_seat_get_keyboard(s.seat); kb != nil {e.mods = wlr.wlr_keyboard_get_modifiers(kb)}
}

pointer_refresh :: proc(s: ^Server, time_msec: u32) {
	pointer_refresh_at(s, time_msec, s.cursor.x, s.cursor.y)
}

pointer_target_refresh :: proc(s: ^Server) {
	if s == nil || s.cursor == nil || s.seat == nil || s.shutting_down {return}
	pointer_refresh_at(s, 0, s.cursor.x, s.cursor.y, false, false)
}

pointer_id :: proc(s: ^Server, device: ^wlr.wlr_input_device) -> u64 {
	for p in s.pointers {
		if p.device == device {return p.id}
	}
	return 0
}

pointer_output :: proc(s: ^Server, pointer: ^wlr.wlr_pointer) -> u64 {
	if pointer.output_name != nil {
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
