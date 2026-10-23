package wlroots

import wl "../wayland"

pixman_region32_t :: struct #align(8) { _opaque: [24]u8 }
wlr_relative_pointer_manager_v1 :: struct {}
wlr_pointer_constraints_v1 :: struct #align(8) {
    _opaque_0: [24]u8,
    events: struct { destroy, new_constraint: wl.Signal },
    _opaque_56: [32]u8,
}
wlr_pointer_constraint_v1_state :: struct {
    committed: u32,
    region: pixman_region32_t,
    cursor_hint: struct { enabled: bool, x,y: f64 },
}
wlr_pointer_constraint_v1 :: struct #align(8) {
    _opaque_0: [16]u8,
    surface: ^wlr_surface,
    seat: ^wlr_seat,
    _opaque_32: [4]u8,
    type: i32,
    region: pixman_region32_t,
    current: wlr_pointer_constraint_v1_state,
    _opaque_120: [72]u8,
    events: struct { set_region, destroy: wl.Signal },
    _opaque_224: [104]u8,
}
foreign import constraints_lib "system:wlroots-0.20"
foreign constraints_lib {
    wlr_pointer_constraints_v1_create :: proc(display: ^wl.Display) -> ^wlr_pointer_constraints_v1 ---
    wlr_relative_pointer_manager_v1_create :: proc(display: ^wl.Display) -> ^wlr_relative_pointer_manager_v1 ---
    wlr_pointer_constraints_v1_constraint_for_surface :: proc(manager: ^wlr_pointer_constraints_v1, surface: ^wlr_surface, seat: ^wlr_seat) -> ^wlr_pointer_constraint_v1 ---
    wlr_pointer_constraint_v1_send_activated :: proc(constraint: ^wlr_pointer_constraint_v1) ---
    wlr_pointer_constraint_v1_send_deactivated :: proc(constraint: ^wlr_pointer_constraint_v1) ---
    wlr_relative_pointer_manager_v1_send_relative_motion :: proc(manager: ^wlr_relative_pointer_manager_v1, seat: ^wlr_seat, time_usec: u64, dx,dy,ux,uy: f64) ---
    wlr_region_confine :: proc(region: ^pixman_region32_t,x1,y1,x2,y2: f64,ox,oy: ^f64) -> bool ---
    wlr_cursor_absolute_to_layout_coords :: proc(cursor: ^wlr_cursor, device: ^wlr_input_device,x,y: f64,lx,ly: ^f64) ---
    wlr_cursor_warp :: proc(cursor: ^wlr_cursor,device: ^wlr_input_device,x,y: f64) -> bool ---
    wlr_seat_pointer_warp :: proc(seat: ^wlr_seat,x,y: f64) ---
}
constraints_create :: proc(display: ^wl.Display) -> ^wlr_pointer_constraints_v1 { return wlr_pointer_constraints_v1_create(display) }
relative_create :: proc(display: ^wl.Display) -> ^wlr_relative_pointer_manager_v1 { return wlr_relative_pointer_manager_v1_create(display) }
constraint_for :: proc(manager: ^wlr_pointer_constraints_v1,seat: ^wlr_seat) -> ^wlr_pointer_constraint_v1 {
    if manager==nil || seat.pointer_state.focused_surface==nil { return nil }
    return wlr_pointer_constraints_v1_constraint_for_surface(manager,seat.pointer_state.focused_surface,seat)
}
constraint_activate :: proc(c: ^wlr_pointer_constraint_v1) { wlr_pointer_constraint_v1_send_activated(c) }
constraint_deactivate :: proc(c: ^wlr_pointer_constraint_v1) { wlr_pointer_constraint_v1_send_deactivated(c) }
relative_motion :: proc(manager: ^wlr_relative_pointer_manager_v1,seat: ^wlr_seat,time_msec: u32,dx,dy,ux,uy: f64) {
    if manager!=nil { wlr_relative_pointer_manager_v1_send_relative_motion(manager,seat,u64(time_msec)*1000,dx,dy,ux,uy) }
}
constraint_confine :: proc(c: ^wlr_pointer_constraint_v1,seat: ^wlr_seat,dx,dy: f64) -> (f64,f64) {
    x,y:=seat.pointer_state.sx,seat.pointer_state.sy
    nx,ny: f64
    if !wlr_region_confine(&c.region,x,y,x+dx,y+dy,&nx,&ny) { return 0,0 }
    return nx-x,ny-y
}
absolute_position :: proc(cursor: ^wlr_cursor,device: ^wlr_input_device,x,y: f64) -> (f64,f64) {
    lx,ly:f64
    wlr_cursor_absolute_to_layout_coords(cursor,device,x,y,&lx,&ly)
    return lx,ly
}
constraint_warp :: proc(cursor: ^wlr_cursor,seat: ^wlr_seat,x,y: f64) {
    if wlr_cursor_warp(cursor,nil,cursor.x-seat.pointer_state.sx+x,cursor.y-seat.pointer_state.sy+y) {
        wlr_seat_pointer_warp(seat,x,y)
    }
}
#assert(size_of(pixman_region32_t)==24 && align_of(pixman_region32_t)==8)
#assert(size_of(wlr_pointer_constraints_v1)==88 && align_of(wlr_pointer_constraints_v1)==8)
#assert(offset_of(wlr_pointer_constraints_v1,events)==24)
#assert(size_of(type_of(wlr_pointer_constraints_v1{}.events))==32 && align_of(type_of(wlr_pointer_constraints_v1{}.events))==8)
#assert(offset_of(type_of(wlr_pointer_constraints_v1{}.events),destroy)==0)
#assert(offset_of(type_of(wlr_pointer_constraints_v1{}.events),new_constraint)==16)
#assert(size_of(wlr_pointer_constraint_v1_state)==56 && align_of(wlr_pointer_constraint_v1_state)==8)
#assert(offset_of(wlr_pointer_constraint_v1_state,committed)==0 && offset_of(wlr_pointer_constraint_v1_state,region)==8)
#assert(offset_of(wlr_pointer_constraint_v1_state,cursor_hint)==32)
#assert(size_of(type_of(wlr_pointer_constraint_v1_state{}.cursor_hint))==24 && align_of(type_of(wlr_pointer_constraint_v1_state{}.cursor_hint))==8)
#assert(offset_of(type_of(wlr_pointer_constraint_v1_state{}.cursor_hint),enabled)==0)
#assert(offset_of(type_of(wlr_pointer_constraint_v1_state{}.cursor_hint),x)==8)
#assert(offset_of(type_of(wlr_pointer_constraint_v1_state{}.cursor_hint),y)==16)
#assert(size_of(wlr_pointer_constraint_v1)==328 && align_of(wlr_pointer_constraint_v1)==8)
#assert(offset_of(wlr_pointer_constraint_v1,surface)==16 && offset_of(wlr_pointer_constraint_v1,seat)==24)
#assert(offset_of(wlr_pointer_constraint_v1,type)==36 && offset_of(wlr_pointer_constraint_v1,region)==40)
#assert(offset_of(wlr_pointer_constraint_v1,current)==64 && offset_of(wlr_pointer_constraint_v1,events)==192)
#assert(size_of(type_of(wlr_pointer_constraint_v1{}.events))==32 && align_of(type_of(wlr_pointer_constraint_v1{}.events))==8)
#assert(offset_of(type_of(wlr_pointer_constraint_v1{}.events),set_region)==0)
#assert(offset_of(type_of(wlr_pointer_constraint_v1{}.events),destroy)==16)
