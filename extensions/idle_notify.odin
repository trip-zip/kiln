package extensions

import st "../seat"

import p "../protocols"
import wl "../wayland"
import "base:runtime"
import "core:time"

Idle_Notifier :: struct {
	global: ^wl.Global,
	notifications: [dynamic]^Idle_Notification,
	inhibited: bool,
	destroy: wl.Listener,
}
Idle_Notification :: struct {
	manager: ^Idle_Notifier,
	resource: ^wl.Resource,
	seat: ^st.Seat,
	timer: ^wl.Event_Source,
	timeout: time.Duration,
	idle, obey_inhibitors: bool,
	destroy: wl.Listener,
}
idle_create :: proc(display: ^wl.Display) -> (^Idle_Notifier, ^Idle_Inhibit_Manager) {
	return idle_notifier_create(display), idle_inhibit_create(display)
}
idle_notifier_create :: proc(display: ^wl.Display) -> ^Idle_Notifier {
	m := new(Idle_Notifier)
	m.global = wl.global_create_typed(display, &p.ext_idle_notifier_v1, 2, m, idle_notifier_request)
	if m.global == nil { free(m); return nil }
	wl.listen(&display.destroy_signal, &m.destroy, idle_notifier_destroyed)
	return m
}
idle_notifier_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	m := wl.owner(listener, Idle_Notifier, "destroy")
	context = m.global.display.loop.ctx
	for len(m.notifications) > 0 { wl.resource_destroy(m.notifications[len(m.notifications)-1].resource) }
	wl.unlisten(listener)
	wl.global_destroy(m.global)
	delete(m.notifications)
	free(m)
}
idle_notification_state :: proc(n: ^Idle_Notification, idle: bool) {
	if n.idle == idle { return }
	n.idle = idle
	event := p.Ext_Idle_Notification_V1_Event.idled if idle else p.Ext_Idle_Notification_V1_Event.resumed
	wl.post(n.resource, u32(event))
}
idle_notification_reset :: proc(n: ^Idle_Notification) {
	if n.seat == nil { return }
	if n.manager.inhibited && n.obey_inhibitors {
		idle_notification_state(n, false)
		wl.arm_timer(n.timer, 0)
	} else if n.timeout == 0 {
		idle_notification_state(n, true)
	} else { wl.arm_timer(n.timer, n.timeout) }
}
idle_notification_timeout :: proc(data: rawptr) -> i32 {
	n := cast(^Idle_Notification)data
	if n.seat != nil && !(n.manager.inhibited && n.obey_inhibitors) { idle_notification_state(n, true) }
	return 0
}
idle_activity :: proc(m: ^Idle_Notifier, seat: ^st.Seat) {
	if m == nil { return }
	for n in m.notifications {
		if n.seat != nil && n.seat == seat {
			idle_notification_state(n, false)
			idle_notification_reset(n)
		}
	}
}
idle_inhibit :: proc(m: ^Idle_Notifier, on: bool) {
	if m == nil || m.inhibited == on { return }
	m.inhibited = on
	for n in m.notifications { if n.obey_inhibitors { idle_notification_reset(n) } }
}
idle_notification_release :: proc(n: ^Idle_Notification) {
	wl.unlisten(&n.destroy)
	wl.remove_source(n.timer)
	n.timer, n.seat = nil, nil
}
idle_notification_seat_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
	n := wl.owner(listener, Idle_Notification, "destroy")
	context = n.resource.client.display.loop.ctx
	idle_notification_release(n)
}
idle_notification_destroy :: proc(r: ^wl.Resource) {
	n := cast(^Idle_Notification)r.data
	idle_notification_release(n)
	for other, i in n.manager.notifications { if other == n { ordered_remove(&n.manager.notifications, i); break } }
	free(n)
}
idle_notification_request :: proc(r: ^wl.Resource, request: p.Ext_Idle_Notification_V1_Request, args: []wl.Argument) {
	switch request { case .destroy: wl.resource_destroy(r) }
}
idle_notifier_request :: proc(r: ^wl.Resource, request: p.Ext_Idle_Notifier_V1_Request, args: []wl.Argument) {
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .get_idle_notification, .get_input_idle_notification:
		n := new(Idle_Notification)
		n.manager = cast(^Idle_Notifier)r.data
		n.timeout = time.Duration(args[1].(wl.Uint))*time.Millisecond
		n.obey_inhibitors = request == .get_idle_notification
		n.resource = wl.resource_create_typed(r.client, &p.ext_idle_notification_v1, r.version,
			u32(args[0].(wl.New_Id)), n, idle_notification_request, idle_notification_destroy)
		if n.resource == nil { free(n); return }
		append(&n.manager.notifications, n)
		client := seat_client_of(wl.object(args[2]))
		if client == nil { return }
		n.seat = client.seat
		wl.listen(&n.seat.events.destroy, &n.destroy, idle_notification_seat_destroyed)
		if n.timeout > 0 {
			n.timer = wl.on_timer(r.client.display, idle_notification_timeout, n)
			if n.timer == nil { wl.client_no_memory(r.client); return }
		}
		idle_notification_reset(n)
	}
}
