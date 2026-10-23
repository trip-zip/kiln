package scene_paint

import wl "../wayland"
import raw "../wayland"
import wlr "../wlroots"
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
	testing.expect_value(t, o.damage[0], wlr.Box{20, 40, 60, 80})
	clear(&o.damage)
	testing.expect_value(t, publish(&o, parts[:]), 0)
	testing.expect_value(t, len(o.damage), 0)
	parts[0].box.x = 15
	testing.expect_value(t, publish(&o, parts[:]), 1)
	testing.expect_value(t, o.damage[0], wlr.Box{20, 40, 60, 80})
	testing.expect_value(t, o.damage[len(o.damage) - 1], wlr.Box{30, 40, 60, 80})
	parts[0], parts[1] = parts[1], parts[0]
	testing.expect_value(t, publish(&o, parts[:]), 2)
	testing.expect_value(t, o.parts[0].key, 2)
	testing.expect_value(t, o.parts[1].key, 1)
	clear(&o.damage)
	publish(&o, nil)
	testing.expect(t, len(o.parts) == 0 && len(o.damage) > 0)
}

fixture_surface :: proc(s: ^wlr.Surface) {
	s.mapped = true
	s.current.width, s.current.height = 80, 60
	wl.init(&s.current.subsurfaces_below)
	wl.init(&s.current.subsurfaces_above)
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
	parent, child: wlr.Surface
	fixture_surface(&parent)
	fixture_surface(&child)
	sub := wlr.wlr_subsurface {
		surface = &child,
		current = {x = 11, y = 17},
	}
	wl.insert(&parent.current.subsurfaces_below, &sub.current.link)
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
	raw.list_remove(&sub.current.link)
	wl.insert(&parent.current.subsurfaces_above, &sub.current.link)
	sub.current.x, sub.current.y = -9, 31
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
	raw.list_remove(&sub.current.link)
	raw.signal_emit_mutable(&child.events.destroy, &child)
	testing.expect_value(t, len(o.subscriptions), 1)
	testing.expect(t, wl.empty(&child.events.commit.listener_list))
	raw.signal_emit_mutable(&parent.events.destroy, &parent)
	testing.expect(t, len(o.parts) == 0 && len(o.subscriptions) == 0)
	testing.expect(t, wl.empty(&parent.events.commit.listener_list))
}

@(test)
client_hit_resolves_current_subsurfaces_without_raster_picking :: proc(t: ^testing.T) {
	parent, child: wlr.Surface
	fixture_surface(&parent)
	fixture_surface(&child)
	testing.expect(t, test_region_begin(&parent.input_region, []wlr.Box{{0, 0, 80, 60}}))
	testing.expect(t, test_region_begin(&child.input_region, []wlr.Box{{0, 0, 20, 20}}))
	defer test_region_finish(&parent.input_region)
	defer test_region_finish(&child.input_region)
	sub := wlr.wlr_subsurface {
		surface = &child,
		current = {x = 10, y = 15},
	}
	wl.insert(&parent.current.subsurfaces_above, &sub.current.link)
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
	parent, popup_surface, later: wlr.Surface
	fixture_surface(&parent)
	fixture_surface(&popup_surface)
	fixture_surface(&later)
	for surface in ([]^wlr.Surface{&parent, &popup_surface, &later}) {
		testing.expect(t, test_region_begin(&surface.input_region, []wlr.Box{{0, 0, 80, 60}}))
		defer test_region_finish(&surface.input_region)
	}
	base := wlr.wlr_xdg_surface {
		surface = &popup_surface,
	}
	wl.init(&base.popups)
	layer := wlr.wlr_layer_surface_v1 {
		surface = &parent,
	}
	wl.init(&layer.popups)
	popup := wlr.wlr_xdg_popup {
		base = &base,
		current = {geometry = {10, 15, 80, 60}},
	}
	wl.insert(&layer.popups, &popup.link)
	o := Output {
		width  = 200,
		height = 150,
		scale  = 1,
	}
	defer output_finish(&o)
	parts := []Part {
		{kind = .Client, id = 7, surface = &parent, layer = &layer, box = {30, 40, 80, 60}},
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
	testing.expect_value(t, o.damage[0], wlr.Box{30, 40, 90, 75})
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
	a, b: wlr.Render_Buffer
	wl.init(&a.events.destroy.listener_list)
	wl.init(&b.events.destroy.listener_list)
	first := history_acquire(&o, &a)
	boxes := history_repaint(first)
	testing.expect_value(t, len(boxes), 1)
	testing.expect_value(t, boxes[0], wlr.Box{0, 0, 100, 80})
	history_presented(first)
	second := history_acquire(&o, &b)
	box1 := wlr.Box{5, 7, 10, 12}
	box2 := wlr.Box{12, 10, 9, 8}
	box3 := wlr.Box{70, 60, 4, 3}
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
	region: wlr.pixman_region32_t
	testing.expect(t, test_region_begin(&region, boxes[:]))
	defer test_region_finish(&region)
	surface: wlr.Surface
	fixture_surface(&surface)
	surface.input_region = region
	surface.current.width, surface.current.height = 100, 80
	for y in 0 ..< 80 {
		for x in 0 ..< 100 {
			sx, sy: f64
			hit := wlr.surface_at(&surface, f64(x), f64(y), &sx, &sy) != nil
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

foreign import test_pixman "system:pixman-1"
foreign test_pixman {
	@(link_name = "pixman_region32_init_rects")
	test_region_init :: proc(region: ^wlr.pixman_region32_t, boxes: [^]wlr.pixman_box32_t, count: i32) -> i32 ---
	@(link_name = "pixman_region32_fini")
	test_region_finish :: proc(region: ^wlr.pixman_region32_t) ---
}

test_region_begin :: proc(region: ^wlr.pixman_region32_t, boxes: []wlr.Box) -> bool {
	rects := make([]wlr.pixman_box32_t, len(boxes))
	defer delete(rects)
	for b, i in boxes {rects[i] = {b.x, b.y, b.x + b.width, b.y + b.height}}
	return test_region_init(region, raw_data(rects), i32(len(rects))) != 0
}
