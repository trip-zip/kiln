package sd_bus

import "core:c"

sd_bus :: struct {}
sd_bus_message :: struct {}
sd_bus_slot :: struct {}
sd_bus_error :: struct { name, message: cstring, _need_free: c.int }
sd_bus_message_handler_t :: #type proc "c" (^sd_bus_message, rawptr, ^sd_bus_error) -> c.int
sd_bus_property_get_t :: #type proc "c" (^sd_bus, cstring, cstring, cstring, ^sd_bus_message, rawptr, ^sd_bus_error) -> c.int
sd_bus_property_set_t :: #type proc "c" (^sd_bus, cstring, cstring, cstring, ^sd_bus_message, rawptr, ^sd_bus_error) -> c.int
Vtable_Start :: struct { element_size: c.size_t, features: u64, vtable_format_reference: ^c.uint }
Vtable_Method :: struct { member, signature, result: cstring, handler: sd_bus_message_handler_t, offset: c.size_t, names: cstring }
Vtable_Signal :: struct { member, signature, names: cstring }
Vtable_Property :: struct { member, signature: cstring, get: sd_bus_property_get_t, set: sd_bus_property_set_t, offset: c.size_t }
sd_bus_vtable :: struct {
    // The low byte is type; the upper 56 bits are flags on the pinned ABI.
    header: u64,
    x: struct #raw_union { start: Vtable_Start, method: Vtable_Method, signal: Vtable_Signal, property: Vtable_Property },
}
#assert(ODIN_ARCH==.amd64 && ODIN_OS==.Linux)
#assert(size_of(sd_bus_error)==24 && align_of(sd_bus_error)==8)
#assert(offset_of(sd_bus_error,name)==0 && offset_of(sd_bus_error,message)==8 && offset_of(sd_bus_error,_need_free)==16)
#assert(size_of(sd_bus_vtable)==56 && align_of(sd_bus_vtable)==8 && offset_of(sd_bus_vtable,x)==8)
#assert(offset_of(Vtable_Start,element_size)==0 && offset_of(Vtable_Start,features)==8 && offset_of(Vtable_Start,vtable_format_reference)==16)
#assert(offset_of(Vtable_Method,member)==0 && offset_of(Vtable_Method,signature)==8 && offset_of(Vtable_Method,result)==16)
#assert(offset_of(Vtable_Method,handler)==24 && offset_of(Vtable_Method,offset)==32 && offset_of(Vtable_Method,names)==40)
#assert(offset_of(Vtable_Signal,member)==0 && offset_of(Vtable_Signal,signature)==8 && offset_of(Vtable_Signal,names)==16)
#assert(offset_of(Vtable_Property,member)==0 && offset_of(Vtable_Property,signature)==8 && offset_of(Vtable_Property,get)==16 && offset_of(Vtable_Property,set)==24 && offset_of(Vtable_Property,offset)==32)
SD_BUS_VTABLE_UNPRIVILEGED :: u64(1<<2)
SD_BUS_VTABLE_PROPERTY_CONST :: u64(1<<4)
SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE :: u64(1<<5)

foreign import lib "system:systemd"
foreign lib {
    sd_bus_object_vtable_format: c.uint
    sd_bus_open_system :: proc(ret: ^^sd_bus) -> c.int ---
    sd_bus_call :: proc(bus: ^sd_bus, m: ^sd_bus_message, usec: u64, error: ^sd_bus_error, reply: ^^sd_bus_message) -> c.int ---
    sd_bus_get_property :: proc(bus: ^sd_bus, destination, path, iface, member: cstring, error: ^sd_bus_error, reply: ^^sd_bus_message, signature: cstring) -> c.int ---
    sd_bus_error_free :: proc(error: ^sd_bus_error) ---
    sd_bus_open_user :: proc(ret: ^^sd_bus) -> c.int ---
    sd_bus_close_unref :: proc(bus: ^sd_bus) -> ^sd_bus ---
    sd_bus_get_fd :: proc(bus: ^sd_bus) -> c.int ---
    sd_bus_get_events :: proc(bus: ^sd_bus) -> c.int ---
    sd_bus_get_timeout :: proc(bus: ^sd_bus, ret: ^u64) -> c.int ---
    sd_bus_process :: proc(bus: ^sd_bus, ret: ^^sd_bus_message) -> c.int ---
    sd_bus_request_name :: proc(bus: ^sd_bus, name: cstring, flags: u64) -> c.int ---
    sd_bus_add_object_vtable :: proc(bus: ^sd_bus, slot: ^^sd_bus_slot, path, iface: cstring, vtable: ^sd_bus_vtable, userdata: rawptr) -> c.int ---
    sd_bus_add_match :: proc(bus: ^sd_bus, slot: ^^sd_bus_slot, match: cstring, callback: sd_bus_message_handler_t, userdata: rawptr) -> c.int ---
    sd_bus_slot_unref :: proc(slot: ^sd_bus_slot) -> ^sd_bus_slot ---
    sd_bus_call_async :: proc(bus: ^sd_bus, slot: ^^sd_bus_slot, m: ^sd_bus_message, callback: sd_bus_message_handler_t, userdata: rawptr, usec: u64) -> c.int ---
    sd_bus_message_new_method_call :: proc(bus: ^sd_bus, ret: ^^sd_bus_message, destination, path, iface, member: cstring) -> c.int ---
    sd_bus_message_new_method_return :: proc(call: ^sd_bus_message, ret: ^^sd_bus_message) -> c.int ---
    sd_bus_message_new_signal :: proc(bus: ^sd_bus, ret: ^^sd_bus_message, path, iface, member: cstring) -> c.int ---
    sd_bus_message_unref :: proc(m: ^sd_bus_message) -> ^sd_bus_message ---
    sd_bus_message_set_expect_reply :: proc(m: ^sd_bus_message, b: c.int) -> c.int ---
    sd_bus_message_set_auto_start :: proc(m: ^sd_bus_message, b: c.int) -> c.int ---
    sd_bus_send :: proc(bus: ^sd_bus, m: ^sd_bus_message, cookie: ^u64) -> c.int ---
    sd_bus_message_get_member :: proc(m: ^sd_bus_message) -> cstring ---
    sd_bus_message_get_sender :: proc(m: ^sd_bus_message) -> cstring ---
    sd_bus_message_get_path :: proc(m: ^sd_bus_message) -> cstring ---
    sd_bus_message_is_method_error :: proc(m: ^sd_bus_message, name: cstring) -> c.int ---
    sd_bus_message_read_basic :: proc(m: ^sd_bus_message, type: c.char, ret: rawptr) -> c.int ---
    sd_bus_message_append_basic :: proc(m: ^sd_bus_message, type: c.char, p: rawptr) -> c.int ---
    sd_bus_message_read_array :: proc(m: ^sd_bus_message, type: c.char, ret: ^rawptr, size: ^c.size_t) -> c.int ---
    sd_bus_message_open_container :: proc(m: ^sd_bus_message, type: c.char, contents: cstring) -> c.int ---
    sd_bus_message_close_container :: proc(m: ^sd_bus_message) -> c.int ---
    sd_bus_message_enter_container :: proc(m: ^sd_bus_message, type: c.char, contents: cstring) -> c.int ---
    sd_bus_message_exit_container :: proc(m: ^sd_bus_message) -> c.int ---
    sd_bus_message_peek_type :: proc(m: ^sd_bus_message, type: ^c.char, contents: ^cstring) -> c.int ---
    sd_bus_message_skip :: proc(m: ^sd_bus_message, types: cstring) -> c.int ---
    sd_bus_service_name_is_valid :: proc(name: cstring) -> c.int ---
    sd_bus_object_path_is_valid :: proc(path: cstring) -> c.int ---
}
