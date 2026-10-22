package compositor

import "base:runtime"
import "core:fmt"
import images "../images"
import wl "../wayland"
import wlr "../wlroots"
import layout "../layout"
import vm "../lua_runtime"

View :: struct {
	server: ^Server,
	protocol: union {^wlr.wlr_xdg_toplevel, ^X11_View},
	allocator: runtime.Allocator,
	tree: ^wlr.wlr_scene_tree,
	mapped: bool,
	foreign_handle: ^wlr.wlr_foreign_toplevel_handle_v1,
	foreign_output: ^wlr.wlr_output,
	foreign_title, foreign_app: string,
	foreign_allocator: runtime.Allocator,
	foreign_maximize, foreign_minimize, foreign_activate, foreign_fullscreen, foreign_close: wl.Listener,
	decoration: ^wlr.wlr_xdg_toplevel_decoration_v1,
	decoration_requested: bool,
	decoration_mode: i32,
	decoration_request, decoration_destroy: wl.Listener,
	map_epoch: u64,
	output: ^Output,
	id: u32,
	requested_width, requested_height: i32,
	last_width, last_height: i32,
	map_, unmap, commit, destroy, maximize, fullscreen, minimize, title, app_id: wl.Listener,
}

focus :: proc(view: ^View) {
	s := view.server
    if locked(s) { return }
	if s.focused != nil && s.focused != view {
		wlr.foreign_activated(s.focused.foreign_handle,false)
		view_activate(s.focused, false)
	}
	changed := s.focused != view
	s.focused = view
	wlr.foreign_activated(view.foreign_handle,true)
	view_activate(view, true)
	enter_surface(s,view_surface(view))
	if changed { queue_event(s, vm.Event{class="input", name="focus", handle=view.id}) }
}

view_added :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "new_toplevel")
	toplevel := (^wlr.wlr_xdg_toplevel)(data)
	tree := wlr.wlr_scene_xdg_surface_create(s.desktop_tree, toplevel.base)
	if tree == nil { fail(s, "Failed to create client scene"); return }
	view := new(View)
	view.server, view.protocol, view.tree = s, toplevel, tree
	view.allocator=context.allocator
	s.next_view_id += 1
	view.id = s.next_view_id
	wlr.wlr_scene_node_set_enabled(&tree.node, false)
	tree.node.data = view
	toplevel.base.data = tree
	append(&s.views, view)
	events := &toplevel.base.surface.events
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

view_map :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	view := wl.owner(listener, View, "map_")
	view.mapped = true
	view.map_epoch += 1
	if x:=x11(view);x!=nil { x11_read_role(x);x11_read_icon(x) }
	foreign_create(view)
	queue_client(view, "map")
	if x:=x11(view);x!=nil { x11_urgency(x) }
	if view.decoration_requested { queue_decoration(view) }
	fmt.printf("Mapped toplevel: %s\n", view_title_text(view))
}

view_unmap :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	view := wl.owner(listener, View, "unmap")
	foreign_destroy(view)
	queue_client(view, "unmap")
	for output in view.server.outputs { layout.forget_client(&output.ui, view.id) }
	view.mapped = false
	wlr.wlr_scene_node_set_enabled(&view.tree.node, false)
	pointer_target_refresh(view.server)
	dirty(view.output)
	view.requested_width, view.requested_height = 0, 0
	s := view.server
	if s.requested_focus == view.id { s.requested_focus = 0 }
	if s.focused == view { clear_focus(s) }
}

view_commit :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	view := wl.owner(listener, View, "commit")
	if t:=xdg(view);t!=nil && t.base.initial_commit {
		if wl.resource_version(xdg(view).resource) >= 2 { wlr.wlr_xdg_toplevel_set_tiled(xdg(view), 15) }
		wlr.wlr_xdg_toplevel_set_size(xdg(view), 0, 0)
	}
	if xdg(view)!=nil { wlr.decoration_server_mode(view.decoration) }
	if !view_override_redirect(view) { record_size(view) }
}
record_size :: proc(view: ^View) {
	g := view_geometry(view)
	if view.mapped && (g.width != view.last_width || g.height != view.last_height) {
		view.last_width, view.last_height = g.width, g.height
		queue_client(view, "commit_size")
	}
}

view_destroy :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	view := wl.owner(listener, View, "destroy")
	context.allocator=view.allocator
	if view.mapped { view_unmap(&view.unmap,nil) }
	foreign_destroy(view)
	queue_client(view, "destroy")
	for output in view.server.outputs { layout.forget_client(&output.ui, view.id) }
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
	if view.server.focused == view { clear_focus(view.server) }
	if view.server.requested_focus == view.id { view.server.requested_focus = 0 }
	for other, i in view.server.views {
		if other == view { ordered_remove(&view.server.views, i); break }
	}
	if x:=x11(view);x!=nil {
		x11_detach(x)
		for l in ([]^wl.Listener{&x.associate,&x.dissociate,&x.configure,&x.activate,&x.geometry,&x.role_changed,&x.icon_changed,&x.hints_changed,&x.types_changed,&x.parent_changed,&x.map_request}) { wl.unlisten(l) }
		x.handle.data=nil
		images.retire(&view.server.lua.images,x.icon)
		delete(x.role);delete(x.icon)
		wlr.wlr_scene_node_destroy(&view.tree.node)
		free(x,view.allocator)
	}
	free(view,view.allocator)
}

// State requests need a configure reply even when the policy declines them.
reply_state :: proc(view: ^View) {
	if t:=xdg(view);t!=nil && t.base.initialized {
		wlr.wlr_xdg_surface_schedule_configure(xdg(view).base)
	}
}
view_maximize :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	view := wl.owner(listener, View, "maximize")
	queue_client(view, "request::maximize")
	reply_state(view)
}
view_fullscreen :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	view := wl.owner(listener, View, "fullscreen")
	queue_client(view, "request::fullscreen")
	reply_state(view)
}

clear_focus :: proc(s: ^Server) {
	if s.focused==nil && s.seat!=nil && s.seat.keyboard_state.focused_surface!=nil { queue_event(s,vm.Event{class="input",name="focus"}) }
	if s.focused != nil {
		wlr.foreign_activated(s.focused.foreign_handle,false)
		view_activate(s.focused, false)
		s.focused = nil
		queue_event(s, vm.Event{class="input", name="focus"})
	}
	if s.seat != nil && !locked(s) { wlr.wlr_seat_keyboard_notify_clear_focus(s.seat) }
}
view_minimize :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	queue_client(wl.owner(listener, View, "minimize"), "request::minimize")
}
view_title :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	v:=wl.owner(listener,View,"title")
	foreign_identity(v)
	queue_client(v,"metadata")
}
view_app_id :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	v:=wl.owner(listener,View,"app_id")
	foreign_identity(v)
	queue_client(v,"metadata")
}

enter_surface :: proc(s: ^Server, surface: ^wlr.wlr_surface) {
    if locked(s) { return }
	if !s.keyboard_grabbed {
		if kb := wlr.wlr_seat_get_keyboard(s.seat); kb != nil {
			keys: [32]u32
			count := 0
			for code in kb.keycodes[:kb.num_keycodes] {
				consumed := true
				for keyboard in s.keyboards { if keyboard.handle == kb { value, exists := keyboard.consumed[code]; consumed = !exists || value; break } }
				if !consumed { keys[count] = code; count += 1 }
			}
			wlr.wlr_seat_keyboard_notify_enter(s.seat, surface,
				raw_data(keys[:]), uint(count), &kb.modifiers)
		} else {
			modifiers: wlr.wlr_keyboard_modifiers
			wlr.wlr_seat_keyboard_notify_enter(s.seat, surface, nil, 0, &modifiers)
		}
	}
}
