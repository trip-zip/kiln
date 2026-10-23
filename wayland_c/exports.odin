// This boundary exists only while C libraries bind server symbols and is deleted with wlroots.
package wayland_c

import p "../protocols"
import wl "../wayland"
import "base:runtime"
import "core:time"

when ODIN_ARCH != .amd64 {#panic("The Wayland C dispatcher requires SysV amd64 integer arguments")}
bridge_context: runtime.Context
install :: proc() {
	bridge_context = context
	wl.core_interfaces = {&p.wl_display, &p.wl_registry, &p.wl_callback}
	wl.c_dispatch, wl.c_destroy, wl.log_handler = dispatch, destroy_resource, log_message
}
// Test binaries bypass main, so they need the same tables and C bridges at startup.
@(init)
bootstrap :: proc "contextless" () {context = runtime.default_context(); install()}
status :: proc(ok: bool) -> i32 {return 0 if ok else -1}
@(export, link_name = "wl_array_init")
wl_array_init :: proc "c" (a: ^wl.Array) { context = bridge_context; wl.array_init(a) }
@(export, link_name = "wl_array_release")
wl_array_release :: proc "c" (a: ^wl.Array) { context = bridge_context; wl.array_release(a) }
@(export, link_name = "wl_array_add")
wl_array_add :: proc "c" (a: ^wl.Array, size: uint) -> rawptr { context = bridge_context; return wl.array_add(a, size) }
@(export, link_name = "wl_array_copy")
wl_array_copy :: proc "c" (a, b: ^wl.Array) -> i32 { context = bridge_context; return status(wl.array_copy(a, b)) }
@(export, link_name = "wl_list_init")
wl_list_init :: proc "c" (list: ^wl.List) { context = bridge_context; wl.init(list) }
@(export, link_name = "wl_list_insert")
wl_list_insert :: proc "c" (list, link: ^wl.List) { context = bridge_context; wl.insert(list, link) }
@(export, link_name = "wl_list_remove")
wl_list_remove :: proc "c" (link: ^wl.List) { context = bridge_context; wl.list_remove(link) }
@(export, link_name = "wl_list_insert_list")
wl_list_insert_list :: proc "c" (list, other: ^wl.List) { context = bridge_context; wl.insert_list(list, other) }
@(export, link_name = "wl_list_empty")
wl_list_empty :: proc "c" (list: ^wl.List) -> i32 { context = bridge_context; return 1 if wl.empty(list) else 0 }
@(export, link_name = "wl_list_length")
wl_list_length :: proc "c" (list: ^wl.List) -> i32 { context = bridge_context; return wl.list_length(list) }
@(export, link_name = "wl_signal_emit_mutable")
wl_signal_emit_mutable :: proc "c" (signal: ^wl.Signal, data: rawptr) { context = bridge_context; wl.signal_emit_mutable(signal, data) }
@(export, link_name = "wl_display_add_destroy_listener")
wl_display_add_destroy_listener :: proc "c" (d: ^wl.Display, l: ^wl.Listener) { context = bridge_context; wl.signal_add(&d.destroy_signal, l) }
@(export, link_name = "wl_display_get_event_loop")
wl_display_get_event_loop :: proc "c" (d: ^wl.Display) -> ^wl.Loop { context = bridge_context; return d.loop }
@(export, link_name = "wl_display_get_serial")
wl_display_get_serial :: proc "c" (d: ^wl.Display) -> u32 { context = bridge_context; return d.serial }
@(export, link_name = "wl_display_next_serial")
wl_display_next_serial :: proc "c" (d: ^wl.Display) -> u32 { context = bridge_context; d.serial += 1; return d.serial }
@(export, link_name = "wl_client_create")
wl_client_create :: proc "c" (d: ^wl.Display, fd: i32) -> ^wl.Client { context = bridge_context; return wl.client_create(d, fd) }
@(export, link_name = "wl_client_destroy")
wl_client_destroy :: proc "c" (c: ^wl.Client) { context = bridge_context; wl.client_destroy(c) }
@(export, link_name = "wl_client_add_destroy_listener")
wl_client_add_destroy_listener :: proc "c" (c: ^wl.Client, l: ^wl.Listener) { context = bridge_context; wl.signal_add(&c.destroy_signal, l) }
@(export, link_name = "wl_client_get_destroy_listener")
wl_client_get_destroy_listener :: proc "c" (c: ^wl.Client, notify: wl.Notify) -> ^wl.Listener { context = bridge_context; return wl.signal_get(&c.destroy_signal, notify) }
@(export, link_name = "wl_client_get_display")
wl_client_get_display :: proc "c" (c: ^wl.Client) -> ^wl.Display { context = bridge_context; return c.display }
@(export, link_name = "wl_client_get_object")
wl_client_get_object :: proc "c" (c: ^wl.Client, id: u32) -> ^wl.Resource { context = bridge_context; return wl.client_get_object(c, id) }
@(export, link_name = "wl_client_post_no_memory")
wl_client_post_no_memory :: proc "c" (c: ^wl.Client) { context = bridge_context; wl.client_no_memory(c) }
@(export, link_name = "wl_event_loop_add_destroy_listener")
wl_event_loop_add_destroy_listener :: proc "c" (loop: ^wl.Loop, l: ^wl.Listener) { context = bridge_context; wl.signal_add(&loop.destroy_signal, l) }
@(export, link_name = "wl_event_loop_add_fd")
wl_event_loop_add_fd :: proc "c" (loop: ^wl.Loop, fd: i32, mask: u32, callback: FD_Callback, data: rawptr) -> ^wl.Source { context = bridge_context; return add_fd(loop, fd, mask, callback, data) }
@(export, link_name = "wl_event_loop_add_timer")
wl_event_loop_add_timer :: proc "c" (loop: ^wl.Loop, callback: Timer_Callback, data: rawptr) -> ^wl.Source { context = bridge_context; return add_timer(loop, callback, data) }
@(export, link_name = "wl_event_loop_add_idle")
wl_event_loop_add_idle :: proc "c" (loop: ^wl.Loop, callback: Idle_Callback, data: rawptr) -> ^wl.Source { context = bridge_context; return add_idle(loop, callback, data) }
@(export, link_name = "wl_event_loop_dispatch")
wl_event_loop_dispatch :: proc "c" (loop: ^wl.Loop, timeout: i32) -> i32 { context = bridge_context; return status(wl.loop_dispatch(loop, timeout)) }
@(export, link_name = "wl_event_source_remove")
wl_event_source_remove :: proc "c" (source: ^wl.Source) -> i32 { context = bridge_context; wl.source_remove(source); return 0 }
@(export, link_name = "wl_event_source_fd_update")
wl_event_source_fd_update :: proc "c" (source: ^wl.Source, mask: u32) -> i32 { context = bridge_context; return status(wl.source_update_fd(source, transmute(wl.Mask)mask)) }
@(export, link_name = "wl_event_source_timer_update")
wl_event_source_timer_update :: proc "c" (source: ^wl.Source, ms: i32) -> i32 { context = bridge_context; return status(wl.source_arm_timer(source, time.Duration(ms) * time.Millisecond)) }
@(export, link_name = "wl_event_source_check")
wl_event_source_check :: proc "c" (source: ^wl.Source) { context = bridge_context; wl.source_check(source) }
@(export, link_name = "wl_global_create")
wl_global_create :: proc "c" (d: ^wl.Display, iface: ^wl.Interface, version: i32, data: rawptr, bind: Bind_Callback) -> ^wl.Global { context = bridge_context; return add_global(d, iface, version, data, bind) }
@(export, link_name = "wl_global_remove")
wl_global_remove :: proc "c" (g: ^wl.Global) { context = bridge_context; wl.global_remove(g) }
@(export, link_name = "wl_global_destroy")
wl_global_destroy :: proc "c" (g: ^wl.Global) { context = bridge_context; wl.global_destroy(g) }
@(export, link_name = "wl_global_get_display")
wl_global_get_display :: proc "c" (g: ^wl.Global) -> ^wl.Display { context = bridge_context; return g.display }
@(export, link_name = "wl_global_get_name")
wl_global_get_name :: proc "c" (g: ^wl.Global, c: ^wl.Client) -> u32 { context = bridge_context; return g.name }
@(export, link_name = "wl_global_set_user_data")
wl_global_set_user_data :: proc "c" (g: ^wl.Global, data: rawptr) { context = bridge_context; g.data = data }
@(export, link_name = "wl_resource_create")
wl_resource_create :: proc "c" (c: ^wl.Client, iface: ^wl.Interface, version: i32, id: u32) -> ^wl.Resource { context = bridge_context; return wl.resource_create(c, iface, version, id) }
@(export, link_name = "wl_resource_destroy")
wl_resource_destroy :: proc "c" (r: ^wl.Resource) { context = bridge_context; wl.resource_destroy(r) }
@(export, link_name = "wl_resource_add_destroy_listener")
wl_resource_add_destroy_listener :: proc "c" (r: ^wl.Resource, l: ^wl.Listener) { context = bridge_context; wl.signal_add(&r.destroy_signal, l) }
@(export, link_name = "wl_resource_from_link")
wl_resource_from_link :: proc "c" (link: ^wl.List) -> ^wl.Resource { context = bridge_context; return runtime.container_of(link, wl.Resource, "link") }
@(export, link_name = "wl_resource_get_link")
wl_resource_get_link :: proc "c" (r: ^wl.Resource) -> ^wl.List { context = bridge_context; return &r.link }
@(export, link_name = "wl_resource_get_id")
wl_resource_get_id :: proc "c" (r: ^wl.Resource) -> u32 { context = bridge_context; return r.id }
@(export, link_name = "wl_resource_get_interface")
wl_resource_get_interface :: proc "c" (r: ^wl.Resource) -> ^wl.Interface { context = bridge_context; return r.interface }
@(export, link_name = "wl_resource_get_class")
wl_resource_get_class :: proc "c" (r: ^wl.Resource) -> cstring { context = bridge_context; return r.interface.name }
@(export, link_name = "wl_resource_get_client")
wl_resource_get_client :: proc "c" (r: ^wl.Resource) -> ^wl.Client { context = bridge_context; return r.client }
@(export, link_name = "wl_resource_get_version")
wl_resource_get_version :: proc "c" (r: ^wl.Resource) -> i32 { context = bridge_context; return r.version }
@(export, link_name = "wl_resource_get_user_data")
wl_resource_get_user_data :: proc "c" (r: ^wl.Resource) -> rawptr { context = bridge_context; return r.data }
@(export, link_name = "wl_resource_set_user_data")
wl_resource_set_user_data :: proc "c" (r: ^wl.Resource, data: rawptr) { context = bridge_context; r.data = data }
@(export, link_name = "wl_resource_instance_of")
wl_resource_instance_of :: proc "c" (r: ^wl.Resource, iface: ^wl.Interface, impl: rawptr) -> i32 { context = bridge_context; return 1 if wl.interface_equal(r.interface, iface) && r.implementation == impl else 0 }
@(export, link_name = "wl_resource_set_implementation")
wl_resource_set_implementation :: proc "c" (r: ^wl.Resource, impl, data, destroy: rawptr) { context = bridge_context; wl.resource_set_implementation(r, impl, data, destroy) }
@(export, link_name = "wl_resource_post_no_memory")
wl_resource_post_no_memory :: proc "c" (r: ^wl.Resource) { context = bridge_context; wl.client_no_memory(r.client) }
@(export, link_name = "wl_log_set_handler_server")
wl_log_set_handler_server :: proc "c" (handler: Log_Callback) { context = bridge_context; c_log = handler }
