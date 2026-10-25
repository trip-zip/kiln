package scene_paint

import "../buffers"
import sf "../surfaces"
import st "../seat"
import "../gles"
import paint "../paint"
import "core:math"

Cursor :: struct {
	surface:         ^sf.Surface,
	pixels:          ^Buffer,
	image:           rawptr,
	box, device_box: gles.Box,
	shown:           bool,
}

cursor_set :: proc(
	o: ^Output,
	surface: ^sf.Surface,
	image: ^st.Cursor_Image,
	x, y: f64,
	hx, hy: i32,
) {
	old := o.cursor
	next := old
	next.surface = surface
	next.shown =
		x >= f64(o.bounds.x) &&
		y >= f64(o.bounds.y) &&
		x < f64(o.bounds.x + o.bounds.width) &&
		y < f64(o.bounds.y + o.bounds.height)
	width, height: i32
	hot_x, hot_y := f64(hx), f64(hy)
	if image != nil {
		width, height =
			i32(math.ceil(f64(image.width) / f64(o.scale))),
			i32(math.ceil(f64(image.height) / f64(o.scale)))
		hot_x, hot_y = f64(image.hotspot_x) / f64(o.scale), f64(image.hotspot_y) / f64(o.scale)
	} else if surface != nil {width, height = surface.current.width, surface.current.height}
	next.box = {
		i32(math.floor(x - f64(o.bounds.x) - hot_x)),
		i32(math.floor(y - f64(o.bounds.y) - hot_y)),
		width,
		height,
	}
	next.device_box = output_box(o, next.box)
	if image != nil {
		box := gles.Box {
			i32(math.floor((x - f64(o.bounds.x)) * f64(o.scale) - f64(image.hotspot_x))),
			i32(math.floor((y - f64(o.bounds.y)) * f64(o.scale) - f64(image.hotspot_y))),
			i32(image.width),
			i32(image.height),
		}
		tw, th := o.width, o.height
		if o.transform % 2 != 0 {tw, th = th, tw}
		next.device_box = gles.transform_box(box, gles.transform_invert(o.transform), tw, th)
	}
	if next.image != rawptr(image) {
		if next.pixels != nil {
			buffers.unlock(&next.pixels.base)
			next.pixels = nil
		}
		next.image = image
		if image != nil {
			s, ok := paint.create(i32(image.width), i32(image.height))
			if ok {
				for row in 0 ..< int(image.height) {
					src := image.buffer[row * int(image.width) * 4:][:int(image.width) * 4]
					dst := paint.data(s)[row * int(s.stride):][:len(src)]
					copy(dst, src)
				}
				next.pixels = wrap(s)
			}
		}
	}
	if next != old {
		if old.shown {damage_box(o, old.device_box)}
		if next.shown {damage_box(o, next.device_box)}
		o.cursor = next
		refresh_subscriptions(o)
	}
}

cursor_finish :: proc(o: ^Output) {
	if o.cursor.pixels != nil {
		buffers.unlock(&o.cursor.pixels.base)
	}
	o.cursor = {}
}

draw_cursor :: proc(
	o: ^Output,
	pass: ^gles.Pass,
	repaint: []gles.Box,
	drawn: ^[dynamic]^sf.Surface,
) -> bool {
	c := o.cursor
	if !c.shown {return true}
	t: ^gles.Texture
	source: gles.FBox
	transform := gles.transform_invert(o.transform)
	if c.surface != nil {
		t = surface_texture(o, c.surface)
		source = gles.FBox(sf.source_box(c.surface))
		transform = gles.transform_compose(
			gles.transform_invert(c.surface.current.transform),
			transform,
		)
		for e in o.subscriptions {
			if e.surface == c.surface {e.visible = true}
		}
	} else if c.pixels != nil {
		t = gles.import_buffer(o.renderer, &c.pixels.base)
		source = {0, 0, f64(c.pixels.base.width), f64(c.pixels.base.height)}
	}
	if t == nil {return true}
	box := c.device_box
	painted := false
	for r in repaint {
		b := intersection(r, box)
		if b.width > 0 && b.height > 0 {
			painted = true
			break
		}
	}
	if !painted {return true}
	if !draw_texture(o, pass, t, source, box, box, transform, repaint) {return false}
	if c.surface != nil {append(drawn, c.surface)}
	return true
}
