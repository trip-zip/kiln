package seat

import sf "../surfaces"

import wl "../wayland"
import p "../protocols"
import wlr "../wlroots"
import keys "../keymap"
import xkb "../xkbcommon"
import "base:runtime"
import "core:c/libc"
import "core:sys/linux"

Modifiers :: keys.Modifiers
Keyboard :: struct {
	handle: ^wlr.wlr_keyboard,
	ctx: runtime.Context,
	keymap: ^keys.Map,
	state: ^keys.State,
	modifiers: Modifiers,
	leds: u32,
	keycodes: [dynamic]u32,
	repeat_rate, repeat_delay: i32,
	keymap_fd: linux.Fd,
	keymap_size: u32,
	seat: ^Seat,
	events: struct { key, modifiers, destroy: wl.Signal },
	key, destroy: wl.Listener,
}
Keyboard_State :: struct {
	keyboard: ^Keyboard,
	focused_surface: ^sf.Surface,
	focused_client: ^Client,
	modifiers: Modifiers,
	keycodes: [dynamic]u32,
	destroy: wl.Listener,
}
keyboard_init :: proc(kb: ^Keyboard, handle: ^wlr.wlr_keyboard) {
	kb.handle, kb.keymap_fd, kb.ctx = handle, -1, context
	kb.repeat_rate, kb.repeat_delay = 25, 600
	for signal in ([]^wl.Signal{&kb.events.key, &kb.events.modifiers, &kb.events.destroy}) { wl.signal_init(signal) }
	if handle != nil {
		wl.listen(&handle.events.key, &kb.key, keyboard_device_key)
		wl.listen(&handle.base.events.destroy, &kb.destroy, keyboard_device_gone)
	}
}
keyboard_finish :: proc(kb: ^Keyboard) {
	wl.unlisten(&kb.key); wl.unlisten(&kb.destroy)
	if kb.seat != nil { set_keyboard(kb.seat, nil) }
	if kb.state != nil { keys.state_destroy(kb.state); kb.state = nil }
	if kb.keymap != nil { keys.destroy(kb.keymap); kb.keymap = nil }
	if kb.keymap_fd >= 0 { linux.close(kb.keymap_fd); kb.keymap_fd = -1 }
	delete(kb.keycodes); kb.keycodes = nil
	wl.signal_emit_final(&kb.events.destroy, kb)
}
keyboard_device_gone :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	kb := wl.owner(listener, Keyboard, "destroy")
	context = kb.ctx
	keyboard_finish(kb)
}
keyboard_device_key :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	kb := wl.owner(listener, Keyboard, "key")
	context = kb.ctx
	e := cast(^wlr.wlr_keyboard_key_event)data
	keyboard_update_key(kb, e)
}
keyboard_update_key :: proc(kb: ^Keyboard, e: ^wlr.wlr_keyboard_key_event) {
	found := false
	for code, i in kb.keycodes { if code == e.keycode { found = true; if e.state == 0 { ordered_remove(&kb.keycodes, i) }; break } }
	if e.state == 1 && !found { append(&kb.keycodes, e.keycode) }
	// Bindings and text interpret the key against the state before its transition.
	wl.signal_emit_mutable(&kb.events.key, e)
	if kb.state != nil && (e.state == 0 && found || e.state == 1 && !found) {
		keys.state_update_key(kb.state, e.keycode, e.state == 1)
		keyboard_update_modifiers(kb)
	}
}
keyboard_update_modifiers :: proc(kb: ^Keyboard) {
	leds: u32
	for name, i in ([3]cstring{"Num Lock", "Caps Lock", "Scroll Lock"}) {
		index := xkb.xkb_keymap_led_get_index(kb.keymap, name)
		if index != max(u32) && xkb.xkb_state_led_index_is_active(kb.state, index) > 0 { leds |= 1<<uint(i) }
	}
	if leds != kb.leds { kb.leds = leds; device_leds(kb.handle, leds) }
	m := keys.state_modifiers(kb.state)
	if m != kb.modifiers { kb.modifiers = m; wl.signal_emit_mutable(&kb.events.modifiers, kb) }
}
keyboard_set_modifiers :: proc(kb: ^Keyboard, depressed, latched, locked, group: u32) {
	if kb.state == nil { return }
	xkb.xkb_state_update_mask(kb.state, depressed, latched, locked, 0, 0, group)
	keyboard_update_modifiers(kb)
}
keyboard_set_keymap :: proc(kb: ^Keyboard, km: ^keys.Map) -> bool {
	state := keys.state_create(km)
	if state == nil { return false }
	text := xkb.xkb_keymap_get_as_string(km, 1)
	if text == nil { keys.state_destroy(state); return false }
	defer libc.free(rawptr(text))
	bytes := (cast([^]u8)text)[:len(text)+1]
	fd, err := linux.memfd_create("kiln-keymap", {.CLOEXEC, .ALLOW_SEALING})
	if err != .NONE { keys.state_destroy(state); return false }
	n, write_err := linux.write(fd, bytes)
	if write_err != .NONE || n != len(bytes) || linux.fcntl(fd, linux.F_ADD_SEALS, {.SHRINK, .GROW, .WRITE, .SEAL}) != .NONE {
		linux.close(fd); keys.state_destroy(state); return false
	}
	if kb.state != nil { keys.state_destroy(kb.state) }
	if kb.keymap != nil { keys.destroy(kb.keymap) }
	if kb.keymap_fd >= 0 { linux.close(kb.keymap_fd) }
	kb.keymap, kb.state, kb.keymap_fd, kb.keymap_size = xkb.xkb_keymap_ref(km), state, fd, u32(len(bytes))
	for code in kb.keycodes { keys.state_update_key(state, code, true) }
	if kb.seat != nil { for c in kb.seat.clients { for r in c.keyboards { keyboard_send_map(r, kb) } } }
	keyboard_update_modifiers(kb)
	return true
}
keyboard_send_map :: proc(r: ^wl.Resource, kb: ^Keyboard) {
	if kb != nil && kb.keymap != nil { wl.post(r, u32(p.Wl_Keyboard_Event.keymap), wl.Uint(1), wl.Fd(kb.keymap_fd), wl.Uint(kb.keymap_size)) }
}
keyboard_send_repeat :: proc(r: ^wl.Resource, kb: ^Keyboard) {
	if r.version >= 4 && kb != nil { wl.post(r, u32(p.Wl_Keyboard_Event.repeat_info), wl.Int(kb.repeat_rate), wl.Int(kb.repeat_delay)) }
}
keyboard_set_repeat_info :: proc(kb: ^Keyboard, rate, delay: i32) {
	kb.repeat_rate, kb.repeat_delay = max(rate,0), max(delay,0)
	if kb.seat != nil { for c in kb.seat.clients { for r in c.keyboards { keyboard_send_repeat(r, kb) } } }
}
set_keyboard :: proc(s: ^Seat, kb: ^Keyboard) {
	if s.keyboard_state.keyboard == kb { return }
	old := s.keyboard_state.keyboard
	if old != nil { old.seat = nil }
	s.keyboard_state.keyboard = kb
	if kb == nil { return }
	kb.seat = s
	for c in s.clients { for r in c.keyboards {
		if old == nil || old.keymap != kb.keymap { keyboard_send_map(r, kb) }
		keyboard_send_repeat(r, kb)
	} }
	keyboard_notify_modifiers(s, &kb.modifiers)
}
get_keyboard :: proc(s: ^Seat) -> ^Keyboard { return s.keyboard_state.keyboard }
keyboard_bind :: proc(c: ^Client, version: i32, id: u32) {
	r := wl.resource_create_typed(c.client, &p.wl_keyboard, version, id, c, keyboard_request, keyboard_destroy)
	if r == nil { return }
	if c.seat.capabilities&2 == 0 { r.data = nil; return }
	append(&c.keyboards, r)
	kb := get_keyboard(c.seat)
	keyboard_send_map(r, kb); keyboard_send_repeat(r, kb)
	state := &c.seat.keyboard_state
	if state.focused_client == c && state.focused_surface != nil {
		keyboard_send_enter(r, next_serial(c), state)
		keyboard_send_modifiers(r, next_serial(c), state.modifiers)
	}
}
keyboard_request :: proc(r: ^wl.Resource, request: p.Wl_Keyboard_Request, args: []wl.Argument) { wl.resource_destroy(r) }
keyboard_destroy :: proc(r: ^wl.Resource) { if c := cast(^Client)r.data; c != nil { remove_resource(&c.keyboards, r) } }
keyboard_send_enter :: proc(r: ^wl.Resource, serial: u32, state: ^Keyboard_State) {
	wl.post(r, u32(p.Wl_Keyboard_Event.enter), wl.Uint(serial), wl.Object(surface_resource(state.focused_surface)),
		wl.Array{data=raw_data(state.keycodes), size=uint(len(state.keycodes)*4)})
}
keyboard_send_modifiers :: proc(r: ^wl.Resource, serial: u32, m: Modifiers) {
	wl.post(r, u32(p.Wl_Keyboard_Event.modifiers), wl.Uint(serial), wl.Uint(m.depressed), wl.Uint(m.latched), wl.Uint(m.locked), wl.Uint(m.group))
}
keyboard_surface_gone :: proc (listener: ^wl.Listener, data: rawptr) {
	state := wl.owner(listener, Keyboard_State, "destroy")
	s := runtime.container_of(state, Seat, "keyboard_state")
	context = s.display.loop.ctx
	keyboard_notify_clear_focus(s)
}
keyboard_notify_enter :: proc(s: ^Seat, surface: ^sf.Surface) {
	kb := get_keyboard(s)
	keyboard_enter(s, surface, kb.keycodes[:] if kb != nil else nil, kb.modifiers if kb != nil else Modifiers{})
}
keyboard_enter :: proc(s: ^Seat, surface: ^sf.Surface, keys: []u32, modifiers: Modifiers) {
	state := &s.keyboard_state
	if state.focused_surface == surface { return }
	if c := state.focused_client; c != nil {
		serial := next_serial(c)
		for r in c.keyboards { wl.post(r, u32(p.Wl_Keyboard_Event.leave), wl.Uint(serial), wl.Object(surface_resource(state.focused_surface))) }
	}
	wl.unlisten(&state.destroy)
	state.focused_surface, state.focused_client, state.modifiers = surface, nil, modifiers
	clear(&state.keycodes); append(&state.keycodes, ..keys)
	if surface != nil {
		surface_watch(surface, &state.destroy, keyboard_surface_gone)
		state.focused_client = client_for(s, surface_resource(surface).client)
		if c := state.focused_client; c != nil {
			serial := next_serial(c)
			for r in c.keyboards { keyboard_send_enter(r, serial, state) }
			keyboard_notify_modifiers(s, &state.modifiers)
		}
	}
	selection_focus(s)
	wl.signal_emit_mutable(&s.events.keyboard_focus_change, s)
}
keyboard_notify_clear_focus :: proc(s: ^Seat) { keyboard_enter(s, nil, nil, {}) }
keyboard_notify_key :: proc(s: ^Seat, time, key, pressed: u32) {
	state := &s.keyboard_state
	found := false
	for code, i in state.keycodes { if code == key { found = true; if pressed == 0 { ordered_remove(&state.keycodes,i) }; break } }
	if pressed != 0 && !found { append(&state.keycodes,key) }
	if c := state.focused_client; c != nil {
		serial := next_serial(c)
		for r in c.keyboards { wl.post(r, u32(p.Wl_Keyboard_Event.key), wl.Uint(serial), wl.Uint(time), wl.Uint(key), wl.Uint(pressed)) }
	}
}
keyboard_notify_modifiers :: proc(s: ^Seat, m: ^Modifiers) {
	s.keyboard_state.modifiers = m^
	if c := s.keyboard_state.focused_client; c != nil {
		serial := next_serial(c)
		for r in c.keyboards { keyboard_send_modifiers(r, serial, m^) }
	}
}
