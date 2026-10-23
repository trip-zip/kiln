package compositor

import layout "../layout"
import vm "../lua_runtime"

runtime_inspector :: proc(data: rawptr, name: string, on: i32, width: f64) -> bool {
	s := (^Server)(data)
	if width >= 0 {
		layout.inspector_width = u32(width)
		for o in s.outputs {if layout.inspector_enabled(&o.ui) {dirty(o)}}
	}
	for o in s.outputs {
		if string(o.handle.name) != name {continue}
		if on >= 0 {layout.inspector_set(&o.ui, on != 0)
			dirty(o)}
		return layout.inspector_enabled(&o.ui)
	}
	return false
}
runtime_inspector_scroll :: proc(data: rawptr, name: string, dx, dy: f32) -> f32 {
	s := (^Server)(data)
	for o in s.outputs {
		if string(o.handle.name) == name {
			if locked(s) {return layout.inspector_scroll(&o.ui, 0, 0)}
			value := layout.inspector_scroll(&o.ui, dx, dy)
			if dx != 0 || dy != 0 {dirty(o)}
			return value
		}
	}
	return 0
}
inspector_input :: proc(s: ^Server, e: ^vm.Event) -> bool {
	if e.native != .Motion && e.native != .Button && e.native != .Axis {return false}
	consumed := false
	for o in s.outputs {
		l := &o.ui
		if !o.handle.enabled || !layout.inspector_enabled(l) {continue}
		point := type_of(l.inspect_point){f32(e.px - f64(o.x)), f32(e.py - f64(o.y))}
		if !l.inspect_have || point != l.inspect_point {l.inspect_point = point
			l.inspect_have = true
			dirty(o)}
		panel := layout.inspector_panel(l, point.x, point.y)
		if e.native == .Button && e.button == 1 {
			if e.pressed && panel {l.inspect_capture = true}
			if l.inspect_capture {
				append(&l.inspect_events, layout.Inspector_Pointer{point, e.pressed})
				l.inspect_down = e.pressed
				dirty(o)
				consumed = true
				if !e.pressed {l.inspect_capture = false}
			}
		}
		if panel {
			consumed = true
			if e.native == .Axis {layout.inspector_scroll(l, f32(-e.dx / 5), f32(-e.dy / 5))
				dirty(o)}
		}
	}
	return consumed
}
