package scene_paint
import layout "../layout"
import wlr "../wlroots"

Part :: struct {
	node:         ^wlr.wlr_scene_node,
	rect:         ^wlr.wlr_scene_rect,
	buffer:       ^wlr.wlr_scene_buffer,
	pixels:       ^Buffer,
	box, visible: layout.Box,
	initialized:  bool,
}
// Source pixels remain unchanged while scene destinations and source regions crop together.
update :: proc(n: ^Node, command: layout.Command) -> u64 {
	mutations: u64
	if square(command) {
		n.parts[0].box = {
			0,
			0,
			f32(max(0, i32(command.box.width))),
			f32(max(0, i32(command.box.height))),
		}
		if n.command.content.(layout.Rectangle).color != command.content.(layout.Rectangle).color {
			c := premultiply(command.content.(layout.Rectangle).color)
			wlr.wlr_scene_rect_set_color(n.rect, raw_data(c[:]))
			mutations += 1
		}
	}
	for &part in n.parts {
		absolute := part.box
		absolute.x += f32(i32(command.box.x)); absolute.y += f32(i32(command.box.y))
		visible := layout.crop(absolute, command.clip)
		visible.x -= f32(i32(command.box.x)); visible.y -= f32(i32(command.box.y))
		show := i32(visible.width) > 0 && i32(visible.height) > 0
		if part.node.enabled !=
		   show {wlr.wlr_scene_node_set_enabled(part.node, show); mutations += 1}
		if show && (!part.initialized || part.visible != visible) {
			x, y := i32(visible.x), i32(visible.y)
			w, h := i32(visible.width), i32(visible.height)
			if part.node.x != x ||
			   part.node.y != y {wlr.wlr_scene_node_set_position(part.node, x, y); mutations += 1}
			if part.rect != nil {
				if !part.initialized ||
				   i32(part.visible.width) != w ||
				   i32(part.visible.height) != h {
					wlr.wlr_scene_rect_set_size(part.rect, w, h); mutations += 1
				}
			} else {
				sx, sy := x - i32(part.box.x), y - i32(part.box.y)
				ox,oy:=i32(command.box.x)+i32(part.box.x),i32(command.box.y)+i32(part.box.y)
				sx,sy=device_span(ox,sx,n.scale),device_span(oy,sy,n.scale)
				dw,dh:=device_span(i32(command.box.x)+x,w,n.scale),device_span(i32(command.box.y)+y,h,n.scale)
				src := wlr.wlr_fbox{f64(sx), f64(sy), f64(dw), f64(dh)}
				part.pixels.source_scale_x,part.pixels.source_scale_y=f64(dw)/f64(w),f64(dh)/f64(h)
				wlr.wlr_scene_buffer_set_source_box(part.buffer, &src)
				wlr.wlr_scene_buffer_set_dest_size(part.buffer, w, h)
				part.pixels.source_x, part.pixels.source_y = sx, sy
				mutations += 2
			}
		}
		part.visible = visible
		part.initialized = true
	}
	n.command.box = command.box
	n.command.clip = command.clip
	if square(command) {n.command.content = command.content}
	return mutations
}
