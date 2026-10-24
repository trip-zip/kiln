package extensions

import p "../protocols"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"
import "core:strings"
import "core:sys/linux"
import "core:time"

Activation :: struct {
	global: ^wl.Global,
	token_timeout_msec: u32,
	tokens: [dynamic]^Activation_Token,
	events: struct { destroy, request_activate, new_token: wl.Signal },
	destroy: wl.Listener,
}
Activation_Token :: struct {
	manager: ^Activation,
	resource: ^wl.Resource,
	seat: ^wlr.wlr_seat,
	surface: ^wlr.wlr_surface,
	app_id: cstring,
	name: [33]u8,
	serial: u32,
	valid, committed: bool,
	timer: ^wl.Event_Source,
	events: struct { destroy: wl.Signal },
	seat_destroy, surface_destroy: wl.Listener,
}
Activation_Event :: struct { activation: ^Activation, token: ^Activation_Token, surface: ^wlr.wlr_surface }
activation_create :: proc(display: ^wl.Display) -> ^Activation {
	context = display.loop.ctx
	m := new(Activation)
	m.token_timeout_msec = 30000
	wl.signal_init(&m.events.destroy)
	wl.signal_init(&m.events.request_activate)
	wl.signal_init(&m.events.new_token)
	m.global = wl.global_create_typed(display, &p.xdg_activation_v1, 1, m, activation_request)
	if m.global == nil { free(m); return nil }
	wl.listen(&display.destroy_signal, &m.destroy, activation_destroyed)
	return m
}
activation_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	m := wl.owner(listener, Activation, "destroy")
	context = m.global.display.loop.ctx
	for len(m.tokens) > 0 { activation_retire(m.tokens[len(m.tokens)-1]) }
	wl.signal_emit_final(&m.events.destroy, m)
	wl.unlisten(listener)
	wl.global_destroy(m.global)
	delete(m.tokens)
	free(m)
}
activation_token_new :: proc(m: ^Activation) -> ^Activation_Token {
	context = m.global.display.loop.ctx
	t := new(Activation_Token)
	t.manager = m
	wl.signal_init(&t.events.destroy)
	append(&m.tokens, t)
	return t
}
activation_retire :: proc(t: ^Activation_Token) {
	if t == nil { return }
	context = t.manager.global.display.loop.ctx
	if t.resource != nil { t.resource.data = nil }
	wl.remove_source(t.timer)
	wl.unlisten(&t.seat_destroy)
	wl.unlisten(&t.surface_destroy)
	for other, i in t.manager.tokens { if other == t { ordered_remove(&t.manager.tokens, i); break } }
	wl.signal_emit_final(&t.events.destroy, nil)
	delete(t.app_id)
	free(t)
}
activation_expired :: proc(data: rawptr) -> i32 { activation_retire(cast(^Activation_Token)data); return 0 }
activation_issue :: proc(t: ^Activation_Token) -> bool {
	for {
		bytes: [16]u8
		at := 0
		for at < len(bytes) {
			n, err := linux.getrandom(bytes[at:], {})
			if err == .EINTR { continue }
			if err != .NONE || n == 0 { return false }
			at += n
		}
		hex := "0123456789abcdef"
		for byte, i in bytes { t.name[i*2], t.name[i*2+1] = hex[byte>>4], hex[byte&15] }
		duplicate := false
		for other in t.manager.tokens { if other != t && other.name == t.name { duplicate = true; break } }
		if !duplicate { break }
	}
	t.committed = true
	if t.manager.token_timeout_msec > 0 {
		t.timer = wl.on_timer(t.manager.global.display, activation_expired, t)
		if t.timer == nil || !wl.arm_timer(t.timer, time.Duration(t.manager.token_timeout_msec)*time.Millisecond) { return false }
	}
	return true
}
activation_mint :: proc(m: ^Activation) -> (^Activation_Token, cstring) {
	t := activation_token_new(m)
	t.valid = true
	if !activation_issue(t) { activation_retire(t); return nil, nil }
	return t, cstring(&t.name[0])
}
activation_seat_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	t := wl.owner(listener, Activation_Token, "seat_destroy")
	wl.unlisten(listener)
	t.seat, t.valid = nil, false
}
activation_surface_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	t := wl.owner(listener, Activation_Token, "surface_destroy")
	wl.unlisten(listener)
	t.surface = nil
}
activation_token_destroy :: proc(r: ^wl.Resource) { activation_retire(cast(^Activation_Token)r.data) }
activation_token_request :: proc(r: ^wl.Resource, request: p.Xdg_Activation_Token_V1_Request, args: []wl.Argument) {
	if request == .destroy { wl.resource_destroy(r); return }
	t := cast(^Activation_Token)r.data
	if t == nil { wl.post_error(r, u32(p.Xdg_Activation_Token_V1_Error.already_used), "token already committed"); return }
	switch request {
	case .destroy:
	case .set_serial:
		wl.unlisten(&t.seat_destroy)
		t.seat = nil
		client := seat_client_of(wl.object(args[1]))
		if client != nil {
			t.seat, t.serial = client.seat, u32(args[0].(wl.Uint))
			wl.listen(&t.seat.events.destroy, &t.seat_destroy, activation_seat_destroyed)
		}
	case .set_app_id:
		delete(t.app_id)
		t.app_id = strings.clone_to_cstring(args[0].(wl.String).value)
	case .set_surface:
		wl.unlisten(&t.surface_destroy)
		t.surface = surface_of(wl.object(args[0]))
		if t.surface != nil { wl.listen(&t.surface.events.destroy, &t.surface_destroy, activation_surface_destroyed) }
	case .commit:
		t.valid = true
		if t.seat != nil {
			client := wlr.wlr_seat_client_for_wl_client(t.seat, r.client)
			t.valid = client != nil && wlr.wlr_seat_client_validate_event_serial(client, t.serial)
			if t.surface != nil && t.surface != t.seat.pointer_state.focused_surface && t.surface != t.seat.keyboard_state.focused_surface { t.valid = false }
		}
		if !activation_issue(t) { wl.client_no_memory(r.client); return }
		// The issued token outlives both its request object and the requesting client.
		r.data, t.resource = nil, nil
		wl.post(r, u32(p.Xdg_Activation_Token_V1_Event.done), wl.String{value = string(cstring(&t.name[0]))})
		if t.valid { wl.signal_emit_mutable(&t.manager.events.new_token, t) }
	}
}
activation_request :: proc(r: ^wl.Resource, request: p.Xdg_Activation_V1_Request, args: []wl.Argument) {
	m := cast(^Activation)r.data
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .get_activation_token:
		t := activation_token_new(m)
		t.resource = wl.resource_create_typed(r.client, &p.xdg_activation_token_v1, r.version,
			u32(args[0].(wl.New_Id)), t, activation_token_request, activation_token_destroy)
		if t.resource == nil { activation_retire(t) }
	case .activate:
		name := args[0].(wl.String).value
		for t in m.tokens {
			if !t.committed || name != string(cstring(&t.name[0])) { continue }
			if t.valid {
				event := Activation_Event{m, t, surface_of(wl.object(args[1]))}
				wl.signal_emit_mutable(&m.events.request_activate, &event)
			}
			// A request listener may already have retired the token.
			for other in m.tokens { if other == t { activation_retire(t); break } }
			return
		}
	}
}
