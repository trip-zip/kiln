package compositor

import sp "../scene_paint"

import images "../images"
import vm "../lua_runtime"
import wl "../wayland"
import wlr "../wlroots"
import xcb "../xcb"
import ewmh "../xcb_ewmh"
import icccm "../xcb_icccm"
import "base:runtime"
import "core:fmt"
import "core:strings"

X11_View :: struct {
	view:                                                                                  ^View,
	handle:                                                                                ^wlr.wlr_xwayland_surface,
	surface:                                                                               ^wlr.wlr_surface,
	associate, dissociate, configure, activate, geometry:                                  wl.Listener,
	role, icon:                                                                            string,
	role_changed, icon_changed, hints_changed, types_changed, parent_changed, map_request: wl.Listener,
	initial_state:                                                                         bool,
	initial_fullscreen, initial_maximized, initial_minimized:                              bool,
	granted_fullscreen, granted_maximized, granted_minimized:                              bool,
	sent:                                                                                  bool,
	sent_x, sent_y:                                                                        i32,
}
xwayland_surface_added :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "new_xwayland_surface")
	xs := (^wlr.wlr_xwayland_surface)(data)
	v := new(View)
	x := new(X11_View)
	s.next_view_id += 1
	v^ = {
		server    = s,
		allocator = context.allocator,
		protocol  = x,
		id        = s.next_view_id,
	}
	x.view, x.handle = v, xs
	xs.data = v
	append(&s.views, v)
	wl.listen(&xs.events.associate, &x.associate, x11_associate)
	wl.listen(&xs.events.dissociate, &x.dissociate, x11_dissociate)
	wl.listen(&xs.events.destroy, &v.destroy, view_destroy)
	wl.listen(&xs.events.request_configure, &x.configure, x11_configure)
	wl.listen(&xs.events.request_activate, &x.activate, x11_activate)
	wl.listen(&xs.events.set_geometry, &x.geometry, x11_geometry)
	wl.listen(&xs.events.set_title, &v.title, view_title)
	wl.listen(&xs.events.set_class, &v.app_id, view_app_id)
	wl.listen(&xs.events.set_role, &x.role_changed, x11_role_changed)
	wl.listen(&xs.events.set_icon, &x.icon_changed, x11_icon_changed)
	wl.listen(&xs.events.set_hints, &x.hints_changed, x11_hints_changed)
	wl.listen(&xs.events.set_window_type, &x.types_changed, x11_types_changed)
	wl.listen(&xs.events.set_parent, &x.parent_changed, x11_parent_changed)
	wl.listen(&xs.events.map_request, &x.map_request, x11_map_request)
	wl.listen(&xs.events.request_fullscreen, &v.fullscreen, view_fullscreen)
	wl.listen(&xs.events.request_maximize, &v.maximize, view_maximize)
	wl.listen(&xs.events.request_minimize, &v.minimize, x11_minimize)
	fmt.printf("X11 new window=%d handle=%d\n", xs.window_id, v.id)
}
x11_associate :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	x := wl.owner(listener, X11_View, "associate")
	v := x.view
	context.allocator = v.allocator
	assert(x.surface == nil)
	x.surface = x.handle.surface
	wl.listen(&x.surface.events.map_, &v.map_, view_map)
	wl.listen(&x.surface.events.unmap, &v.unmap, view_unmap)
	wl.listen(&x.surface.events.commit, &v.commit, view_commit)
	fmt.printf(
		"X11 associate window=%d handle=%d surface=%p\n",
		x.handle.window_id,
		v.id,
		x.surface,
	)
	if wlr.xwayland_map_buffered(x.surface) {
		fmt.printf("X11 buffered association window=%d handle=%d\n", x.handle.window_id, v.id)
	}
	if !view_override_redirect(v) {record_size(v)}
}
x11_detach :: proc(x: ^X11_View) {
	v := x.view
	if v.mapped {view_unmap(&v.unmap, nil)}
	wl.unlisten(&v.map_)
	wl.unlisten(&v.unmap)
	wl.unlisten(&v.commit)
	if v.output != nil {sp.remove_client(&v.output.paint, v.id)}
	x.surface = nil
	x.sent = false
}
x11_dissociate :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	x := wl.owner(listener, X11_View, "dissociate")
	context.allocator = x.view.allocator
	x11_detach(x)
	fmt.printf("X11 dissociate window=%d handle=%d\n", x.handle.window_id, x.view.id)
}
x11_configure :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	x := wl.owner(listener, X11_View, "configure")
	e := (^wlr.wlr_xwayland_surface_configure_event)(data)
	// wlroots fills absent mask fields from the current cached geometry.
	if !x.view.mapped {wlr.xwayland_configure(x.handle, i32(e.x), i32(e.y), i32(e.width), i32(e.height))
		return}
	queue_event(
		x.view.server,
		vm.Event {
			name = "request::configure",
			handle = x.view.id,
			map_epoch = x.view.map_epoch,
			x = i32(e.x),
			y = i32(e.y),
			width = i32(e.width),
			height = i32(e.height),
		},
	)
}
x11_activate :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	x := wl.owner(listener, X11_View, "activate")
	queue_event(
		x.view.server,
		vm.Event{name = "request::activate", handle = x.view.id, valid = false},
	)
}
x11_minimize :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	v := wl.owner(listener, View, "minimize")
	e := (^wlr.wlr_xwayland_minimize_event)(data)
	queue_event(
		v.server,
		vm.Event {
			name = "request::minimize",
			handle = v.id,
			map_epoch = v.map_epoch,
			on = e.minimize,
		},
	)
}
x11_geometry :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	x := wl.owner(listener, X11_View, "geometry")
	xs := x.handle
	if x.view.mapped && xs.override_redirect {
		queue_event(
			x.view.server,
			vm.Event {
				name = "request::configure",
				handle = x.view.id,
				map_epoch = x.view.map_epoch,
				x = i32(xs.x),
				y = i32(xs.y),
				width = i32(xs.width),
				height = i32(xs.height),
			},
		)
	}
}

publish_view_size :: proc(v: ^View, width, height: i32) {
	if view_override_redirect(v) {return}
	changed := request_size(v, width, height)
	if t := xdg(v); t != nil {
		if changed {wlr.wlr_xdg_toplevel_set_size(t, width, height)
			v.output.configures += 1}
	} else if x := x11(v); x != nil {
		px, py: i32
		if !view_position(v, &px, &py) {return}
		if changed || !x.sent || px != x.sent_x || py != x.sent_y {
			if !wlr.xwayland_configure(x.handle, px, py, width, height) {
				fmt.eprintln(
					"X11 published geometry exceeds protocol limits; retaining last X geometry",
				)
				return
			}
			x.sent, x.sent_x, x.sent_y = true, px, py
			v.output.configures += 1
			fmt.printf(
				"X11 published window=%d handle=%d box=%d,%d,%d,%d\n",
				x.handle.window_id,
				v.id,
				px,
				py,
				width,
				height,
			)
		}
	}
}

x11_read_role :: proc(x: ^X11_View) {
	delete(x.role, x.view.allocator)
	context.allocator = x.view.allocator
	x.role = xcb.role(
		wlr.xwayland_connection(x.view.server.xwayland),
		x.handle.window_id,
		x.view.server.x11_atoms[14],
	)
}
x11_read_icon :: proc(x: ^X11_View) {
	context.allocator = x.view.allocator
	s := x.view.server
	key := fmt.aprintf("xwl-icon:%d", x.view.id)
	defer delete(key)
	pixels, w, h := ewmh.icon(
		wlr.xwayland_connection(s.xwayland),
		x.handle.window_id,
		s.x11_atoms[15],
	)
	defer delete(pixels)
	ok := len(pixels) > 0 && images.put_argb(&s.lua.images, key, w, h, pixels)
	delete(x.icon)
	x.icon = ""
	if ok {x.icon = strings.clone(key)} else {images.retire(&s.lua.images, key)}
	fmt.printf("X11 icon handle=%d accepted=%v size=%dx%d\n", x.view.id, ok, w, h)
}
x11_types :: proc(x: ^X11_View) -> string {
	names := X11_TYPES
	buf: [256]u8
	n := 0
	for atom in x.handle.window_type[:x.handle.window_type_len] {
		for known, i in x.view.server.x11_atoms[:14] {
			if known == 0 || atom != known {continue}
			name := names[i]
			if n + len(name) + (n > 0 ? 1 : 0) >= len(buf) {break}
			if n > 0 {buf[n] = ','
				n += 1}
			copy(buf[n:], name)
			n += len(name)
			break
		}
	}
	return strings.clone(string(buf[:n]))
}
x11_role_changed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	x := wl.owner(listener, X11_View, "role_changed")
	if !x.view.mapped {return}
	x11_read_role(x)
	queue_client(x.view, "metadata")
}
x11_icon_changed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	x := wl.owner(listener, X11_View, "icon_changed")
	if !x.view.mapped {return}
	x11_read_icon(x)
	queue_client(x.view, "metadata")
}
x11_urgency :: proc(x: ^X11_View) {
	if !x.view.mapped {return}
	queue_event(
		x.view.server,
		vm.Event {
			name = "request::urgent",
			handle = x.view.id,
			map_epoch = x.view.map_epoch,
			on = icccm.urgent(x.handle.hints),
		},
	)
}
x11_hints_changed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	x11_urgency(wl.owner(listener, X11_View, "hints_changed"))
}
x11_types_changed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	x := wl.owner(listener, X11_View, "types_changed")
	if x.view.mapped {queue_client(x.view, "metadata")}
}
x11_parent_changed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	x := wl.owner(listener, X11_View, "parent_changed")
	if x.view.mapped {queue_client(x.view, "metadata")}
}

// MapNotify can rewrite _NET_WM_STATE before association has read the initial hints.
// Capture the client's request at the public pre-map hook; Lua still grants it.
x11_map_request :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	x := wl.owner(listener, X11_View, "map_request")
	s := x.view.server
	x.initial_state = false
	reply := xcb.property(
		wlr.xwayland_connection(s.xwayland),
		x.handle.window_id,
		s.x11_atoms[16],
		2048,
		4,
	)
	if reply == nil {return}
	defer xcb.release(reply)
	if reply.bytes_after != 0 ||
	   (reply.type != 0 && (reply.type != 4 || reply.format != 32)) {return}
	bytes := xcb.property_bytes(reply)
	words := ([^]u32)(raw_data(bytes))[:len(bytes) / 4]
	x.initial_state = true
	x.initial_fullscreen, x.initial_maximized, x.initial_minimized = false, false, false
	vert, horz := false, false
	for atom in words {
		if atom == s.x11_atoms[17] {x.initial_fullscreen = true}
		if atom == s.x11_atoms[18] {vert = true}
		if atom == s.x11_atoms[19] {horz = true}
		if atom == s.x11_atoms[20] {x.initial_minimized = true}
	}
	x.initial_maximized = vert && horz
	fmt.printf(
		"X11 initial window=%d fullscreen=%v maximized=%v cached_fullscreen=%v\n",
		x.handle.window_id,
		x.initial_fullscreen,
		x.initial_maximized,
		x.handle.fullscreen,
	)
}
// Only explicit compositor verbs grant state; XWM's optimistic request cache is not authority.
x11_settled_state :: proc(s: ^Server, e: ^vm.Event) {
	if s.xwayland == nil {return}
	if e.class != "" && e.class != "client" {return}
	if e.name != "map" &&
	   e.name != "request::fullscreen" &&
	   e.name != "request::maximize" &&
	   e.name != "request::minimize" {return}
	for v in s.views {
		if v.id != e.handle || !v.mapped {continue}
		x := x11(v)
		if x == nil {return}
		xs := x.handle
		if xs.fullscreen !=
		   x.granted_fullscreen {wlr.xwayland_fullscreen(xs, x.granted_fullscreen)}
		if xs.maximized_horz != x.granted_maximized ||
		   xs.maximized_vert !=
			   x.granted_maximized {wlr.xwayland_maximize(xs, x.granted_maximized)}
		if xs.minimized != x.granted_minimized {wlr.xwayland_minimize(xs, x.granted_minimized)}
		wlr.foreign_fullscreen(v.foreign_handle, x.granted_fullscreen)
		wlr.foreign_maximized(v.foreign_handle, x.granted_maximized)
		wlr.foreign_minimized(v.foreign_handle, x.granted_minimized)
		return
	}
}
