package compositor

import gles "../gles"
import out "../outputs"
import layout "../layout"
import vm "../lua_runtime"
import sp "../scene_paint"
import "core:fmt"

lock_ui_clear :: proc(o: ^Output) {
	ui := o.lock_ui
	if ui == nil {return}
	r := &o.server.lua
	if r.current_layout == &ui.ui {r.current_layout = nil}
	if r.frame_layout == &ui.ui {r.frame_layout = nil}
	clear_chrome(ui)
	layout.destroy(&ui.ui)
	sp.publish(&o.paint, nil)
	sp.output_finish(&ui.paint)
	free(ui)
	o.lock_ui = nil
}
arrange_lock :: proc(o: ^Output) -> bool {
	s := o.server
	lock_cover(s)
	if s.lock_owner != .Native {o.dirty = false
		return true}
	if !o.dirty || o.arranging {return true}
	o.dirty = false
	o.arranging = true
	defer o.arranging = false
	if o.lock_ui == nil {
		ui := new(Output)
		ui.chrome = make(map[u64]^sp.Node)
		if !layout.init(&ui.ui) {
			layout.destroy(&ui.ui)
			clear_chrome(ui)
			free(ui)
			return true
		}
		o.lock_ui = ui
	}
	ui := o.lock_ui
	b: gles.Box
	b = out.layout_box(s.layout, o.handle)
	ui.x, ui.y = b.x, b.y
	ui.ui.scale = o.handle.scale
	width, height := out.cover_size(o.handle)
	nodes, valid := vm.declare(&s.lua, &ui.ui, string(o.handle.name), width, height, true)
	if !valid {return true}
	commands, ok := layout.prepare(&ui.ui, width, height, nodes)
	if !ok || !reconcile(ui, commands) {return true}
	sp.publish(&o.paint, ui.paint.parts[:])
	layout.publish(&ui.ui, nodes)
	fmt.printf(
		"Lock layout %s: solve %d, nodes %d, rasters %d\n",
		o.handle.name,
		ui.ui.solves,
		len(ui.chrome),
		ui.rasters,
	)
	return true
}
