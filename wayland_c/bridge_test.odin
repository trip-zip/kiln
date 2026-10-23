package wayland_c

import wl "../wayland"
import "core:sys/linux"
import "core:testing"

Post_Event :: #type proc "c" (res: ^wl.Resource, opcode: u32, #c_vararg args: ..any)
Post_Error :: #type proc "c" (res: ^wl.Resource, code: u32, format: cstring, #c_vararg args: ..any)

@(test)
variadic_events_and_errors_cross_registers_and_stack :: proc(t: ^testing.T) {
	display := wl.create()
	defer wl.destroy(display)
	fds: [2]linux.Fd
	testing.expect_value(t, linux.socketpair(.UNIX, .STREAM, {}, &fds), .NONE)
	defer linux.close(fds[1])
	client := wl.client_create(display, i32(fds[0]))
	defer wl.client_destroy(client)
	message := wl.Message{name="value", signature="isuuuui"}
	iface := wl.Interface{name="bridge", version=1, event_count=1, events=cast([^]wl.Message)&message}
	resource := wl.resource_create(client, &iface, 1, 2)
	Post_Event(rawptr(wl_resource_post_event))(resource, 0, i32(-42), cstring("hello"), u32(3), u32(4), u32(5), u32(6), i32(-7))
	bytes: [128]u8
	n := wl.ring_size(&client.connection.output)
	wl.ring_copy(&client.connection.output, bytes[:n])
	testing.expect_value(t, wl.word_read(bytes[:], 8), u32(0xffffffd6))
	testing.expect_value(t, string(bytes[16:21]), "hello")
	testing.expect_value(t, wl.word_read(bytes[:], n-4), u32(0xfffffff9))
	client.connection.output.tail = client.connection.output.head
	Post_Error(rawptr(wl_resource_post_error))(resource, 9, "bad %s: %d (%u, %s)", cstring("name"), i32(-42), u32(99), cstring("tail"))
	n = wl.ring_size(&client.connection.output)
	wl.ring_copy(&client.connection.output, bytes[:n])
	testing.expect(t, client.failed)
	testing.expect_value(t, wl.word_read(bytes[:], 12), u32(9))
	length := wl.word_read(bytes[:], 16)
	testing.expect_value(t, string(bytes[20:20+length-1]), "bad name: -42 (99, tail)")
}

Call_Result :: struct { integer, fd: i32, object: ^wl.Resource, new_id: u32, array_size: uint, text: [5]u8 }
request :: proc "c" (client: ^wl.Client, resource: ^wl.Resource, integer: i32, text: cstring, object: ^wl.Resource, new_id: u32, array: ^wl.Array, fd: i32) {
	context = client.display.loop.ctx
	result := cast(^Call_Result)resource.data
	result.integer, result.fd, result.object, result.new_id, result.array_size = integer, fd, object, new_id, array.size
	copy(result.text[:], string(text))
}
@(test)
request_dispatch_converts_tagged_arguments_for_c :: proc(t: ^testing.T) {
	result: Call_Result
	loop := wl.loop_create()
	defer wl.loop_destroy(loop)
	display := wl.Display{loop=loop}
	client := wl.Client{display=&display}
	table := [1]rawptr{rawptr(request)}
	resource := wl.Resource{client=&client, data=&result, implementation=&table}
	dispatch(&resource, 0, []wl.Argument{wl.Int(-9), wl.String{value="hello"}, wl.Object(&resource), wl.New_Id(13), wl.Array{size=7}, wl.Fd(19)})
	testing.expect_value(t, result.integer, i32(-9))
	testing.expect_value(t, result.fd, i32(19))
	testing.expect_value(t, result.object, &resource)
	testing.expect_value(t, result.new_id, u32(13))
	testing.expect_value(t, result.array_size, uint(7))
	testing.expect_value(t, string(result.text[:]), "hello")
}
