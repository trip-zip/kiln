package shells

import st "../seat"

import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"

Surface_Role :: struct {
	name: cstring,
	no_object: bool,
	client_commit, commit, map_, unmap, destroy: proc "c" (^wlr.Surface),
}
#assert(size_of(Surface_Role) == 56 && align_of(Surface_Role) == 8)
#assert(offset_of(Surface_Role, name) == 0 && offset_of(Surface_Role, no_object) == 8)
#assert(offset_of(Surface_Role, client_commit) == 16 && offset_of(Surface_Role, commit) == 24)
#assert(offset_of(Surface_Role, map_) == 32 && offset_of(Surface_Role, unmap) == 40)
#assert(offset_of(Surface_Role, destroy) == 48)

foreign import role_lib "system:wlroots-0.20"
foreign role_lib {
	wlr_surface_set_role :: proc(^wlr.Surface, ^Surface_Role, ^wl.Resource, u32) -> bool ---
	wlr_surface_set_role_object :: proc(^wlr.Surface, ^wl.Resource) ---
	wlr_surface_map :: proc(^wlr.Surface) ---
	wlr_surface_unmap :: proc(^wlr.Surface) ---
	wlr_surface_has_buffer :: proc(^wlr.Surface) -> bool ---
}
surface_of :: proc(r: ^wl.Resource) -> ^wlr.Surface { return wlr.wlr_surface_from_resource(r) if r != nil else nil }
output_of :: proc(r: ^wl.Resource) -> ^wlr.wlr_output { return wlr.wlr_output_from_resource(r) if r != nil else nil }
has_buffer :: wlr_surface_has_buffer
map_surface :: wlr_surface_map
unmap_surface :: wlr_surface_unmap
has_pending_buffer :: proc(s: ^wlr.Surface) -> bool { return s.pending.buffer_width > 0 && s.pending.buffer_height > 0 }

Surface_Object :: union { ^Xdg_Surface, ^Layer_Surface, ^Lock_Surface, ^st.Drag_Icon }
roles: map[^wlr.Surface]Surface_Object
xdg_role := Surface_Role{name = "xdg_surface", client_commit = role_client_commit, commit = role_commit,
	map_ = role_map, unmap = role_unmap, destroy = role_destroy}
layer_role := Surface_Role{name = "zwlr_layer_surface_v1", client_commit = role_client_commit, commit = role_commit,
	unmap = role_unmap, destroy = role_destroy}
lock_role := Surface_Role{name = "ext_session_lock_surface_v1", client_commit = role_client_commit, commit = role_commit,
	unmap = role_unmap, destroy = role_destroy}
drag_icon_role := Surface_Role{name="wl_data_device.icon", no_object=true, commit=role_commit}
@(init)
install_drag_role :: proc "contextless"() { st.drag_icon_assign = drag_role_assign; st.drag_icon_forget = drag_role_forget }
drag_role_assign :: proc(i: ^st.Drag_Icon, r: ^wl.Resource) -> bool {
	if roles[i.surface] != nil { wl.post_error(r, 0, "surface already has an active role"); return false }
	if !role_assign(i, r) { return false }; st.icon_surface_commit(i.surface); return true
}
drag_role_forget :: proc(i: ^st.Drag_Icon) { wlr_surface_unmap(i.surface); role_forget(i) }
role_assign :: proc(object: $T, error_resource: ^wl.Resource, error_code: u32 = 0) -> bool {
	role: ^Surface_Role
	when T == ^Xdg_Surface { role = &xdg_role } else when T == ^Layer_Surface { role = &layer_role } else when T == ^Lock_Surface { role = &lock_role } else when T == ^st.Drag_Icon { role = &drag_icon_role }
	if !wlr_surface_set_role(object.surface, role, error_resource, error_code) { return false }
	if roles == nil { roles = make(map[^wlr.Surface]Surface_Object) }
	roles[object.surface] = object
	when T != ^st.Drag_Icon { wlr_surface_set_role_object(object.surface, object.resource) }
	return true
}
role_client_commit :: proc "c" (surface: ^wlr.Surface) {
	context = runtime.default_context()
	switch object in roles[surface] {
	case ^Xdg_Surface: context = object.resource.client.display.loop.ctx; xdg_validate(object)
	case ^Layer_Surface: context = object.resource.client.display.loop.ctx; layer_validate(object)
	case ^Lock_Surface: context = object.resource.client.display.loop.ctx; lock_surface_validate(object)
	case ^st.Drag_Icon:
	}
}
role_commit :: proc "c" (surface: ^wlr.Surface) {
	context = runtime.default_context()
	switch object in roles[surface] {
	case ^Xdg_Surface: context = object.resource.client.display.loop.ctx; xdg_commit(object)
	case ^Layer_Surface: context = object.resource.client.display.loop.ctx; layer_commit(object)
	case ^Lock_Surface: context = object.resource.client.display.loop.ctx; lock_surface_commit(object)
	case ^st.Drag_Icon: context = surface.resource.client.display.loop.ctx; st.icon_surface_commit(surface)
	}
}
role_map :: proc "c" (surface: ^wlr.Surface) {
	context = runtime.default_context()
	if x := xdg_of(surface); x != nil { context = x.resource.client.display.loop.ctx; xdg_geometry(x) }
}
role_unmap :: proc "c" (surface: ^wlr.Surface) {
	context = runtime.default_context()
	switch object in roles[surface] {
	case ^Xdg_Surface: context = object.resource.client.display.loop.ctx; xdg_reset(object); object.unmapping = true
	case ^Layer_Surface: context = object.resource.client.display.loop.ctx; layer_reset(object); object.unmapping = true
	case ^Lock_Surface: context = object.resource.client.display.loop.ctx; object.unmapping = true
	case ^st.Drag_Icon:
	}
}
role_destroy :: proc "c" (surface: ^wlr.Surface) {
	context = runtime.default_context()
	switch object in roles[surface] {
	case ^Xdg_Surface: context = object.resource.client.display.loop.ctx; xdg_retire(object)
	case ^Layer_Surface: context = object.resource.client.display.loop.ctx; layer_retire(object)
	case ^Lock_Surface: context = object.resource.client.display.loop.ctx; lock_surface_retire(object)
	case ^st.Drag_Icon:
	}
}
role_forget :: proc(object: $T) {
	if roles[object.surface] == Surface_Object(object) {
		delete_key(&roles,object.surface)
		if len(roles)==0 { delete(roles); roles=nil }
	}
}
xdg_of :: proc(surface: ^wlr.Surface) -> ^Xdg_Surface {
	x, _ := roles[surface].(^Xdg_Surface)
	return x
}
// Role geometry must include mapped subsurfaces without depending on another surface API.
surface_extents :: proc(s: ^wlr.Surface, x := i32(0), y := i32(0)) -> wlr.Box {
	box := wlr.Box{x, y, s.current.width, s.current.height}
	for head in ([]^wl.List{&s.current.subsurfaces_below, &s.current.subsurfaces_above}) {
		if head.next == nil { continue }
		it := wl.iterate(head)
		for link in wl.next(&it) {
			state := runtime.container_of(link, wlr.wlr_subsurface_parent_state, "link")
			sub := runtime.container_of(state, wlr.wlr_subsurface, "current")
			if !sub.surface.mapped { continue }
			b := surface_extents(sub.surface, x+state.x, y+state.y)
			right, bottom := max(box.x+box.width, b.x+b.width), max(box.y+box.height, b.y+b.height)
			box.x, box.y = min(box.x, b.x), min(box.y, b.y)
			box.width, box.height = right-box.x, bottom-box.y
		}
	}
	return box
}

seat_client_of :: st.client_of
valid_grab_serial :: st.valid_serial

popup_list :: proc(surface: ^wlr.Surface) -> ^[dynamic]^Popup {
	switch object in roles[surface] {
	case ^Xdg_Surface: return &object.popups
	case ^Layer_Surface: return &object.popups
	case ^Lock_Surface, ^st.Drag_Icon:
	}
	return nil
}
window_geometry :: proc(surface: ^wlr.Surface) -> wlr.Box {
	if x := xdg_of(surface); x != nil {
		if x.toplevel != nil {return x.toplevel.geometry}
		if x.popup != nil {return x.popup.geometry}
	}
	return {}
}
surface_tree :: proc(s: ^wlr.Surface, x, y: i32, iterator: Surface_Iterator, data: rawptr) {
	for head, i in ([]^wl.List{&s.current.subsurfaces_below, &s.current.subsurfaces_above}) {
		if i == 1 {iterator(s, x, y, data)}
		if head.next == nil {continue}
		it := wl.iterate(head)
		for link in wl.next(&it) {
			state := runtime.container_of(link, wlr.wlr_subsurface_parent_state, "link")
			sub := runtime.container_of(state, wlr.wlr_subsurface, "current")
			if sub.surface.mapped {surface_tree(sub.surface, x + state.x, y + state.y, iterator, data)}
		}
	}
}
