package shells

import sf "../surfaces"

import st "../seat"

import wl "../wayland"
import wlr "../wlroots"

Surface_Role :: sf.Role
surface_of :: proc(r: ^wl.Resource) -> ^sf.Surface { return sf.of(r) if r != nil else nil }
output_of :: proc(r: ^wl.Resource) -> ^wlr.wlr_output { return wlr.wlr_output_from_resource(r) if r != nil else nil }
has_buffer :: sf.has_buffer
map_surface :: sf.map_
unmap_surface :: sf.unmap
has_pending_buffer :: proc(s: ^sf.Surface) -> bool { return s.pending.buffer_width > 0 && s.pending.buffer_height > 0 }

Surface_Object :: union { ^Xdg_Surface, ^Layer_Surface, ^Lock_Surface, ^st.Drag_Icon }
roles: map[^sf.Surface]Surface_Object
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
drag_role_forget :: proc(i: ^st.Drag_Icon) { sf.unmap(i.surface); role_forget(i) }
role_assign :: proc(object: $T, error_resource: ^wl.Resource, error_code: u32 = 0) -> bool {
	role: ^Surface_Role
	when T == ^Xdg_Surface { role = &xdg_role } else when T == ^Layer_Surface { role = &layer_role } else when T == ^Lock_Surface { role = &lock_role } else when T == ^st.Drag_Icon { role = &drag_icon_role }
	if !sf.set_role(object.surface, role, error_resource, error_code) { return false }
	if roles == nil { roles = make(map[^sf.Surface]Surface_Object) }
	roles[object.surface] = object
	when T != ^st.Drag_Icon { sf.set_role_object(object.surface, object.resource) }
	return true
}
role_client_commit :: proc (surface: ^sf.Surface) {
	switch object in roles[surface] {
	case ^Xdg_Surface: xdg_validate(object)
	case ^Layer_Surface: layer_validate(object)
	case ^Lock_Surface: lock_surface_validate(object)
	case ^st.Drag_Icon:
	}
}
role_commit :: proc (surface: ^sf.Surface) {
	switch object in roles[surface] {
	case ^Xdg_Surface: xdg_commit(object)
	case ^Layer_Surface: layer_commit(object)
	case ^Lock_Surface: lock_surface_commit(object)
	case ^st.Drag_Icon: st.icon_surface_commit(surface)
	}
}
role_map :: proc (surface: ^sf.Surface) {
	if x := xdg_of(surface); x != nil { xdg_geometry(x) }
}
role_unmap :: proc (surface: ^sf.Surface) {
	switch object in roles[surface] {
	case ^Xdg_Surface: xdg_reset(object); object.unmapping = true
	case ^Layer_Surface: layer_reset(object); object.unmapping = true
	case ^Lock_Surface: object.unmapping = true
	case ^st.Drag_Icon:
	}
}
role_destroy :: proc (surface: ^sf.Surface) {
	switch object in roles[surface] {
	case ^Xdg_Surface: xdg_retire(object)
	case ^Layer_Surface: layer_retire(object)
	case ^Lock_Surface: lock_surface_retire(object)
	case ^st.Drag_Icon:
	}
}
role_forget :: proc(object: $T) {
	if roles[object.surface] == Surface_Object(object) {
		delete_key(&roles,object.surface)
		if len(roles)==0 { delete(roles); roles=nil }
	}
}
xdg_of :: proc(surface: ^sf.Surface) -> ^Xdg_Surface {
	x, _ := roles[surface].(^Xdg_Surface)
	return x
}
surface_extents :: proc(s: ^sf.Surface, x := i32(0), y := i32(0)) -> wlr.Box { return wlr.Box(sf.extents(s,x,y)) }

seat_client_of :: st.client_of
valid_grab_serial :: st.valid_serial

popup_list :: proc(surface: ^sf.Surface) -> ^[dynamic]^Popup {
	switch object in roles[surface] {
	case ^Xdg_Surface: return &object.popups
	case ^Layer_Surface: return &object.popups
	case ^Lock_Surface, ^st.Drag_Icon:
	}
	return nil
}
window_geometry :: proc(surface: ^sf.Surface) -> wlr.Box {
	if x := xdg_of(surface); x != nil {
		if x.toplevel != nil {return x.toplevel.geometry}
		if x.popup != nil {return x.popup.geometry}
	}
	return {}
}
surface_tree :: proc(s: ^sf.Surface, x,y: i32, iterator: Surface_Iterator, data: rawptr) { sf.each(s,iterator,data,x,y) }
