package compositor

import "core:fmt"
import sp "../scene_paint"
import layout "../layout"
import vm "../lua_runtime"
import wlr "../wlroots"


dirty :: proc(output: ^Output) {
	if output == nil { return }
	output.dirty = true
	if output.handle.enabled { wlr.wlr_output_schedule_frame(output.handle) }
}

// Compare against our last request, never against the client's committed size.
request_size :: proc(view: ^View, width, height: i32) -> bool {
	if view.requested_width == width && view.requested_height == height { return false }
	view.requested_width, view.requested_height = width, height
	return true
}

reconcile :: proc(output: ^Output, original: []layout.Command) -> bool {
	ordered:=make([dynamic]layout.Command)
    defer delete(ordered)
    for promote in 0..<2 {
        for cmd in original {
            owns:=false
            if leaf,ok:=cmd.content.(layout.Client);ok && output.server!=nil { owns=has_popup(output.server,leaf.id) }
            if owns==(promote==1) { append(&ordered,cmd) }
        }
    }
    commands:=ordered[:]
    output.mutations, output.rasters = 0, 0
	before := sp.created_buffers
	defer output.rasters = sp.created_buffers-before
	prepared := make(map[u64]^sp.Node)
	defer delete(prepared)
	wanted := make(map[u64]bool)
	defer delete(wanted)
	clients := make(map[u32]bool)
	defer delete(clients)
	scratch: ^wlr.wlr_scene_tree
	defer { if scratch != nil { wlr.wlr_scene_node_destroy(&scratch.node) } }
	defer { for _, n in prepared { sp.destroy(n) } }
	fonts := output.ui.fonts
	if fonts == nil { fonts = &output.ui.fallback_fonts }
	for command in commands {
		if client, ok := command.content.(layout.Client); ok {
            if output.server!=nil { for v in output.server.views {
                if v.id!=client.id || x11(v)==nil || view_override_redirect(v) { continue }
                x,y:=f64(command.box.x)+f64(output.tree.node.x),f64(command.box.y)+f64(output.tree.node.y)
                if x< -32768 || x>32767 || y< -32768 || y>32767 || command.box.width>65535 || command.box.height>65535 {
                    fmt.eprintln("X11 geometry exceeds signed-16 coordinates or unsigned-16 dimensions; keeping published frame")
                    return false
                }
            } }
            clients[client.id] = true; continue
        }
		key := sp.key(command)
		wanted[key] = true
		old := output.chrome[key]
		if old != nil && (sp.reusable(old,command,layout.density(&output.ui)) || (sp.square(old.command) && sp.square(command))) { continue }
		if scratch == nil {
			scratch = wlr.wlr_scene_tree_create(output.tree)
			if scratch == nil { return false }
			wlr.wlr_scene_node_set_enabled(&scratch.node,false)
		}
		n, ok := sp.create(scratch,command,fonts,layout.density(&output.ui))
		if !ok { return false }
		prepared[key] = n
	}
	// No fallible operation remains. Borrowed trees are resolved only from live views.
	for key, n in prepared {
		if old := output.chrome[key]; old != nil { sp.destroy(old); output.mutations += 1 }
		wlr.wlr_scene_node_reparent(n.root,output.tree)
		output.mutations += 1
		output.chrome[key] = n
	}
	clear(&prepared)
	stale := make([dynamic]u64)
	defer delete(stale)
	for key,n in output.chrome { if !wanted[key] { sp.destroy(n); append(&stale,key); output.mutations += 1 } }
	for key in stale { delete_key(&output.chrome,key) }
	if output.server != nil {
		for l in output.server.layers {
			if l.output==output && !clients[l.id] && l.tree.node.enabled {
				wlr.wlr_scene_node_set_enabled(&l.tree.node,false);output.mutations+=1
			}
		}
		for view in output.server.views {
			if view.output == output && !clients[view.id] && view.tree.node.enabled {
				wlr.wlr_scene_node_set_enabled(&view.tree.node,false)
				output.mutations += 1
			}
		}
	}
	previous: ^wlr.wlr_scene_node
	for command in commands {
		node: ^wlr.wlr_scene_node
        placed_view: ^View
		if content, client := command.content.(layout.Client); client {
			view: ^View
			if output.server != nil { for live in output.server.views { if live.id == content.id && live.mapped { view = live; break } } }
			if view == nil {
                l:=find_layer(output.server,content.id)
                if l==nil || !l.mapped { continue }
                if l.output!=output {
                    if l.output!=nil { layout.forget_client(&l.output.ui,l.id) }
                    l.output=output
                    if !l.explicit_output { l.handle.output=output.handle }
                    wlr.wlr_scene_node_reparent(&l.tree.node,output.tree);output.mutations+=1
                }
                node=&l.tree.node
                if !node.enabled { wlr.wlr_scene_node_set_enabled(node,true);output.mutations+=1 }
            } else {
			if view.output != output {
				if view.output != nil { layout.forget_client(&view.output.ui,view.id) }
				view.output = output
				foreign_place(view,output)
				wlr.wlr_scene_node_reparent(&view.tree.node,output.tree)
				output.mutations += 1
			}
			node = &view.tree.node
            placed_view=view
			if !node.enabled { wlr.wlr_scene_node_set_enabled(node,true); output.mutations += 1 }
			}
		} else {
			n := output.chrome[sp.key(command)]
			node = n.root
			output.mutations += sp.update(n,command)
		}
		x,y := i32(command.box.x),i32(command.box.y)
		if node.x != x || node.y != y { wlr.wlr_scene_node_set_position(node,x,y); output.mutations += 1 }
		if placed_view!=nil { publish_view_size(placed_view,max(1,i32(command.box.width)),max(1,i32(command.box.height))) }
		if previous == nil {
			if node.link.prev != &output.tree.children { wlr.wlr_scene_node_lower_to_bottom(node); output.mutations += 1 }
		} else if node.link.prev != &previous.link {
			wlr.wlr_scene_node_place_above(node,previous)
			output.mutations += 1
		}
		previous = node
	}
	if s := output.server; s != nil {
		settle_focus_request(s,output)
        if l:=find_layer(s,s.requested_focus);l!=nil && l.mapped && l.output==output {
            if l.tree.node.enabled { enter_surface(s,l.handle.surface) }
            else { s.requested_focus=0;clear_focus(s) }
        }
		if s.focused != nil && !s.focused.tree.node.enabled {
			clear_focus(s)
		}
		for view in s.views {
			if view.id == s.requested_focus && view.mapped && view.output == output && view.tree.node.enabled && (s.focused != view || (!s.keyboard_grabbed && runtime_focused(s)!=view.id)) { focus(view) }
		}
	}
	idle_recompute(output.server)
	pointer_target_refresh(output.server)
	return true
}

clear_chrome :: proc(output: ^Output) {
	for _,n in output.chrome { sp.destroy(n) }
	delete(output.chrome)
}

arrange :: proc(output: ^Output) -> bool {
	if locked(output.server) { return arrange_lock(output) }
    if output.arranging { return true }
	if pending_layout_facts(output) {
		dirty(output)
		return true
	}
	box: wlr.wlr_box
	wlr.wlr_output_layout_get_box(output.server.layout, output.handle, &box)
	if output.tree.node.x != box.x || output.tree.node.y != box.y {
        wlr.wlr_scene_node_set_position(&output.tree.node, box.x, box.y)
        // Output placement is already committed even if a new declaration fails.
        for v in output.server.views {
            if x11(v)!=nil && v.output==output && v.mapped && v.requested_width>0 && v.requested_height>0 {
                publish_view_size(v,v.requested_width,v.requested_height)
            }
        }
    }
	if box.width != output.width || box.height != output.height { output.dirty = true }
	if !output.dirty { return true }
	output.width, output.height = box.width, box.height
	output.dirty = false
	output.arranging = true
	defer output.arranging = false
	output.ui.scale=output.handle.scale
	nodes, valid := vm.declare(&output.server.lua, &output.ui, string(output.handle.name), box.width, box.height)
	if !valid { return true }
	was_inspecting:=layout.inspector_enabled(&output.ui)
	commands, ok := layout.prepare(&output.ui, box.width, box.height, nodes)
	if !ok { return true }
	if !reconcile(output, commands) { layout.rollback(&output.ui);fmt.eprintln("Raster candidate rejected; keeping active frame"); return true }
	vm.publish_layer_answers(&output.server.lua)
	layout.publish(&output.ui,nodes)
    if len(output.ui.inspect_events)>0 || was_inspecting!=layout.inspector_enabled(&output.ui) { dirty(output) }
	vm.publish_ui(&output.server.lua)
	refresh_popups(output)
	clients := 0
	for node in nodes { if node.client.id != 0 { clients += 1 } }
	fmt.printf("Layout %s: %dx%d, %d clients, solve %d, size requests %d\n",
		output.handle.name, box.width, box.height, clients, output.ui.solves, output.configures)
	bytes: u64
	for _,n in output.chrome { bytes += n.bytes }
	fmt.printf("Paint %s: mutations %d, rasters %d, nodes %d, bytes %d, live buffers %d, live bytes %d\n",
		output.handle.name,output.mutations,output.rasters,len(output.chrome),bytes,sp.live_buffers,sp.live_bytes)
	fmt.printf("Images: decodes %d, resident %d, keys %d\n",output.server.lua.images.decodes,output.server.lua.images.bytes,len(output.server.lua.images.entries))
	return true
}

// Unrelated clocks and continuously readable pipes must not starve this output.
// Input/client/output facts still resolve through the queue before publication.
pending_layout_facts :: proc(output: ^Output) -> bool {
	for &e in output.server.events {
		if e.class=="spawn" || e.class=="timer" { continue }
		if e.class=="frame" && (e.output!=string(output.handle.name) || !valid_tick(output.server,&e)) { continue }
		return true
	}
	return false
}

// Omission on the old owner can publish before a dirty destination accepts it.
// Retain the focus request until those publications settle, then clear a real omission.
settle_focus_request :: proc(s: ^Server, published: ^Output) {
	for view in s.views {
		if view.id!=s.requested_focus || view.output==nil || view.tree.node.enabled { continue }
		for other in s.outputs {
			if other!=published && other.handle.enabled && other.dirty { return }
		}
		s.requested_focus=0
		if s.focused==nil { queue_event(s,vm.Event{class="input",name="focus"}) }
		return
	}
}
