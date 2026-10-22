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
