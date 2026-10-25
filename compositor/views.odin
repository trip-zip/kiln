package compositor

import out "../outputs"
import sf "../surfaces"
import st "../seat"
import sh "../shells"
import ext "../extensions"
import sp "../scene_paint"
import images "../images"
import layout "../layout"
import vm "../lua_runtime"
import wl "../wayland"
import "base:runtime"
import "core:fmt"

View :: struct {
	server:                                                                                  ^Server,
	protocol:                                                                                union {
		^sh.Toplevel,
		^X11_View,
	},
	allocator:                                                                               runtime.Allocator,
	mapped:                                                                                  bool,
	foreign_handle:                                                                          ^ext.Foreign_Handle,
	foreign_output:                                                                          ^out.Output,
	foreign_title,
	foreign_app:                                                              string,
	foreign_allocator:                                                                       runtime.Allocator,
	foreign_maximize,
	foreign_minimize,
	foreign_activate,
	foreign_fullscreen,
	foreign_close: wl.Listener,
	decoration:                                                                              ^sh.Decoration,
	decoration_requested:                                                                    bool,
	decoration_mode:                                                                         i32,
	decoration_request,
	decoration_destroy:                                                  wl.Listener,
	map_epoch:                                                                               u64,
	output:                                                                                  ^Output,
	id:                                                                                      u32,
	requested_width,
	requested_height:                                                       i32,
	last_width,
	last_height:                                                                 i32,
	map_,
	unmap,
	commit,
	destroy,
	maximize,
	fullscreen,
	minimize,
	title,
	app_id:             wl.Listener,
}

focus :: proc(view: ^View) {
	s := view.server
	if locked(s) {return}
	if s.focused != nil && s.focused != view {
		ext.foreign_activated(s.focused.foreign_handle, false)
		view_activate(s.focused, false)
	}
	changed := s.focused != view
	s.focused = view
	ext.foreign_activated(view.foreign_handle, true)
	view_activate(view, true)
	enter_surface(s, view_surface(view))
	if changed {queue_event(s, vm.Event{class = "input", name = "focus", handle = view.id})}
}

view_added :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "new_toplevel")
	toplevel := (^sh.Toplevel)(data)
	view := new(View)
	view.server, view.protocol = s, toplevel
	view.allocator = context.allocator
	s.next_view_id += 1
	view.id = s.next_view_id
	append(&s.views, view)
	events := &toplevel.surface.events
	wl.listen(&events.map_, &view.map_, view_map)
	wl.listen(&events.unmap, &view.unmap, view_unmap)
	wl.listen(&events.commit, &view.commit, view_commit)
	wl.listen(&toplevel.events.destroy, &view.destroy, view_destroy)
	wl.listen(&toplevel.events.request_maximize, &view.maximize, view_maximize)
	wl.listen(&toplevel.events.request_fullscreen, &view.fullscreen, view_fullscreen)
	wl.listen(&toplevel.events.request_minimize, &view.minimize, view_minimize)
	wl.listen(&toplevel.events.set_title, &view.title, view_title)
	wl.listen(&toplevel.events.set_app_id, &view.app_id, view_app_id)
}

view_map :: proc (listener: ^wl.Listener, data: rawptr) {
	view := wl.owner(listener, View, "map_")
	view.mapped = true
	view.map_epoch += 1
	if x := x11(view); x != nil {x11_read_role(x)
		x11_read_icon(x)}
	foreign_create(view)
	queue_client(view, "map")
	if x := x11(view); x != nil {x11_urgency(x)}
	if view.decoration_requested {queue_decoration(view)}
	fmt.printf("Mapped toplevel: %s\n", view_title_text(view))
}

view_unmap :: proc (listener: ^wl.Listener, data: rawptr) {
	view := wl.owner(listener, View, "unmap")
	foreign_destroy(view)
	queue_client(view, "unmap")
	for output in view.server.outputs {layout.forget_client(&output.ui, view.id)}
	view.mapped = false
	if view.output != nil {sp.remove_client(&view.output.paint, view.id)}
	pointer_target_refresh(view.server)
	dirty(view.output)
	view.requested_width, view.requested_height = 0, 0
	s := view.server
	if s.requested_focus == view.id {s.requested_focus = 0}
	if s.focused == view {clear_focus(s)}
}

view_commit :: proc (listener: ^wl.Listener, data: rawptr) {
	view := wl.owner(listener, View, "commit")
	if view.output != nil {
		if t := xdg(view); t != nil { sp.client_damage(&view.output.paint, view.id, &t.geometry) }
		else { sp.client_damage(&view.output.paint, view.id) }
	}
	if t := xdg(view); t != nil && t.initial_commit {
		if wl.resource_version(xdg(view).resource) >=
		   2 {sh.set_tiled(xdg(view), 15)}
		sh.set_size(xdg(view), 0, 0)
	}
	if xdg(view) != nil {sh.decoration_server_mode(view.decoration)}
	if !view_override_redirect(view) {record_size(view)}
}
record_size :: proc(view: ^View) {
	g := view_geometry(view)
	if view.mapped && (g.width != view.last_width || g.height != view.last_height) {
		view.last_width, view.last_height = g.width, g.height
		queue_client(view, "commit_size")
	}
}

view_destroy :: proc(listener: ^wl.Listener, data: rawptr) {
	view := wl.owner(listener, View, "destroy")
	context.allocator = view.allocator
	if view.mapped {view_unmap(&view.unmap, nil)}
	foreign_destroy(view)
	if view.output != nil {sp.remove_client(&view.output.paint, view.id)}
	queue_client(view, "destroy")
	for output in view.server.outputs {layout.forget_client(&output.ui, view.id)}
	wl.unlisten(&view.map_)
	wl.unlisten(&view.unmap)
	wl.unlisten(&view.commit)
	wl.unlisten(&view.destroy)
	wl.unlisten(&view.maximize)
	wl.unlisten(&view.fullscreen)
	wl.unlisten(&view.minimize)
	wl.unlisten(&view.title)
	wl.unlisten(&view.app_id)
	wl.unlisten(&view.decoration_request)
	wl.unlisten(&view.decoration_destroy)
	if view.server.focused == view {clear_focus(view.server)}
	if view.server.requested_focus == view.id {view.server.requested_focus = 0}
	for other, i in view.server.views {
		if other == view {ordered_remove(&view.server.views, i)
			break}
	}
	if x := x11(view); x != nil {
		x11_detach(x)
		for l in ([]^wl.Listener{&x.associate, &x.dissociate, &x.configure, &x.activate, &x.geometry, &x.role_changed, &x.icon_changed, &x.hints_changed, &x.types_changed, &x.parent_changed, &x.map_request}) {wl.unlisten(l)}
		x.handle.data = nil
		images.retire(&view.server.lua.images, x.icon)
		delete(x.role)
		delete(x.icon)
		free(x, view.allocator)
	}
	free(view, view.allocator)
}

// State requests need a configure reply even when the policy declines them.
reply_state :: proc(view: ^View) {
	if t := xdg(view); t != nil && t.initialized {
		sh.schedule_configure(xdg(view))
	}
}
view_maximize :: proc(listener: ^wl.Listener, data: rawptr) {
	view := wl.owner(listener, View, "maximize")
	queue_client(view, "request::maximize")
	reply_state(view)
}
view_fullscreen :: proc(listener: ^wl.Listener, data: rawptr) {
	view := wl.owner(listener, View, "fullscreen")
	queue_client(view, "request::fullscreen")
	reply_state(view)
}

clear_focus :: proc(s: ^Server) {
	if s.focused == nil &&
	   s.seat != nil &&
	   s.seat.keyboard_state.focused_surface !=
		   nil {queue_event(s, vm.Event{class = "input", name = "focus"})}
	if s.focused != nil {
		ext.foreign_activated(s.focused.foreign_handle, false)
		view_activate(s.focused, false)
		s.focused = nil
		queue_event(s, vm.Event{class = "input", name = "focus"})
	}
	if s.seat != nil && !locked(s) && sh.grab_surface(s.shell) == nil {st.keyboard_notify_clear_focus(s.seat)}
}
view_minimize :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	queue_client(wl.owner(listener, View, "minimize"), "request::minimize")
}
view_title :: proc(listener: ^wl.Listener, data: rawptr) {
	v := wl.owner(listener, View, "title")
	foreign_identity(v)
	queue_client(v, "metadata")
}
view_app_id :: proc(listener: ^wl.Listener, data: rawptr) {
	v := wl.owner(listener, View, "app_id")
	foreign_identity(v)
	queue_client(v, "metadata")
}

enter_surface :: proc(s: ^Server, target: ^sf.Surface) {
	surface := target
	if grabbed := sh.grab_surface(s.shell); grabbed != nil {surface = grabbed}
	if locked(s) {return}
	if !s.keyboard_grabbed {
		if kb := st.get_keyboard(s.seat); kb != nil {
			keys := make([dynamic]u32, context.temp_allocator)
			for code in kb.keycodes[:] {
				consumed := true
				for keyboard in s.keyboards {if &keyboard.keyboard == kb {value, exists := keyboard.consumed[code]
						consumed = !exists || value
						break}}
				if !consumed {append(&keys, code)}
			}
			st.keyboard_enter(
				s.seat,
				surface,
				keys[:],
				kb.modifiers,
			)
		} else {
			modifiers: st.Modifiers
			st.keyboard_enter(s.seat, surface, nil, modifiers)
		}
	}
}
