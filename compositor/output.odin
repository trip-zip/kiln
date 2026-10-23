package compositor

import layout "../layout"
import vm "../lua_runtime"
import sp "../scene_paint"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"
import "core:fmt"

// Keep the state storage local so every failure releases its C-owned contents.
enable_output :: proc(
	output: ^wlr.wlr_output,
	allocator: ^wlr.wlr_allocator,
	renderer: ^wlr.wlr_renderer,
) -> bool {
	if !wlr.wlr_output_init_render(output, allocator, renderer) {return false}
	state: wlr.wlr_output_state
	wlr.wlr_output_state_init(&state)
	defer wlr.wlr_output_state_finish(&state)
	wlr.wlr_output_state_set_enabled(&state, true)
	if mode := wlr.wlr_output_preferred_mode(output); mode != nil {
		wlr.wlr_output_state_set_mode(&state, mode)
	}
	return wlr.wlr_output_commit_state(output, &state)
}

Output :: struct {
	lock_ui:                               ^Output,
	covered:                               bool,
	present:                               wl.Listener,
	lock_submitted, lock_presented:        bool,
	lock_commit_seq:                       u32,
	server:                                ^Server,
	handle:                                ^wlr.wlr_output,
	frame, request_state, commit, destroy: wl.Listener,
	frames:                                u64,
	tick_on:                               bool,
	tick_last:                             f64,
	tick_generation:                       u64,
	paint:                                 sp.Output,
	x, y:                                  i32,
	ui:                                    layout.Layout,
	chrome:                                map[u64]^sp.Node,
	mutations, rasters:                    u64,
	dirty, arranging:                      bool,
	width, height:                         i32,
	configures:                            u64,
	facts:                                 Output_Facts,
	discovered:                            bool,
	lifetime, notices:                     u64,
}

output_added :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "new_output")
	handle := (^wlr.wlr_output)(data)
	fixture_name_output(handle)
	if !enable_output(handle, s.allocator, s.renderer) {
		fail(s, "Failed to enable output")
		return
	}
	output := new(Output)
	output.server, output.handle = s, handle
	s.next_output += 1
	output.lifetime = s.next_output
	output.chrome = make(map[u64]^sp.Node)
	if !layout.init(&output.ui) {
		layout.destroy(&output.ui)
		clear_chrome(output)
		free(output)
		fail(s, "Failed to create output layout")
		return
	}
	append(&s.outputs, output)
	wl.listen(&handle.events.present, &output.present, lock_presented)
	wl.listen(&handle.events.frame, &output.frame, output_frame)
	wl.listen(&handle.events.request_state, &output.request_state, output_request_state)
	wl.listen(&handle.events.destroy, &output.destroy, output_destroy)
	layout_output := wlr.wlr_output_layout_add_auto(s.layout, handle)
	sp.output_init(&output.paint, s.scene, handle, s.renderer, s.layout)
	if layout_output == nil {
		fail(s, "Failed to add output to scene")
		return
	}
	// Layout and scene must consume the commit before we publish its facts.
	wl.listen(&handle.events.commit, &output.commit, output_committed)
	output.facts = output_facts(output)
	output.discovered = true
	lock_cover(s)
	map_pointers(s)
	drag_position(s)
	queue_output(output, "add")
	dirty(output)
	fmt.printf("Output %s enabled: %dx%d\n", handle.name, handle.width, handle.height)
}

output_frame :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	output := wl.owner(listener, Output, "frame")
	if !output.handle.enabled {return}
	if !wlr.session_active(output.server.session) {output.dirty = true
		return}
	if !arrange(output) {fail(output.server, "Failed to arrange output")
		return}
	scene_output := sp.get_scene_output(output.server.scene, output.handle)
	if locked(output.server) && !output.lock_submitted {sp.output_invalidate(scene_output)}
	if locked(output.server) && !output.lock_submitted {
		output.lock_submitted = true
		output.lock_commit_seq = wlr.lock_next_sequence(output.handle)
	}
	if scene_output == nil || !sp.output_commit(scene_output) {
		output_commit_failed(output)
		return
	}
	queue_tick(output, monotonic())
	// Publication may request a settle while this frame is still pending.
	if output.dirty || output.tick_on {wlr.wlr_output_schedule_frame(output.handle)}
	output.frames += 1
	if output.frames == 1 {fmt.printf("First frame committed on %s\n", output.handle.name)}
}

output_request_state :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	output := wl.owner(listener, Output, "request_state")
	event := (^wlr.wlr_output_event_request_state)(data)
	commit_output(output, event.state)
}

output_destroy :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	output := wl.owner(listener, Output, "destroy")
	queue_output(output, "remove")
	wl.unlisten(&output.present)
	wl.unlisten(&output.commit)
	wl.unlisten(&output.frame)
	wl.unlisten(&output.request_state)
	wl.unlisten(&output.destroy)
	s := output.server
	for other, i in s.outputs {
		if other == output {ordered_remove(&s.outputs, i)
			break}
	}
	remove_layer_output(s, output)
	for view in s.views {
		if view.output == output {
			if s.focused == view {clear_focus(s)}
			foreign_place(view, nil)
			view.output = nil
		}
	}
	pointer_target_refresh(s)
	for other in s.outputs {dirty(other)}
	lock_ui_clear(output)
	lock_cover(s)
	lock_maybe_ack(s)
	idle_recompute(s)
	clear_chrome(output)
	output.chrome = nil
	sp.output_finish(&output.paint)
	if s.lua.current_layout == &output.ui {s.lua.current_layout = nil}
	if s.lua.frame_layout == &output.ui {s.lua.frame_layout = nil}
	layout.destroy(&output.ui)
	free(output)
}

Output_Facts :: struct {
	x, y, width, height, refresh:                              i32,
	scale:                                                     f32,
	enabled:                                                   bool,
	physical_width, physical_height, transform, adaptive_sync: i32,
}
output_facts :: proc(output: ^Output) -> Output_Facts {
	w := output.handle
	box: wlr.wlr_box
	wlr.wlr_output_layout_get_box(output.server.layout, w, &box)
	return {
		box.x,
		box.y,
		box.width,
		box.height,
		w.refresh,
		w.scale,
		w.enabled,
		w.width,
		w.height,
		w.transform,
		w.adaptive_sync_status,
	}
}
update_output_facts :: proc(output: ^Output) {
	if !output.discovered {return}
	facts := output_facts(output)
	if facts != output.facts {
		sp.output_invalidate(sp.get_scene_output(output.server.scene, output.handle))
		if facts.scale != output.facts.scale {cursor_density(output.server)}
		if facts.enabled != output.facts.enabled {
			if !facts.enabled {
				s := output.server
				if s.focused != nil && s.focused.output == output {clear_focus(s)}
				for l in s.layers {
					if l.output == output &&
					   l.handle.surface == s.seat.keyboard_state.focused_surface {clear_focus(s)
						break}
				}
				pointer_target_refresh(s)
			}
		}
		output.facts = facts
		if locked(output.server) {output.lock_submitted = false
			output.lock_presented = false}
		lock_cover(output.server)
		lock_focus(output.server)
		lock_maybe_ack(output.server)
		idle_recompute(output.server)
		output.notices += 1
		queue_output(output, "change")
		dirty(output)
	}
}

commit_output :: proc(
	output: ^Output,
	state: ^wlr.wlr_output_state,
	commit: type_of(wlr.wlr_output_commit_state) = wlr.wlr_output_commit_state,
) -> bool {
	before := output.notices
	if !commit(output.handle, state) {
		fmt.eprintf("Output %s rejected requested state\n", output.handle.name)
		return false
	}
	output_accepted(output, before)
	return true
}
output_accepted :: proc(output: ^Output, before: u64) {
	if output.notices == before {
		output.notices += 1
		queue_output(output, "change")
	}
	dirty(output)
}
runtime_output_set :: proc(data: rawptr, name: string, change: vm.Output_Change) {
	s := (^Server)(data)
	for o in s.outputs {
		if string(o.handle.name) != name {continue}
		if p, ok := change.(vm.Output_Position); ok {
			before := o.notices
			if wlr.wlr_output_layout_add(s.layout, o.handle, p.x, p.y) !=
			   nil {output_accepted(o, before)}
			return
		}
		state: wlr.wlr_output_state
		wlr.wlr_output_state_init(&state)
		defer wlr.wlr_output_state_finish(&state)
		switch c in change {
		case vm.Output_Mode:
			match: ^wlr.wlr_output_mode
			it := wl.iterate(&o.handle.modes)
			for link, ok := wl.next(&it); ok; link, ok = wl.next(&it) {
				m := runtime.container_of(link, wlr.wlr_output_mode, "link")
				if mode_matches(m, c) {match = m
					break}
			}
			if match !=
			   nil {wlr.wlr_output_state_set_mode(&state, match)} else {wlr.wlr_output_state_set_custom_mode(&state, c.width, c.height, c.refresh)}
		case vm.Output_Scale:
			wlr.wlr_output_state_set_scale(&state, c.value)
		case vm.Output_Enabled:
			wlr.wlr_output_state_set_enabled(&state, c.value)
		case vm.Output_Adaptive_Sync:
			wlr.wlr_output_state_set_adaptive_sync_enabled(&state, c.value)
		case vm.Output_Position:
			unreachable()
		}
		accepted := commit_output(o, &state)
		if c, ok := change.(vm.Output_Adaptive_Sync); ok {
			fmt.printf(
				"Adaptive sync %s: requested %v accepted %v enabled %v\n",
				o.handle.name,
				c.value,
				accepted,
				o.handle.adaptive_sync_status == 1,
			)
		}
		return
	}
}
mode_matches :: proc(m: ^wlr.wlr_output_mode, wanted: vm.Output_Mode) -> bool {
	return(
		m.width == wanted.width &&
		m.height == wanted.height &&
		(wanted.refresh == 0 || m.refresh == wanted.refresh) \
	)
}
output_committed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	update_output_facts(wl.owner(listener, Output, "commit"))
}
output_layout_changed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "layout_change")
	for output in s.outputs {update_output_facts(output)}
}

output_commit_failed :: proc(output: ^Output) {
	if !wlr.session_active(output.server.session) {output.dirty = true
		return}
	fail(output.server, "Failed to commit output frame")
}
