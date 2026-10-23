package scene_paint

import layout "../layout"
import wlr "../wlroots"

Kind :: enum {
	Solid,
	Raster,
	Client,
}
Part :: struct {
	box:               wlr.Box,
	kind:              Kind,
	color:             [4]f32,
	pixels:            ^Buffer,
	surface:           ^wlr.Surface,
	xdg:               ^wlr.wlr_xdg_surface,
	layer:             ^wlr.wlr_layer_surface_v1,
	source:            wlr.wlr_fbox,
	coverage, visible: wlr.Box,
	id:                u32,
	key:               u64,
	initialized:       bool,
}

// Source pixels remain unchanged while destinations and source regions crop together.
update :: proc(n: ^Node, command: layout.Command) -> u64 {
	mutations: u64
	if square(command) {
		n.parts[0].box = {0, 0, max(0, i32(command.box.width)), max(0, i32(command.box.height))}
		color := premultiply(command.content.(layout.Rectangle).color)
		if n.parts[0].color != color {
			n.parts[0].color = color
			mutations += 1
		}
	}
	for &part in n.parts {
		ox, oy := i32(command.box.x), i32(command.box.y)
		absolute := layout.Box {
			f32(part.box.x + ox),
			f32(part.box.y + oy),
			f32(part.box.width),
			f32(part.box.height),
		}
		crop := layout.crop(absolute, command.clip)
		visible := wlr.Box{i32(crop.x) - ox, i32(crop.y) - oy, i32(crop.width), i32(crop.height)}
		if !part.initialized || part.visible != visible {
			mutations += 1
			if part.pixels != nil && visible.width > 0 && visible.height > 0 {
				x, y := ox + part.box.x, oy + part.box.y
				sx := device_span(x, visible.x - part.box.x, n.scale)
				sy := device_span(y, visible.y - part.box.y, n.scale)
				dw := device_span(ox + visible.x, visible.width, n.scale)
				dh := device_span(oy + visible.y, visible.height, n.scale)
				part.source = {f64(sx), f64(sy), f64(dw), f64(dh)}
				part.pixels.source_x, part.pixels.source_y = sx, sy
				part.pixels.source_scale_x = f64(dw) / f64(visible.width)
				part.pixels.source_scale_y = f64(dh) / f64(visible.height)
			}
		}
		part.visible = visible
		part.initialized = true
	}
	n.command.box, n.command.clip = command.box, command.clip
	if square(command) {n.command.content = command.content}
	return mutations
}

placed :: proc(part: Part, command: layout.Command) -> Part {
	p := part
	p.box = p.visible
	p.box.x += i32(command.box.x)
	p.box.y += i32(command.box.y)
	p.key = key(command)
	return p
}
