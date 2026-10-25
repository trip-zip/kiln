package input_config

import bk "../backend"
import raw "../libinput"
import "core:c"
Optional :: struct($T: typeid) { value: T, present: bool }
Pointer :: struct {
	tap_to_click, natural_scrolling, left_handed: Optional(bool),
	accel_speed: Optional(f64),
	accel_profile, scroll_method, click_method: Optional(string),
}
profile :: proc(name: string) -> c.int { return name == "flat" ? 1 : 2 }
scroll :: proc(name: string) -> c.int {
	switch name { case "two_finger": return 1; case "edge": return 2; case "button": return 4 }
	return 0
}
click :: proc(name: string) -> c.int {
	switch name { case "button_areas": return 1; case "clickfinger": return 2 }
	return 0
}
apply :: proc(device: ^bk.Device, cfg: Pointer) {
	dev := device.libinput
	if dev == nil { return }
	if cfg.tap_to_click.present && raw.libinput_device_config_tap_get_finger_count(dev)>0 {
		raw.libinput_device_config_tap_set_enabled(dev, c.int(cfg.tap_to_click.value))
	}
	if cfg.natural_scrolling.present && raw.libinput_device_config_scroll_has_natural_scroll(dev)!=0 {
		raw.libinput_device_config_scroll_set_natural_scroll_enabled(dev, c.int(cfg.natural_scrolling.value))
	}
	if cfg.left_handed.present && raw.libinput_device_config_left_handed_is_available(dev)!=0 {
		raw.libinput_device_config_left_handed_set(dev, c.int(cfg.left_handed.value))
	}
	if cfg.accel_speed.present && raw.libinput_device_config_accel_is_available(dev)!=0 {
		raw.libinput_device_config_accel_set_speed(dev, cfg.accel_speed.value)
	}
	if cfg.accel_profile.present {
		v := profile(cfg.accel_profile.value)
		if raw.libinput_device_config_accel_get_profiles(dev)&u32(v)!=0 { raw.libinput_device_config_accel_set_profile(dev,v) }
	}
	if cfg.scroll_method.present {
		v := scroll(cfg.scroll_method.value)
		if v==0 || raw.libinput_device_config_scroll_get_methods(dev)&u32(v)!=0 { raw.libinput_device_config_scroll_set_method(dev,v) }
	}
	if cfg.click_method.present {
		v := click(cfg.click_method.value)
		if v==0 || raw.libinput_device_config_click_get_methods(dev)&u32(v)!=0 { raw.libinput_device_config_click_set_method(dev,v) }
	}
}
