package shells

import gles "../gles"
import p "../protocols"
import wl "../wayland"

Positioner_Rules :: struct {
	width, height:               i32,
	anchor_rect:                 gles.Box,
	anchor, gravity, adjustment: u32,
	offset_x, offset_y:          i32,
	reactive:                    bool,
	parent_width, parent_height: i32,
	parent_configure:            u32,
}
positioner_create :: proc(r: ^wl.Resource, id: u32) {
	rules := new(Positioner_Rules)
	if wl.resource_create_typed(
		   r.client,
		   &p.xdg_positioner,
		   r.version,
		   id,
		   rules,
		   positioner_request,
		   positioner_destroy,
	   ) ==
	   nil {free(rules)}
}
positioner_destroy :: proc(r: ^wl.Resource) {free(cast(^Positioner_Rules)r.data)}
positioner_request :: proc(
	r: ^wl.Resource,
	request: p.Xdg_Positioner_Request,
	args: []wl.Argument,
) {
	v := cast(^Positioner_Rules)r.data
	switch request {
	case .destroy:
		wl.resource_destroy(r)
	case .set_size:
		width, height := i32(args[0].(wl.Int)), i32(args[1].(wl.Int))
		if width <= 0 ||
		   height <=
			   0 {wl.post_error(r, u32(p.Xdg_Positioner_Error.invalid_input), "size must be positive"); return}
		v.width, v.height = width, height
	case .set_anchor_rect:
		box := gles.Box {
			i32(args[0].(wl.Int)),
			i32(args[1].(wl.Int)),
			i32(args[2].(wl.Int)),
			i32(args[3].(wl.Int)),
		}
		if box.width < 0 ||
		   box.height <
			   0 {wl.post_error(r, u32(p.Xdg_Positioner_Error.invalid_input), "anchor size is negative"); return}
		v.anchor_rect = box
	case .set_anchor, .set_gravity:
		value := u32(args[0].(wl.Uint))
		if value >
		   8 {wl.post_error(r, u32(p.Xdg_Positioner_Error.invalid_input), "invalid edge"); return}
		if request == .set_anchor {v.anchor = value} else {v.gravity = value}
	case .set_constraint_adjustment:
		value := u32(args[0].(wl.Uint))
		if value & ~u32(63) !=
		   0 {wl.post_error(r, u32(p.Xdg_Positioner_Error.invalid_input), "invalid constraint adjustment"); return}
		v.adjustment = value
	case .set_offset:
		v.offset_x, v.offset_y = i32(args[0].(wl.Int)), i32(args[1].(wl.Int))
	case .set_reactive:
		v.reactive = true
	case .set_parent_size:
		v.parent_width, v.parent_height = i32(args[0].(wl.Int)), i32(args[1].(wl.Int))
	case .set_parent_configure:
		v.parent_configure = u32(args[0].(wl.Uint))
	}
}

positioner_complete :: proc(r: Positioner_Rules) -> bool {return(
		r.width > 0 &&
		r.height > 0 &&
		r.anchor_rect.width > 0 &&
		r.anchor_rect.height > 0 \
	)}
positioner_axis :: proc(edge: u32, vertical: bool) -> i32 {
	if vertical {
		if edge == 1 || edge == 5 || edge == 7 {return -1}
		if edge == 2 || edge == 6 || edge == 8 {return 1}
	} else {
		if edge == 3 || edge == 5 || edge == 6 {return -1}
		if edge == 4 || edge == 7 || edge == 8 {return 1}
	}
	return 0
}
positioner_coordinate :: proc(start, extent, size, offset, anchor, gravity: i32) -> i32 {
	point := start + offset
	if anchor == 0 {point += extent / 2} else if anchor > 0 {point += extent}
	if gravity == 0 {point -= size / 2} else if gravity < 0 {point -= size}
	return point
}
positioner_geometry :: proc(r: Positioner_Rules) -> gles.Box {
	return {
		positioner_coordinate(
			r.anchor_rect.x,
			r.anchor_rect.width,
			r.width,
			r.offset_x,
			positioner_axis(r.anchor, false),
			positioner_axis(r.gravity, false),
		),
		positioner_coordinate(
			r.anchor_rect.y,
			r.anchor_rect.height,
			r.height,
			r.offset_y,
			positioner_axis(r.anchor, true),
			positioner_axis(r.gravity, true),
		),
		r.width,
		r.height,
	}
}
positioner_unconstrain :: proc(r: Positioner_Rules, constraint: gles.Box) -> gles.Box {
	box := positioner_geometry(r)
	for vertical in ([2]bool{false, true}) {
		pos, size, start, extent := box.x, box.width, constraint.x, constraint.width
		anchor_start, anchor_size, offset := r.anchor_rect.x, r.anchor_rect.width, r.offset_x
		flip, slide, resize := u32(4), u32(1), u32(16)
		if vertical {
			pos, size, start, extent = box.y, box.height, constraint.y, constraint.height
			anchor_start, anchor_size, offset = r.anchor_rect.y, r.anchor_rect.height, r.offset_y
			flip, slide, resize = 8, 2, 32
		}
		low, high := start - pos, pos + size - start - extent
		anchor, gravity :=
			positioner_axis(r.anchor, vertical), positioner_axis(r.gravity, vertical)
		if r.adjustment & flip != 0 && (low > 0) != (high > 0) {
			flipped := positioner_coordinate(
				anchor_start,
				anchor_size,
				size,
				offset,
				-anchor,
				-gravity,
			)
			if flipped >= start && flipped + size <= start + extent {pos = flipped}
		}
		low, high = start - pos, pos + size - start - extent
		if r.adjustment & slide != 0 && (low > 0 || high > 0) {
			if low > 0 && high > 0 {
				if gravity < 0 {pos -= high} else {pos += low}
			} else if abs(low) < abs(high) {pos += low} else {pos -= high}
		}
		low, high = max(0, start - pos), max(0, pos + size - start - extent)
		if r.adjustment & resize != 0 && size - low - high > 0 {pos += low; size -= low + high}
		if vertical {box.y, box.height = pos, size} else {box.x, box.width = pos, size}
	}
	return box
}
