package compositor

import ext "../extensions"
import wl "../wayland"
import wlr "../wlroots"
import "core:fmt"
import "core:strings"
import "core:testing"

extension_text_request :: proc(c: ^Extension_Client, id, opcode: u32, value: string, tail: []u32 = nil) {
	padded := (len(value)+4)&~3
	bytes := make([]u8, 12+padded+len(tail)*4, context.temp_allocator)
	wl.word_write(bytes, 0, id); wl.word_write(bytes, 4, u32(len(bytes))<<16|opcode)
	wl.word_write(bytes, 8, u32(len(value)+1)); copy(bytes[12:], value)
	for word, i in tail { wl.word_write(bytes, 12+padded+i*4, word) }
	assert(wl.connection_queue(&c.peer, bytes, nil) == .NONE)
	assert(wl.connection_flush(&c.peer) == .NONE)
}
extension_event_string :: proc(event: []u8) -> string { return string(event[12:12+wl.word_read(event, 8)-1]) }
extension_hold_events :: proc(s: ^Server) {
	// Keep the real policy handlers' queued events inspectable without booting Lua.
	s.event_source = wl.on_timer(s.display, proc(data: rawptr) -> i32 { return 0 }, nil)
}
extension_clear_events :: proc(s: ^Server) {
	for &event in s.events { free_event(&event) }
	clear(&s.events)
}

@(test)
owned_activation_mints_serial_validation_and_single_use :: proc(t: ^testing.T) {
	s := extension_server()
	defer extension_finish(s)
	s.activation = ext.activation_create(s.display)
	wl.listen(&s.activation.events.request_activate, &s.request_activate, activation_requested)
	extension_hold_events(s)
	a, b := extension_client(s), extension_client(s)
	defer wl.connection_close(&a.peer)
	defer wl.connection_close(&b.peer)
	extension_bind(&a, "xdg_activation_v1", 1, 7)
	extension_bind(&b, "xdg_activation_v1", 1, 7)
	base := wlr.wlr_xdg_surface{surface = ext.surface_of(wl.client_get_object(b.client, 6))}
	top := wlr.wlr_xdg_toplevel{base = &base}
	view := View{id = 77, server = s, protocol = &top, mapped = true}
	append(&s.views, &view)
	_, name := runtime_mint_token(s)
	copy_name := strings.clone(string(name), context.temp_allocator)
	extension_text_request(&b, 7, 2, copy_name, []u32{6})
	extension_pump(&b)
	testing.expect_value(t, len(s.events), 1)
	testing.expect(t, s.events[0].name == "request::activate" && s.events[0].handle == 77 && s.events[0].valid)
	testing.expect_value(t, len(s.minted_tokens), 0)
	extension_clear_events(s)
	extension_text_request(&b, 7, 2, copy_name, []u32{6})
	extension_pump(&b)
	testing.expect_value(t, len(s.events), 0)
	old_enter := extension_focus(s, &a)
	serial := old_enter
	// Interleaved clients exhaust wlroots' bounded serial history with actual enter events.
	for _ in 0..<130 { extension_focus(s, &b); serial = extension_focus(s, &a) }
	seat_client := ext.seat_client_of(wl.client_get_object(a.client, 3))
	// A full wlroots ring deliberately accepts evicted serials; only half-range age is unambiguously stale.
	testing.expect(t, wlr.wlr_seat_client_validate_event_serial(seat_client, old_enter))
	stale := serial-0x80000000
	testing.expect(t, !wlr.wlr_seat_client_validate_event_serial(seat_client, stale))
	testing.expect(t, wlr.wlr_seat_client_validate_event_serial(seat_client, serial))
	for valid in ([2]bool{false, true}) {
		extension_send(&a, []u32{7, 12<<16|1, 8, 8, 16<<16, serial if valid else stale, 3,
			8, 12<<16|2, 6})
		extension_text_request(&a, 8, 1, "launcher.application")
		extension_send(&a, []u32{8, 8<<16|3})
		done := extension_event(extension_pump(&a), 8, 0)
		assert(done != nil)
		token_name := extension_event_string(done)
		testing.expect_value(t, len(token_name), 32)
		testing.expect(t, token_name != copy_name)
		// Destroying the request object must not invalidate the issued token.
		extension_send(&a, []u32{8, 8<<16|4})
		extension_pump(&a)
		extension_text_request(&b, 7, 2, token_name, []u32{6})
		extension_pump(&b)
		testing.expect_value(t, len(s.events), 1 if valid else 0)
		if valid {
			testing.expect(t, s.events[0].valid && s.events[0].app_id == "launcher.application")
			testing.expect_value(t, s.events[0].name, "request::activate")
		}
		extension_clear_events(s)
	}
	extension_send(&a, []u32{7, 12<<16|1, 8, 8, 12<<16|2, 6, 8, 8<<16|3})
	done := extension_event(extension_pump(&a), 8, 0)
	assert(done != nil)
	extension_text_request(&b, 7, 2, extension_event_string(done), []u32{6})
	extension_pump(&b)
	testing.expect_value(t, len(s.events), 1)
	testing.expect(t, s.events[0].name == "request::activate" && s.events[0].handle == 77 && !s.events[0].valid)
	extension_clear_events(s)
	testing.expect_value(t, len(s.activation.tokens), 0)
	fmt.println("Activation: trusted and serial-validated tokens activate; no-seat token reaches request::activate with valid=false; half-range-stale token rejected; replay rejected; evicted serial acceptance matches wlroots")
}

@(test)
owned_activation_default_timeout_and_configured_expiry :: proc(t: ^testing.T) {
	s := extension_server()
	defer extension_finish(s)
	s.activation = ext.activation_create(s.display)
	wl.listen(&s.activation.events.request_activate, &s.request_activate, activation_requested)
	extension_hold_events(s)
	c := extension_client(s)
	defer wl.connection_close(&c.peer)
	extension_bind(&c, "xdg_activation_v1", 1, 7)
	testing.expect_value(t, s.activation.token_timeout_msec, u32(30000))
	s.activation.token_timeout_msec = 250
	before := wl.monotonic_ns()
	_, name := runtime_mint_token(s)
	token_name := strings.clone(string(name), context.temp_allocator)
	testing.expect_value(t, len(s.activation.tokens), 1)
	extension_pump(&c, 270)
	elapsed := wl.monotonic_ns()-before
	testing.expect(t, elapsed >= 250_000_000)
	testing.expect_value(t, len(s.activation.tokens), 0)
	testing.expect_value(t, len(s.minted_tokens), 0)
	extension_text_request(&c, 7, 2, token_name, []u32{6})
	extension_pump(&c)
	testing.expect_value(t, len(s.events), 0)
	fmt.printf("Activation: default 30000 ms verified; configured 250 ms timeout expired after %.3f ms; token and minted owner retired\n", f64(elapsed)/1e6)
}

@(test)
owned_activation_commit_reuse_and_destroyed_seat_are_safe :: proc(t: ^testing.T) {
	for mode in 0..<3 {
		s := extension_server()
		defer extension_finish(s)
		s.activation = ext.activation_create(s.display)
		c := extension_client(s)
		defer wl.connection_close(&c.peer)
		extension_bind(&c, "xdg_activation_v1", 1, 7)
		serial := extension_focus(s, &c)
		extension_send(&c, []u32{7, 12<<16|1, 8, 8, 16<<16, serial, 3, 8, 12<<16|2, 6})
		extension_pump(&c)
		if mode == 0 {
			wlr_seat_destroy(s.seat)
			s.seat = nil
		}
		extension_send(&c, []u32{8, 8<<16|3})
		testing.expect(t, extension_event(extension_pump(&c), 8, 0) != nil)
		if mode == 0 {
			testing.expect(t, s.activation.tokens[0].valid && s.activation.tokens[0].seat == nil)
		} else {
			if mode == 1 { extension_send(&c, []u32{8, 8<<16|3}) } else { extension_text_request(&c, 8, 1, "after.commit") }
			err := extension_event(extension_pump(&c), 1, 0)
			assert(err != nil)
			testing.expect_value(t, wl.word_read(err, 12), u32(0))
			// Committed token storage survives the creator's disconnect until use/expiry.
			testing.expect_value(t, len(s.activation.tokens), 1)
		}
	}
}
