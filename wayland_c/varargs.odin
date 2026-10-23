package wayland_c

import wl "../wayland"
import "core:fmt"

Va_List :: struct {
	gp_offset, fp_offset:             u32,
	overflow_arg_area, reg_save_area: rawptr,
}
#assert(size_of(Va_List) == 24)
foreign import libc "system:c"
foreign libc {vsnprintf :: proc "c" (_: [^]u8, _: uint, _: cstring, _: ^Va_List) -> i32 ---}
Log_Callback :: #type proc "c" (_: cstring, _: ^Va_List)
c_log: Log_Callback
error_vargs :: proc(resource: ^wl.Resource, code: u32, format: cstring, ap: ^Va_List) {
	buffer: [128]u8
	length := vsnprintf(&buffer[0], len(buffer), format, ap)
	wl.post_error(resource, code, string(buffer[:clamp(int(length), 0, len(buffer) - 1)]))
}
log_message :: proc(message: string) {
	if c_log == nil {fmt.eprint(message); return}
	buffer: [4096]u8
	n := copy(buffer[:len(buffer) - 1], message)
	buffer[n] = 0
	value := uintptr(&buffer[0])
	ap := Va_List{48, 304, &value, nil}
	c_log("%s", &ap)
}
@(export, link_name = "wl_resource_post_error_vargs")
wl_resource_post_error_vargs :: proc "c" (r: ^wl.Resource, code: u32, format: cstring, ap: ^Va_List) {context = bridge_context; error_vargs(r, code, format, ap)}
@(export, link_name = "wl_resource_post_event")
wl_resource_post_event :: proc "c" (r: ^wl.Resource, opcode: u32, a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19: uintptr) {
	context = bridge_context
	values := [20]uintptr{a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19}
	event(r, opcode, values[:])
}
@(export, link_name = "wl_resource_post_error")
wl_resource_post_error :: proc "c" (r: ^wl.Resource, code: u32, format: cstring, a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19: uintptr) {
	context = bridge_context
	values := [20]uintptr{a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19}
	ap := Va_List{48, 304, &values[0], nil}; error_vargs(r, code, format, &ap)
}
@(export, link_name = "wl_client_post_implementation_error")
wl_client_post_implementation_error :: proc "c" (client: ^wl.Client, format: cstring, a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19: uintptr) {
	context = bridge_context
	values := [20]uintptr{a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19}
	ap := Va_List{48, 304, &values[0], nil}; error_vargs(client.display_resource, 3, format, &ap)
}
