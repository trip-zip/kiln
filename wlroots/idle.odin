package wlroots

import wl "../wayland"

idle_create :: proc(display: ^wl.Display) -> (^wlr_idle_notifier_v1, ^wlr_idle_inhibit_manager_v1) {
    return wlr_idle_notifier_v1_create(display), wlr_idle_inhibit_v1_create(display)
}
idle_inhibit :: proc(notifier: ^wlr_idle_notifier_v1, on: bool) { wlr_idle_notifier_v1_set_inhibited(notifier,on) }
idle_activity :: proc(notifier: ^wlr_idle_notifier_v1, seat: ^wlr_seat) { wlr_idle_notifier_v1_notify_activity(notifier,seat) }
surface_root :: proc(surface: ^wlr_surface) -> ^wlr_surface { return wlr_surface_get_root_surface(surface) }
