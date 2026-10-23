package compositor

import layout "../layout"
import vm "../lua_runtime"
import sp "../scene_paint"
import wlr "../wlroots"
import "core:fmt"


dirty :: proc(output: ^Output) {
	if output == nil {return}
	output.dirty = true
	if output.handle.enabled {wlr.wlr_output_schedule_frame(output.handle)}
}

// Compare against our last request, never against the client's committed size.
request_size :: proc(view: ^View, width, height: i32) -> bool {
	if view.requested_width == width && view.requested_height == height {return false}
	view.requested_width, view.requested_height = width, height
	return true
}

reconcile :: proc(output: ^Output, original: []layout.Command) -> bool {
	commands := original
	output.mutations, output.rasters = 0, 0
	before := sp.created_buffers
	defer output.rasters = sp.created_buffers - before
	prepared := make(map[u64]^sp.Node)
	defer delete(prepared)
	wanted := make(map[u64]bool)
	defer delete(wanted)
	defer {for _, n in prepared {sp.destroy(n)}}
	fonts := output.ui.fonts
	if fonts == nil {fonts = &output.ui.fallback_fonts}
	for command in commands {
		if client, ok := command.content.(layout.Client); ok {
			if output.server != nil {for v in output.server.views {
					if v.id != client.id || x11(v) == nil || view_override_redirect(v) {continue}
					x, y := f64(command.box.x) + f64(output.x), f64(command.box.y) + f64(output.y)
					if x < -32768 ||
					   x > 32767 ||
					   y < -32768 ||
					   y > 32767 ||
					   command.box.width > 65535 ||
					   command.box.height > 65535 {
						fmt.eprintln(
							"X11 geometry exceeds signed-16 coordinates or unsigned-16 dimensions; keeping published frame",
						)
						return false
					}
				}}
			continue
		}
		key := sp.key(command)
		wanted[key] = true
		old := output.chrome[key]
		if old != nil &&
		   (sp.reusable(old, command, layout.density(&output.ui)) ||
				   (sp.square(old.command) && sp.square(command))) {continue}
		n, ok := sp.create(command, fonts, layout.density(&output.ui))
		if !ok {return false}
		prepared[key] = n
	}
	// Publish only after every raster candidate succeeds.
	for key, n in prepared {
		if old := output.chrome[key]; old != nil {damage_chrome(output, key)
			sp.destroy(old)
			output.mutations += 1}
		output.mutations += 1
		output.chrome[key] = n
	}
	clear(&prepared)
	stale := make([dynamic]u64)
	defer delete(stale)
	for key, n in output.chrome {if !wanted[key] {damage_chrome(output, key)
			sp.destroy(n)
			append(&stale, key)
			output.mutations += 1}}
	for key in stale {delete_key(&output.chrome, key)}
	parts := make([dynamic]sp.Part)
	defer delete(parts)
	for command in commands {
		if content, client := command.content.(layout.Client); client {
			part := sp.Part {
				kind = .Client,
				id   = content.id,
				key  = sp.key(command),
				box  = {
					i32(command.box.x),
					i32(command.box.y),
					i32(command.box.width),
					i32(command.box.height),
				},
			}
			view: ^View
			if output.server != nil {
				for v in output.server.views {if v.id == content.id && v.mapped {view = v
						break}}
			}
			if view != nil {
				if view.output != output {
					if view.output != nil {
						layout.forget_client(&view.output.ui, view.id)
						sp.remove_client(&view.output.paint, view.id)
					}
					view.output = output
					foreign_place(view, output)
				}
				part.surface = view_surface(view)
				if top := xdg(view); top != nil {part.xdg = top.base}
			} else {
				l := find_layer(output.server, content.id)
				if l == nil || !l.mapped {continue}
				if l.output != output {
					if l.output != nil {
						layout.forget_client(&l.output.ui, l.id)
						sp.remove_client(&l.output.paint, l.id)
					}
					l.output = output
					if !l.explicit_output {l.handle.output = output.handle}
				}
				part.surface, part.layer = l.handle.surface, l.handle
			}
			append(&parts, part)
		} else {
			n := output.chrome[sp.key(command)]
			output.mutations += sp.update(n, command)
			for p in n.parts {
				part := sp.placed(p, command)
				if part.box.width > 0 && part.box.height > 0 {append(&parts, part)}
			}
		}
	}
	if output.server != nil {
		if part, ok := drag_part(output.server, output); ok { append(&parts, part) }
	}
	output.mutations += sp.publish(&output.paint, parts[:])
	if output.server != nil {
		for view in output.server.views {
			if view.output != output {continue}
			if part, ok := sp.find_client(&output.paint, view.id); ok {
				publish_view_size(view, max(1, part.box.width), max(1, part.box.height))
			}
		}
	}
	if s := output.server; s != nil {
		settle_focus_request(s, output)
		if l := find_layer(s, s.requested_focus); l != nil && l.mapped && l.output == output {
			if client_visible(
				l.output,
				l.id,
			) {enter_surface(s, l.handle.surface)} else {s.requested_focus = 0
				clear_focus(s)}
		}
		if s.focused != nil && !client_visible(s.focused.output, s.focused.id) {
			clear_focus(s)
		}
		for view in s.views {
			if view.id == s.requested_focus &&
			   view.mapped &&
			   view.output == output &&
			   client_visible(view.output, view.id) &&
			   (s.focused != view ||
					   (!s.keyboard_grabbed && runtime_focused(s) != view.id)) {focus(view)}
		}
	}
	idle_recompute(output.server)
	pointer_target_refresh(output.server)
	return true
}

damage_chrome :: proc(output: ^Output, key: u64) {
	for part in output.paint.parts {if part.key == key {sp.damage_part(&output.paint, part)}}
}
client_visible :: proc(output: ^Output, id: u32) -> bool {
	if output == nil {return false}
	_, ok := sp.find_client(&output.paint, id)
	return ok
}
view_position :: proc(v: ^View, x, y: ^i32) -> bool {
	if v.output == nil {return false}
	p, ok := sp.find_client(&v.output.paint, v.id)
	x^, y^ = v.output.x + p.box.x, v.output.y + p.box.y
	return ok
}
clear_chrome :: proc(output: ^Output) {
	sp.publish(&output.paint, nil)
	for _, n in output.chrome {sp.destroy(n)}
	delete(output.chrome)
}

arrange :: proc(output: ^Output) -> bool {
	if locked(output.server) {return arrange_lock(output)}
	if output.arranging {return true}
	if pending_layout_facts(output) {
		dirty(output)
		return true
	}
	box: wlr.wlr_box
	wlr.wlr_output_layout_get_box(output.server.layout, output.handle, &box)
	if output.x != box.x || output.y != box.y {
		output.x, output.y = box.x, box.y
		// Output placement is already committed even if a new declaration fails.
		for v in output.server.views {
			if x11(v) != nil &&
			   v.output == output &&
			   v.mapped &&
			   v.requested_width > 0 &&
			   v.requested_height > 0 {
				publish_view_size(v, v.requested_width, v.requested_height)
			}
		}
	}
	if box.width != output.width || box.height != output.height {output.dirty = true}
	if !output.dirty {return true}
	output.width, output.height = box.width, box.height
	output.dirty = false
	output.arranging = true
	defer output.arranging = false
	output.ui.scale = output.handle.scale
	nodes, valid := vm.declare(
		&output.server.lua,
		&output.ui,
		string(output.handle.name),
		box.width,
		box.height,
	)
	if !valid {return true}
	was_inspecting := layout.inspector_enabled(&output.ui)
	commands, ok := layout.prepare(&output.ui, box.width, box.height, nodes)
	if !ok {return true}
	if !reconcile(output, commands) {layout.rollback(&output.ui)
		fmt.eprintln("Raster candidate rejected; keeping active frame")
		return true}
	vm.publish_layer_answers(&output.server.lua)
	layout.publish(&output.ui, nodes)
	if len(output.ui.inspect_events) > 0 ||
	   was_inspecting != layout.inspector_enabled(&output.ui) {dirty(output)}
	vm.publish_ui(&output.server.lua)
	refresh_popups(output)
	clients := 0
	for node in nodes {if node.client.id != 0 {clients += 1}}
	fmt.printf(
		"Layout %s: %dx%d, %d clients, solve %d, size requests %d\n",
		output.handle.name,
		box.width,
		box.height,
		clients,
		output.ui.solves,
		output.configures,
	)
	bytes: u64
	for _, n in output.chrome {bytes += n.bytes}
	if output.paint.trace {fmt.printf("Paint %s: mutations %d, rasters %d, nodes %d, bytes %d, live buffers %d, live bytes %d\n", output.handle.name, output.mutations, output.rasters, len(output.chrome), bytes, sp.live_buffers, sp.live_bytes)}
	fmt.printf(
		"Images: decodes %d, resident %d, keys %d\n",
		output.server.lua.images.decodes,
		output.server.lua.images.bytes,
		len(output.server.lua.images.entries),
	)
	return true
}

// Unrelated clocks and continuously readable pipes must not starve this output.
// Input/client/output facts still resolve through the queue before publication.
pending_layout_facts :: proc(output: ^Output) -> bool {
	for &e in output.server.events {
		if e.class == "spawn" || e.class == "timer" {continue}
		if e.class == "frame" &&
		   (e.output != string(output.handle.name) || !valid_tick(output.server, &e)) {continue}
		return true
	}
	return false
}

// Omission on the old owner can publish before a dirty destination accepts it.
// Retain the focus request until those publications settle, then clear a real omission.
settle_focus_request :: proc(s: ^Server, published: ^Output) {
	for view in s.views {
		if view.id != s.requested_focus ||
		   view.output == nil ||
		   client_visible(view.output, view.id) {continue}
		for other in s.outputs {
			if other != published && other.handle.enabled && other.dirty {return}
		}
		s.requested_focus = 0
		if s.focused == nil {queue_event(s, vm.Event{class = "input", name = "focus"})}
		return
	}
}
