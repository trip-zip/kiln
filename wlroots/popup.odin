package wlroots

import "core:c"

wlr_xdg_positioner_rules :: struct #align(4) { _opaque: [60]u8 }
wlr_xdg_popup_configure :: struct #align(4) {
    _opaque_0: [4]u8,
    geometry: wlr_box,
    rules: wlr_xdg_positioner_rules,
    _opaque_80: [4]u8,
}
foreign import popup_lib "system:wlroots-0.20"
foreign popup_lib {
    wlr_xdg_positioner_rules_get_geometry :: proc(rules: ^wlr_xdg_positioner_rules, box: ^wlr_box) ---
    wlr_xdg_popup_unconstrain_from_box :: proc(popup: ^wlr_xdg_popup, box: ^wlr_box) ---
    wlr_xdg_popup_get_toplevel_coords :: proc(popup: ^wlr_xdg_popup, x,y: c.int, tx,ty: ^c.int) ---
    wlr_xdg_positioner_rules_unconstrain_box :: proc(rules: ^wlr_xdg_positioner_rules, constraint: ^wlr_box, box: ^wlr_box) ---
}
// wlroots schedules even an unchanged configure. Compare its computed result
// first so retained publication and buffer commits cannot create a feedback loop.
popup_constrain :: proc(popup: ^wlr_xdg_popup, bounds: wlr_box, force: bool) {
    box:=bounds
    x,y: i32
    wlr_xdg_popup_get_toplevel_coords(popup,0,0,&x,&y)
    constraint:=box;constraint.x-=x;constraint.y-=y
    geometry: wlr_box
    wlr_xdg_positioner_rules_get_geometry(&popup.scheduled.rules,&geometry)
    desired:=geometry
    wlr_xdg_positioner_rules_unconstrain_box(&popup.scheduled.rules,&constraint,&geometry)
    if force || geometry!=popup.scheduled.geometry {
        popup.scheduled.geometry=desired
        wlr_xdg_popup_unconstrain_from_box(popup,&box)
    }
}
#assert(size_of(wlr_xdg_positioner_rules)==60)
#assert(align_of(wlr_xdg_positioner_rules)==4)
#assert(size_of(wlr_xdg_popup_configure)==84)
#assert(align_of(wlr_xdg_popup_configure)==4)
#assert(offset_of(wlr_xdg_popup_configure,geometry)==4)
#assert(offset_of(wlr_xdg_popup_configure,rules)==20)
