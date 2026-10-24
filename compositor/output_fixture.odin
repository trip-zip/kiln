package compositor

import layout "../layout"
import readback "../readback"
import "base:runtime"
_ :: layout
_ :: readback
_ :: runtime
import vm "../lua_runtime"
import sp "../scene_paint"
import wl "../wayland"
import wlr "../wlroots"
_ :: vm
_ :: wl
_ :: sp

when #config(KILN_OUTPUT_FIXTURE, false) {
	fixture_server: ^Server
	fixture_name: cstring
	// Read-only counts let the private harness compare settled live ownership.
	@(export)
	kiln_test_resource :: proc "c" (kind: i32) -> i64 {
		context = runtime.default_context()
		s := fixture_server
		if s == nil {return -1}
		switch kind {
		case 0:
			return i64(len(s.constraint_owners))
		case 1:
			return s.drag_active ? 1 : 0
		case 2:
			n: i64
			for e in s.lua.images.entries {
				if e.supplied {n += 1}
			}
			return n
		case 3:
			return i64(s.lua.images.bytes)
		case 4:
			return i64(len(s.minted_tokens))
		case 5:
			n: i64
			for slot in ([4]rawptr{s.services.notify_slot, s.services.watcher_slot, s.services.owner_slot, s.services.item_slot}) {
				if slot != nil {n += 1}
			}
			for it in s.services.items {
				if it.pending != nil {n += 1}
			}
			return n
		case 6:
			n: i64
			for it in s.services.items {
				if it.pending != nil {n += 1}
			}
			return n
		case 7:
			return i64(len(s.services.items))
		case 8:
			return i64(s.services.bus.dispatches)
		case 9:
			return i64(len(s.lua.images.entries))
		case 10:
			return i64(len(s.timers))
		case 11:
			return i64(len(s.lua.timer_refs))
		case 12:
			return i64(len(s.idle_inhibitors))
		case 13:
			return i64(len(s.lock_surfaces))
		case 14:
			return 1 if s.auth.pid > 0 else 0
		case 15:
			return i64(u32(s.auth.source != nil) + u32(s.auth.timer != nil))
		case 16:
			n: i64
			for o in s.outputs {
				if o.lock_ui != nil {n += i64(o.lock_ui.ui.solves)}
			}
			return n
		case 17:
			return i64(sp.live_buffers)
		case 18:
			return i64(sp.live_bytes)
		case 20:
			return i64(len(s.outputs))
		case 21:
			return i64(len(s.ipc.clients))
		case 23:
			n: i64
			for o in s.outputs {
				if layout.inspector_enabled(&o.ui) {n += 1}
			}
			return n
		case 24:
			n: i64
			for o in s.outputs {n += i64(len(o.ui.inspect_events))}
			return n
		case 25:
			n: i64
			for o in s.outputs {n += i64(len(o.ui.saved.nodes))}
			return n
		case 26:
			return i64(2 * len(s.outputs))
		case 27:
			return i64(len(s.pipes))
		case 28:
			return i64(len(s.events))
		case 29:
			n := i64(len(s.timers))
			for _, p in s.pipes {
				if p.exit_source != nil {n += 1}
				for stream in p.streams {
					if stream.source != nil {n += 1}
				}
			}
			return n
		case 30:
			n: i64
			for o in s.outputs {
				if len(o.paint.swapchain.buffers) > 0 {n += 1}
			}
			return n
		case 22:
			return readback.live_chains + readback.live_states + readback.live_textures
		case 19:
			n: i64
			for i in s.idle_inhibitors {n += i64(u32(i.destroy.link.next != nil) + u32(i.map_.link.next != nil) + u32(i.unmap.link.next != nil))}
			for p in s.lock_surfaces {n += i64(u32(p.destroy.link.next != nil) + u32(p.map_.link.next != nil) + u32(p.unmap.link.next != nil))}
			for l in ([4]^wl.Listener{&s.new_lock, &s.lock_new_surface, &s.lock_unlock, &s.lock_destroy}) {
				if l.link.next != nil {n += 1}
			}
			return n
		}
		return -1
	}
	fixture_attach :: proc(s: rawptr) {fixture_server = (^Server)(s)}
	fixture_name_output :: proc(output: ^wlr.wlr_output) {
		if fixture_name != nil {wlr.wlr_output_set_name(output, fixture_name)}
	}
	Fixture_Backend :: struct {
		headless, x11: ^wlr.wlr_backend,
	}
	fixture_backend :: proc "c" (backend: ^wlr.wlr_backend, data: rawptr) {
		context = runtime.default_context()
		f := (^Fixture_Backend)(data)
		if wlr.wlr_backend_is_headless(backend) {f.headless = backend}
		if wlr.wlr_backend_is_x11(backend) {f.x11 = backend}
	}
	// Only the separately compiled private harness binary exports this entry point.
	@(export)
	kiln_test_output :: proc "c" (action: i32, name: cstring, a, b: i32) -> bool {
		context = runtime.default_context()
		s := fixture_server
		if s == nil {return false}
		if action == 9 {
			queue_event(
				s,
				vm.Event{native = .DeviceMotion, absolute = true, px = f64(a), py = f64(b)},
			)
			return true
		}
		if action == 8 {
			readback.fail_after = a
			return a >= 0 && a <= 4
		}
		if action == 7 {
			// Queue before the caller changes lock ownership in the same IPC turn.
			queue_event(
				s,
				vm.Event{class = "input", name = "key", key = "a", utf8 = "a", pressed = true},
			)
			for v in s.views {queue_event(s, vm.Event{class = "client", name = "request::move", handle = v.id})}
			return true
		}
		if action == 6 {
			if a < 0 || a > 65536 { return false }
			s.gamma.size = u32(a)
			return true
		}
		if action == 2 || action == 3 {
			f: Fixture_Backend
			wlr.wlr_multi_for_each_backend(s.backend, fixture_backend, &f)
			if action == 2 {fixture_name = name}
			defer fixture_name = nil
			if action == 2 && f.headless != nil && a > 0 &&
			   b > 0 {return wlr.wlr_headless_add_output(f.headless, u32(a), u32(b)) != nil}
			if action == 3 && f.x11 != nil {return wlr.wlr_x11_output_create(f.x11) != nil}
			return false
		}
		for o in s.outputs {
			if string(o.handle.name) != string(name) {continue}
			switch action {
			case 0:
				if a < 0 || a > 7 {return false}
				state: wlr.wlr_output_state
				wlr.wlr_output_state_init(&state)
				defer wlr.wlr_output_state_finish(&state)
				wlr.wlr_output_state_set_transform(&state, a)
				return commit_output(o, &state)
			case 1:
				wlr.wlr_output_destroy(o.handle)
				return true
			case 4:
				// Deterministic queued-input race through the real callback;
				// the output/device dies before the idle dispatcher runs.
				found := false
				for p in s.pointers {
					pointer := wlr.wlr_pointer_from_input_device(p.device)
					if pointer_output(s, pointer) != o.lifetime {continue}
					event := wlr.wlr_pointer_motion_absolute_event {
						pointer   = pointer,
						time_msec = 424242,
						x         = .9,
						y         = .9,
					}
					cursor_absolute(&s.cursor_absolute, &event)
					found = true
					break
				}
				if !found {return false}
				wlr.wlr_output_destroy(o.handle)
				return true
			}
		}
		return false
	}
} else {
	fixture_attach :: proc(s: rawptr) {}
	fixture_name_output :: proc(output: ^wlr.wlr_output) {}
}
