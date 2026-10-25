package libinput

import "core:c"
foreign import lib "system:input"
libinput_device :: struct {}
foreign lib {
	libinput_device_config_tap_get_finger_count :: proc(device: ^libinput_device) -> c.int ---
	libinput_device_config_tap_set_enabled :: proc(device: ^libinput_device, enabled: c.int) -> c.int ---
	libinput_device_config_scroll_has_natural_scroll :: proc(device: ^libinput_device) -> c.int ---
	libinput_device_config_scroll_set_natural_scroll_enabled :: proc(device: ^libinput_device, enabled: c.int) -> c.int ---
	libinput_device_config_left_handed_is_available :: proc(device: ^libinput_device) -> c.int ---
	libinput_device_config_left_handed_set :: proc(device: ^libinput_device, enabled: c.int) -> c.int ---
	libinput_device_config_accel_is_available :: proc(device: ^libinput_device) -> c.int ---
	libinput_device_config_accel_set_speed :: proc(device: ^libinput_device, speed: f64) -> c.int ---
	libinput_device_config_accel_get_profiles :: proc(device: ^libinput_device) -> u32 ---
	libinput_device_config_accel_set_profile :: proc(device: ^libinput_device, profile: c.int) -> c.int ---
	libinput_device_config_scroll_get_methods :: proc(device: ^libinput_device) -> u32 ---
	libinput_device_config_scroll_set_method :: proc(device: ^libinput_device, method: c.int) -> c.int ---
	libinput_device_config_click_get_methods :: proc(device: ^libinput_device) -> u32 ---
	libinput_device_config_click_set_method :: proc(device: ^libinput_device, method: c.int) -> c.int ---
}
libinput_log_priority :: enum c.int { LIBINPUT_LOG_PRIORITY_DEBUG = 10, LIBINPUT_LOG_PRIORITY_INFO = 20, LIBINPUT_LOG_PRIORITY_ERROR = 30 }
libinput :: struct {}
libinput_event :: struct {}
libinput_event_keyboard :: struct {}
libinput_event_pointer :: struct {}
libinput_interface :: struct {
	open_restricted: proc "c" (cstring,c.int,rawptr) -> c.int,
	close_restricted: proc "c" (c.int,rawptr),
}
#assert(size_of(libinput_interface) == 16 && offset_of(libinput_interface,open_restricted) == 0 && offset_of(libinput_interface,close_restricted) == 8)
foreign lib {
	libinput_log_set_priority :: proc(ctx: ^libinput, priority: libinput_log_priority) ---
	libinput_path_create_context :: proc(interface: ^libinput_interface, data: rawptr) -> ^libinput ---
	libinput_path_add_device :: proc(ctx: ^libinput, path: cstring) -> ^libinput_device ---
	libinput_path_remove_device :: proc(device: ^libinput_device) ---
	libinput_unref :: proc(ctx: ^libinput) -> ^libinput ---
	libinput_get_fd :: proc(ctx: ^libinput) -> c.int ---
	libinput_dispatch :: proc(ctx: ^libinput) -> c.int ---
	libinput_suspend :: proc(ctx: ^libinput) ---
	libinput_resume :: proc(ctx: ^libinput) -> c.int ---
	libinput_get_event :: proc(ctx: ^libinput) -> ^libinput_event ---
	libinput_event_destroy :: proc(event: ^libinput_event) ---
	libinput_event_get_type :: proc(event: ^libinput_event) -> c.int ---
	libinput_event_get_device :: proc(event: ^libinput_event) -> ^libinput_device ---
	libinput_event_get_keyboard_event :: proc(event: ^libinput_event) -> ^libinput_event_keyboard ---
	libinput_event_get_pointer_event :: proc(event: ^libinput_event) -> ^libinput_event_pointer ---
	libinput_device_ref :: proc(device: ^libinput_device) -> ^libinput_device ---
	libinput_device_unref :: proc(device: ^libinput_device) -> ^libinput_device ---
	libinput_device_has_capability :: proc(device: ^libinput_device, capability: c.int) -> c.int ---
	libinput_device_get_name :: proc(device: ^libinput_device) -> cstring ---
	libinput_device_get_sysname :: proc(device: ^libinput_device) -> cstring ---
	libinput_device_get_output_name :: proc(device: ^libinput_device) -> cstring ---
	libinput_device_led_update :: proc(device: ^libinput_device, leds: c.int) ---
	libinput_event_keyboard_get_time_usec :: proc(event: ^libinput_event_keyboard) -> u64 ---
	libinput_event_keyboard_get_key :: proc(event: ^libinput_event_keyboard) -> u32 ---
	libinput_event_keyboard_get_key_state :: proc(event: ^libinput_event_keyboard) -> c.int ---
	libinput_event_pointer_get_time_usec :: proc(event: ^libinput_event_pointer) -> u64 ---
	libinput_event_pointer_get_dx :: proc(event: ^libinput_event_pointer) -> f64 ---
	libinput_event_pointer_get_dy :: proc(event: ^libinput_event_pointer) -> f64 ---
	libinput_event_pointer_get_dx_unaccelerated :: proc(event: ^libinput_event_pointer) -> f64 ---
	libinput_event_pointer_get_dy_unaccelerated :: proc(event: ^libinput_event_pointer) -> f64 ---
	libinput_event_pointer_get_absolute_x_transformed :: proc(event: ^libinput_event_pointer, width: u32) -> f64 ---
	libinput_event_pointer_get_absolute_y_transformed :: proc(event: ^libinput_event_pointer, height: u32) -> f64 ---
	libinput_event_pointer_get_button :: proc(event: ^libinput_event_pointer) -> u32 ---
	libinput_event_pointer_get_button_state :: proc(event: ^libinput_event_pointer) -> c.int ---
	libinput_event_pointer_has_axis :: proc(event: ^libinput_event_pointer, axis: c.int) -> c.int ---
	libinput_event_pointer_get_scroll_value :: proc(event: ^libinput_event_pointer, axis: c.int) -> f64 ---
	libinput_event_pointer_get_scroll_value_v120 :: proc(event: ^libinput_event_pointer, axis: c.int) -> f64 ---
	libinput_device_config_scroll_get_natural_scroll_enabled :: proc(device: ^libinput_device) -> c.int ---
}
