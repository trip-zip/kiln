package scene_paint

import gles "../gles"
import sf "../surfaces"
import rg "../region"
import sh "../shells"
import wl "../wayland"
import raw "../wayland"
import "base:runtime"
import "core:testing"

@(test)
flat_publication_damages_old_and_new_device_boxes :: proc(t: ^testing.T) {
	o := Output {
		scale  = 2,
		width  = 400,
		height = 200,
	}
	defer output_finish(&o)
	parts := [2]Part {
		{kind = .Solid, box = {10, 20, 30, 40}, color = {1, 0, 0, 1}, key = 1},
		{kind = .Solid, box = {60, 20, 30, 40}, color = {0, 1, 0, 1}, key = 2},
	}
	testing.expect_value(t, publish(&o, parts[:]), 2)
	testing.expect_value(t, o.damage[0], gles.Box{20, 40, 60, 80})
	clear(&o.damage)
	testing.expect_value(t, publish(&o, parts[:]), 0)
	testing.expect_value(t, len(o.damage), 0)
	parts[0].box.x = 15
	testing.expect_value(t, publish(&o, parts[:]), 1)
	testing.expect_value(t, o.damage[0], gles.Box{20, 40, 60, 80})
	testing.expect_value(t, o.damage[len(o.damage) - 1], gles.Box{30, 40, 60, 80})
	parts[0], parts[1] = parts[1], parts[0]
	testing.expect_value(t, publish(&o, parts[:]), 2)
	testing.expect_value(t, o.parts[0].key, 2)
	testing.expect_value(t, o.parts[1].key, 1)
	clear(&o.damage)
	publish(&o, nil)
	testing.expect(t, len(o.parts) == 0 && len(o.damage) > 0)
}

fixture_surface :: proc(s: ^sf.Surface) {
	s.mapped = true
	s.current.width, s.current.height = 80, 60
	for signal in ([]^wl.Signal{&s.events.commit, &s.events.map_, &s.events.unmap, &s.events.destroy}) {
		wl.init(&signal.listener_list)
	}
}

@(test)
current_subsurface_order_and_desynchronized_damage :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	scene := scene_create()
	defer scene_destroy(scene)
	o := Output {
		scene  = scene,
		scale  = 1,
		width  = 200,
		height = 150,
	}
	defer output_finish(&o)
	parent, child: sf.Surface
	fixture_surface(&parent)
	fixture_surface(&child)
	sub := sf.Subsurface {
		surface = &child,
		current = {x = 11, y = 17},
	}
	append(&parent.current.below,sf.Child{&sub,sub.current.x,sub.current.y})
 defer delete(parent.current.below)
 defer delete(parent.current.above)
	parts := [1]Part{{kind = .Client, id = 7, surface = &parent, box = {10, 20, 80, 60}}}
	publish(&o, parts[:])
	testing.expect_value(t, len(o.subscriptions), 2)
	positions := current_surfaces(o.parts[0])
	testing.expect(
		t,
		len(positions) == 2 && positions[0].surface == &child && positions[1].surface == &parent,
	)
	testing.expect_value(t, positions[0].x, 21)
	testing.expect_value(t, positions[0].y, 37)
	clear(&parent.current.below); clear(&parent.current.above)
	append(&parent.current.above,sf.Child{&sub,sub.current.x,sub.current.y})
	parent.current.above[0].x, parent.current.above[0].y = -9, 31
	raw.signal_emit_mutable(&parent.events.commit, &parent)
	positions = current_surfaces(o.parts[0])
	testing.expect(t, positions[0].surface == &parent && positions[1].surface == &child)
	testing.expect_value(t, positions[1].x, 1)
	testing.expect_value(t, positions[1].y, 51)
	child.mapped = false
	raw.signal_emit_mutable(&child.events.unmap, &child)
	clear(&o.damage)
	child.mapped = true
	raw.signal_emit_mutable(&child.events.map_, &child)
	testing.expect(t, len(o.damage) > 0)
	clear(&o.damage)
	raw.signal_emit_mutable(&child.events.commit, &child)
	testing.expect(t, len(o.damage) > 0)
	clear(&parent.current.below); clear(&parent.current.above)
	raw.signal_emit_mutable(&child.events.destroy, &child)
	testing.expect_value(t, len(o.subscriptions), 1)
	testing.expect(t, wl.empty(&child.events.commit.listener_list))
	raw.signal_emit_mutable(&parent.events.destroy, &parent)
	testing.expect(t, len(o.parts) == 0 && len(o.subscriptions) == 0)
	testing.expect(t, wl.empty(&parent.events.commit.listener_list))
}

@(test)
client_hit_resolves_current_subsurfaces_without_raster_picking :: proc(t: ^testing.T) {
	parent, child: sf.Surface
	fixture_surface(&parent)
	fixture_surface(&child)
	testing.expect(t, test_region_begin(&parent.input_region, []gles.Box{{0, 0, 80, 60}}))
	testing.expect(t, test_region_begin(&child.input_region, []gles.Box{{0, 0, 20, 20}}))
	defer test_region_finish(&parent.input_region)
	defer test_region_finish(&child.input_region)
	sub := sf.Subsurface {
		surface = &child,
		current = {x = 10, y = 15},
	}
	append(&parent.current.above,sf.Child{&sub,sub.current.x,sub.current.y})
	defer delete(parent.current.above)
	o: Output
	defer output_finish(&o)
	append(&o.parts, Part{kind = .Client, id = 7, surface = &parent, box = {30, 40, 80, 60}})
	append(&o.parts, Part{kind = .Solid, color = {1, 0, 0, 1}, box = {30, 40, 80, 60}})
	surface, id, x, y := client_at(&o, 45, 60)
	testing.expect(t, surface == &child && id == 7 && x == 5 && y == 5)
	surface, id, x, y = client_at(&o, 31, 42)
	testing.expect(t, surface == &parent && id == 7 && x == 1 && y == 2)
	surface, _, _, _ = client_at(&o, 29, 40)
	testing.expect(t, surface == nil)
	child.mapped = false
	surface, id, x, y = client_at(&o, 45, 60)
	testing.expect(t, surface == &parent && id == 7 && x == 15 && y == 20)
}

@(test)
later_parts_cannot_occlude_client_popups :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	parent, popup_surface, later: sf.Surface
	fixture_surface(&parent)
	fixture_surface(&popup_surface)
	fixture_surface(&later)
	for surface in ([]^sf.Surface{&parent, &popup_surface, &later}) {
		testing.expect(t, test_region_begin(&surface.input_region, []gles.Box{{0, 0, 80, 60}}))
	}
	defer for surface in ([]^sf.Surface{&parent,&popup_surface,&later}) { test_region_finish(&surface.input_region) }
	base := new(sh.Xdg_Surface); base.surface = &parent
	defer free(base)
	popup := sh.Popup{surface=&popup_surface,parent=&parent,current={geometry={10,15,80,60}}}
	append(&base.popups,&popup)
	defer delete(base.popups)
	saved := sh.roles
	sh.roles = make(map[^sf.Surface]sh.Surface_Object)
	sh.roles[&parent] = base
	defer { delete(sh.roles); sh.roles = saved }
	o := Output {
		width  = 200,
		height = 150,
		scale  = 1,
	}
	defer output_finish(&o)
	parts := []Part {
		{kind = .Client, id = 7, surface = &parent, box = {30, 40, 80, 60}},
		{kind = .Client, id = 8, surface = &later, box = {30, 40, 80, 60}},
		{kind = .Solid, color = {1, 0, 0, 1}, box = {30, 40, 100, 100}},
	}
	publish(&o, parts)
	items := draw_order(&o)
	testing.expect_value(t, len(items), 4)
	testing.expect(t, items[0].position.surface == &parent && items[1].position.surface == &later)
	testing.expect(t, items[2].part.kind == .Solid)
	testing.expect(t, items[3].position.surface == &popup_surface && items[3].position.popup)
	testing.expect(t, items[3].position.x == 40 && items[3].position.y == 55)
	surface, id, x, y := client_at(&o, 45, 60)
	testing.expect(t, surface == &popup_surface && id == 7 && x == 5 && y == 5)
	// Unmapping removes only the popup band and still damages its owning part's old coverage.
	clear(&o.damage)
	popup_surface.mapped = false
	client_damage(&o, 7)
	testing.expect_value(t, o.damage[0], gles.Box{30, 40, 90, 75})
	items = draw_order(&o)
	testing.expect_value(t, len(items), 3)
	surface, id, _, _ = client_at(&o, 45, 60)
	testing.expect(t, surface == &later && id == 8)
}

@(test)
reacquired_buffer_repaints_only_damage_since_presentation :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	scene := scene_create()
	defer scene_destroy(scene)
	o := Output {
		scene  = scene,
		width  = 100,
		height = 80,
	}
	defer output_finish(&o)
	a, b: gles.Buffer
	wl.init(&a.events.destroy.listener_list)
	wl.init(&b.events.destroy.listener_list)
	first := history_acquire(&o, &a)
	boxes := history_repaint(first)
	testing.expect_value(t, len(boxes), 1)
	testing.expect_value(t, boxes[0], gles.Box{0, 0, 100, 80})
	history_presented(first)
	second := history_acquire(&o, &b)
	box1 := gles.Box{5, 7, 10, 12}
	box2 := gles.Box{12, 10, 9, 8}
	box3 := gles.Box{70, 60, 4, 3}
	append(&o.damage, box1)
	history_presented(second)
	clear(&o.damage)
	append(&o.damage, box2)
	history_presented(second)
	clear(&o.damage)
	append(&o.damage, box3)
	reused := history_acquire(&o, &a)
	testing.expect(t, reused == first)
	boxes = history_repaint(reused)
	testing.expect_value(t, len(boxes), 3)
	testing.expect_value(t, boxes[0], box1)
	testing.expect_value(t, boxes[1], box2)
	testing.expect_value(t, boxes[2], box3)
	// Check the actual pass clip point by point, including the gap between rectangles.
	region: rg.Region
	testing.expect(t, test_region_begin(&region, boxes[:]))
	defer test_region_finish(&region)
	surface: sf.Surface
	fixture_surface(&surface)
	surface.input_region = region
	surface.current.width, surface.current.height = 100, 80
	for y in 0 ..< 80 {
		for x in 0 ..< 100 {
			sx, sy: f64
			hit := sf.at(&surface, f64(x), f64(y), &sx, &sy) != nil
			expected :=
				contains(box1, f64(x), f64(y)) ||
				contains(box2, f64(x), f64(y)) ||
				contains(box3, f64(x), f64(y))
			testing.expect_value(t, hit, expected)
		}
	}
	history_presented(reused)
	clear(&o.damage)
	boxes = history_repaint(reused)
	testing.expect_value(t, len(boxes), 0)
	testing.expect_value(t, len(second.boxes), 1)
	testing.expect_value(t, second.boxes[0], box3)
	raw.signal_emit_mutable(&a.events.destroy, &a)
	testing.expect_value(t, len(o.history), 1)
	testing.expect(t, wl.empty(&a.events.destroy.listener_list))
}

test_region_finish :: rg.finish
test_region_begin :: proc(region: ^rg.Region, boxes: []gles.Box) -> bool {
 for b in boxes { rg.union_rect(region,rg.Box(b)) }; return true
}
