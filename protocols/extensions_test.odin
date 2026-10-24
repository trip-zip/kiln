package protocols

import wl "../wayland"
import "core:testing"

@(test)
extension_tables_link_across_generated_files :: proc(t: ^testing.T) {
	pointer := wp_cursor_shape_manager_v1.methods[u32(Wp_Cursor_Shape_Manager_V1_Request.get_pointer)]
	testing.expect(t, pointer.types[0] == &wp_cursor_shape_device_v1)
	testing.expect(t, pointer.types[1] == &wl_pointer)
	tablet := wp_cursor_shape_manager_v1.methods[u32(Wp_Cursor_Shape_Manager_V1_Request.get_tablet_tool_v2)]
	testing.expect(t, tablet.types[0] == &wp_cursor_shape_device_v1)
	testing.expect(t, tablet.types[1] == &zwp_tablet_tool_v2)
	capture := zwlr_screencopy_manager_v1.methods[u32(Zwlr_Screencopy_Manager_V1_Request.capture_output)]
	testing.expect(t, capture.types[0] == &zwlr_screencopy_frame_v1)
	testing.expect(t, capture.types[1] == nil)
	testing.expect(t, capture.types[2] == &wl_output)
	copy := zwlr_screencopy_frame_v1.methods[u32(Zwlr_Screencopy_Frame_V1_Request.copy)]
	testing.expect(t, copy.types[0] == &wl_buffer)
}

@(test)
extension_versions_and_wire_values_survive_generation :: proc(t: ^testing.T) {
	input := &ext_idle_notifier_v1.methods[u32(Ext_Idle_Notifier_V1_Request.get_input_idle_notification)]
	testing.expect_value(t, wl.message_since(input), i32(2))
	testing.expect_value(t, string(input.signature), "2nuo")
	testing.expect(t, input.types[2] == &wl_seat)
	parent := &zwlr_foreign_toplevel_handle_v1.events[u32(Zwlr_Foreign_Toplevel_Handle_V1_Event.parent)]
	testing.expect_value(t, wl.message_since(parent), i32(3))
	testing.expect_value(t, string(parent.signature), "3?o")
	testing.expect(t, parent.types[0] == &zwlr_foreign_toplevel_handle_v1)
	buffer_done := &zwlr_screencopy_frame_v1.events[u32(Zwlr_Screencopy_Frame_V1_Event.buffer_done)]
	testing.expect_value(t, wl.message_since(buffer_done), i32(3))
	testing.expect_value(t, u32(Wp_Cursor_Shape_Device_V1_Shape.dnd_ask), u32(35))
	testing.expect_value(t, u32(Wp_Cursor_Shape_Device_V1_Shape.all_resize), u32(36))
}
