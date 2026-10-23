package protocols

import wl "../wayland"
import "core:dynlib"
import "core:fmt"
import "core:sys/posix"
import "core:testing"

@(test)
core_tables_match_libwayland :: proc(t: ^testing.T) {
	// A library handle bypasses our exports when locating the reference tables.
	library, loaded := dynlib.load_library("libwayland-server.so.0")
	if !testing.expect(t, loaded, dynlib.last_error()) { return }
	defer dynlib.unload_library(library)
	process := posix.dlopen(nil, {.NOW})
	if !testing.expect(t, process != nil) { return }
	defer posix.dlclose(process)
	testing.expect_value(t, len(wayland_interfaces), 23)
	for own in wayland_interfaces {
		symbol := fmt.tprintf("%s_interface", own.name)
		exported, exported_ok := dynlib.symbol_address(dynlib.Library(process), symbol)
		testing.expect(t, exported_ok && exported == rawptr(own), symbol)
		address, found := dynlib.symbol_address(library, symbol)
		if !testing.expect(t, found, symbol) { continue }
		reference := cast(^wl.Interface)address
		testing.expect(t, reference != own, symbol)
		expect_equal(t, string(own.name), string(reference.name), symbol)
		expect_equal(t, own.version, reference.version, symbol)
		expect_equal(t, own.method_count, reference.method_count, symbol)
		expect_equal(t, own.event_count, reference.event_count, symbol)
		if own.method_count == reference.method_count {
			compare_messages(t, own.methods, reference.methods, own.method_count, symbol)
		}
		if own.event_count == reference.event_count {
			compare_messages(t, own.events, reference.events, own.event_count, symbol)
		}
	}
}

compare_messages :: proc(t: ^testing.T, own, reference: [^]wl.Message, count: i32, symbol: string) {
	if !testing.expect(t, (own == nil) == (reference == nil), symbol) || count == 0 { return }
	for index in 0..<count {
		got, want := own[index], reference[index]
		label := fmt.tprintf("%s.%s opcode %d", symbol, want.name, index)
		expect_equal(t, string(got.name), string(want.name), label)
		if !expect_equal(t, string(got.signature), string(want.signature), label) { continue }
		if !testing.expect(t, (got.types == nil) == (want.types == nil), label) { continue }
		arg_index := 0
		for c in string(want.signature) {
			if c == '?' || '0' <= c && c <= '9' { continue }
			got_type, want_type := got.types[arg_index], want.types[arg_index]
			arg_index += 1
			if !testing.expect(t, (got_type == nil) == (want_type == nil), label) || want_type == nil { continue }
			expect_equal(t, string(got_type.name), string(want_type.name), label)
			expect_equal(t, got_type.version, want_type.version, label)
			canonical: ^wl.Interface
			for candidate in wayland_interfaces {
				if string(candidate.name) == string(want_type.name) { canonical = candidate; break }
			}
			testing.expect(t, canonical != nil && got_type == canonical, label)
		}
	}
}

@(test)
core_opcodes_and_enums_keep_wire_values :: proc(t: ^testing.T) {
	testing.expect_value(t, u32(Wl_Registry_Request.bind), u32(0))
	testing.expect_value(t, u32(Wl_Display_Event.delete_id), u32(1))
	testing.expect_value(t, u32(Wl_Surface_Request.commit), u32(6))
	testing.expect_value(t, u32(Wl_Surface_Request.damage_buffer), u32(9))
	testing.expect_value(t, u32(Wl_Fixes_Request.ack_global_remove), u32(2))
	testing.expect_value(t, u32(Wl_Output_Transform._90), u32(1))
	testing.expect_value(t, u32(Wl_Shm_Format.argb8888), u32(0))
	testing.expect_value(t, u32(Wl_Shm_Format.abgr8888), u32(0x34324241))
	testing.expect_value(t, u32(Wl_Data_Device_Manager_Dnd_Action_none), u32(0))
	testing.expect_value(t, u32(Wl_Shell_Surface_Resize_top_left), u32(5))
	testing.expect_value(t, transmute(u32)Wl_Seat_Capability{.pointer, .touch}, u32(5))
	testing.expect_value(t, transmute(u32)Wl_Output_Mode{.current, .preferred}, u32(3))
}

expect_equal :: proc(t: ^testing.T, got: $T, want: T, label: string) -> bool {
	return testing.expect(t, got == want, fmt.tprintf("%s: got %v, expected %v", label, got, want))
}
