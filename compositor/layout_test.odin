package compositor

import "core:testing"
import clay "deps:clay"
import sp "../scene_paint"
import layout "../layout"
import vm "../lua_runtime"
import wlr "../wlroots"

@(test)
reconcile_retains_and_removes_rectangles :: proc(t: ^testing.T) {
	scene := wlr.wlr_scene_create()
	testing.expect(t, scene != nil)
	defer wlr.wlr_scene_node_destroy(&scene.tree.node)
	output := Output{tree = &scene.tree, chrome = make(map[u64]^sp.Node)}
	defer clear_chrome(&output)
	l: layout.Layout
	testing.expect(t, layout.init(&l))
	defer layout.destroy(&l)
	r: vm.Runtime
	testing.expect(t, vm.init(&r))
	defer vm.destroy(&r)
	output.ui.fonts = &r.fonts
	reply := vm.evaluate(&r, `package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
core.output.list = function() return {{name="TEST",width=1280,height=720}} end
` + #load("../scripts/fixtures/strip.lua"))
	defer delete(reply)
	testing.expect_value(t, reply, "\n")
	nodes, valid := vm.declare(&r, &l, "TEST", 1280, 720)
	testing.expect(t, valid)
	commands, ok := layout.solve(&l, 1280, 720, nodes)
	testing.expect(t, ok && reconcile(&output, commands))
	background := output.chrome[sp.key(commands[0])].root
	strip := output.chrome[sp.key(commands[1])].root
	testing.expect(t, reconcile(&output, commands))
	testing.expect(t, output.chrome[sp.key(commands[0])].root == background)
	testing.expect(t, output.chrome[sp.key(commands[1])].root == strip)
	nodes, valid = vm.declare(&r, &l, "TEST", 1000, 600)
	testing.expect(t, valid)
	commands, ok = layout.solve(&l, 1000, 600, nodes)
	testing.expect(t, ok && reconcile(&output, commands))
	testing.expect(t, output.chrome[sp.key(commands[0])].root == background)
	testing.expect(t, output.chrome[sp.key(commands[1])].root == strip)
	testing.expect(t, reconcile(&output, commands[:1]))
	testing.expect_value(t, len(output.chrome), 1)
	testing.expect(t, reconcile(&output, nil))
	testing.expect_value(t, len(output.chrome), 0)
}

@(test)
reconcile_keeps_borrowed_client_tree :: proc(t: ^testing.T) {
	scene := wlr.wlr_scene_create()
	testing.expect(t, scene != nil)
	defer wlr.wlr_scene_node_destroy(&scene.tree.node)
	output := Output{tree = &scene.tree, chrome = make(map[u64]^sp.Node)}
	defer clear_chrome(&output)
	tree := wlr.wlr_scene_tree_create(&scene.tree)
	testing.expect(t, tree != nil)
	s: Server
	defer delete(s.views)
	output.server = &s
	view := View{id = 1, mapped = true, output = &output, tree = tree, requested_width = 616, requested_height = 652}
	append(&s.views, &view)
	commands := [?]layout.Command{{1, {16, 52, 616, 652}, layout.Client{1}, {}}}
	testing.expect(t, reconcile(&output, commands[:]))
	testing.expect(t, reconcile(&output, commands[:]))
	testing.expect(t, view.tree == tree)
	x, y: i32
	testing.expect(t, wlr.wlr_scene_node_coords(&tree.node, &x, &y))
	testing.expect_value(t, x, 16)
	testing.expect_value(t, y, 52)
	testing.expect_value(t, output.configures, 0)
	commands[0].box.x = 648
	testing.expect(t, reconcile(&output, commands[:]))
	testing.expect(t, view.tree == tree)
	testing.expect(t, wlr.wlr_scene_node_coords(&tree.node, &x, &y))
	testing.expect_value(t, x, 648)
	testing.expect(t, reconcile(&output, nil))
	testing.expect(t, !wlr.wlr_scene_node_coords(&tree.node, &x, &y))
	testing.expect(t, view.tree == tree)
	testing.expect(t, reconcile(&output, commands[:]))
	testing.expect(t, wlr.wlr_scene_node_coords(&tree.node, &x, &y))
}

@(test)
client_commits_do_not_dirty_or_repeat_size_requests :: proc(t: ^testing.T) {
	output: Output
	base: wlr.wlr_xdg_surface
	toplevel := wlr.wlr_xdg_toplevel{base = &base}
	view := View{output = &output, protocol=&toplevel}
	testing.expect(t, request_size(&view, 616, 652))
	for _ in 0..<10 { view_commit(&view.commit, nil) }
	testing.expect(t, !output.dirty)
	testing.expect(t, !request_size(&view, 616, 652))
	testing.expect(t, request_size(&view, 968, 532))
	testing.expect(t, !request_size(&view, 968, 532))
}

@(test)
raster_candidates_are_atomic_and_unchanged_frames_do_nothing :: proc(t: ^testing.T) {
	before,bytes := sp.live_buffers,sp.live_bytes
	scene := wlr.wlr_scene_create()
	defer wlr.wlr_scene_node_destroy(&scene.tree.node)
	output := Output{tree=&scene.tree,chrome=make(map[u64]^sp.Node)}
	defer clear_chrome(&output)
	testing.expect(t,layout.init(&output.ui))
	defer layout.destroy(&output.ui)
	r: vm.Runtime
	testing.expect(t,vm.init(&r))
	defer vm.destroy(&r)
	good :: `core.set_frame_handler(function()
 core.open({id='root',layout={sizing={width=300,height=80}}})
 core.open({id='fit'});core.text('Owned text 123', {fontSize=18,textColor={r=255,g=255,b=255}});core.close()
 core.open({id='sibling',layout={sizing={width=40,height=40}},backgroundColor={g=255},cornerRadius={topLeft=12}});core.close()
 core.close();collectgarbage('collect')
end)`
	delete(vm.evaluate(&r,good))
	nodes,ok := vm.declare(&r,&output.ui,"TEST",800,600)
	testing.expect(t,ok)
	commands,solved := layout.prepare(&output.ui,800,600,nodes)
	testing.expect(t,solved && reconcile(&output,commands))
	layout.publish(&output.ui,nodes)
	b,_ := layout.box(&output.ui,"fit",0)
	count := sp.live_buffers
	for _ in 0..<6 {
		nodes,ok = vm.declare(&r,&output.ui,"TEST",800,600)
		commands,solved = layout.prepare(&output.ui,800,600,nodes)
		testing.expect(t,ok && solved && reconcile(&output,commands))
		layout.publish(&output.ui,nodes)
		testing.expect_value(t,output.mutations,0)
		testing.expect_value(t,output.rasters,0)
		testing.expect_value(t,sp.live_buffers,count)
	}
	delete(vm.evaluate(&r,`core.set_frame_handler(function()
core.open({id='fit'});core.text('invalidated?');collectgarbage('collect');error('after text') end)`))
	_,ok = vm.declare(&r,&output.ui,"TEST",800,600)
	testing.expect(t,!ok)
	actual,_ := layout.box(&output.ui,"fit",0)
	testing.expect_value(t,actual,b)
	testing.expect(t,reconcile(&output,output.ui.commands[:]))
	testing.expect_value(t,output.mutations,0)
	delete(vm.evaluate(&r,`core.set_frame_handler(function()
core.open({id='fit'});core.text('prepared first',{textColor={r=255},fontSize=30});core.close()
core.open({id='huge',layout={sizing={width=100000,height=100000}},backgroundColor={r=255},cornerRadius={topLeft=10}});core.close()
end)`))
	nodes,ok = vm.declare(&r,&output.ui,"TEST",800,600)
	commands,solved = layout.prepare(&output.ui,800,600,nodes)
	testing.expect(t,ok && solved)
	testing.expect(t,!reconcile(&output,commands))
	testing.expect_value(t,sp.live_buffers,count)
	testing.expect_value(t,output.mutations,0)
	actual,_ = layout.box(&output.ui,"fit",0)
	testing.expect_value(t,actual,b)
	hits := layout.hits(&output.ui,1,1)
	testing.expect(t,len(hits)>0)
	delete(hits)
	delete(vm.evaluate(&r,good))
	nodes,ok = vm.declare(&r,&output.ui,"TEST",800,600)
	commands,solved = layout.prepare(&output.ui,800,600,nodes)
	testing.expect(t,ok && solved && reconcile(&output,commands))
	layout.publish(&output.ui,nodes)
	testing.expect_value(t,output.rasters,0)
	testing.expect_value(t,output.mutations,0)
	testing.expect(t,reconcile(&output,nil))
	testing.expect_value(t,sp.live_buffers,before)
	testing.expect_value(t,sp.live_bytes,bytes)
}

@(test)
rounded_border_native_picking_matches_client_holes :: proc(t: ^testing.T) {
 scene := wlr.wlr_scene_create()
 defer wlr.wlr_scene_node_destroy(&scene.tree.node)
 output := Output{tree=&scene.tree,chrome=make(map[u64]^sp.Node)}
 defer clear_chrome(&output)
 testing.expect(t,layout.init(&output.ui))
 defer layout.destroy(&output.ui)
 s: Server
 defer delete(s.views)
 output.server = &s
 tree := wlr.wlr_scene_tree_create(&scene.tree)
 color := [4]f32{0,0,0,1}
 surface := wlr.wlr_scene_rect_create(tree,40,40,raw_data(color[:]))
 view := View{id=1,mapped=true,output=&output,tree=tree,requested_width=40,requested_height=40}
 append(&s.views,&view)
 nodes := [?]layout.Node{
  {name="ring",named=true,end=2,declaration={
   layout={sizing={clay.SizingFixed(40),clay.SizingFixed(40)}},
   cornerRadius={20,20,20,20},border={color={255,255,255,255},width={left=3,right=3,top=3,bottom=3}}}},
  {name="core.surface",index=1,named=true,end=2,client={1},declaration={
   layout={sizing={clay.SizingGrow(),clay.SizingGrow()}}}},
 }
 commands,ok := layout.solve(&output.ui,40,40,nodes[:])
 testing.expect(t,ok && reconcile(&output,commands))
 x,y: f64
 for point in ([][2]f64{{2,2},{20,8},{20,20}}) {
  testing.expect(t,wlr.wlr_scene_node_at(&scene.tree.node,point[0],point[1],&x,&y)==&surface.node)
  testing.expect_value(t,layout.hit(&output.ui,f32(point[0]),f32(point[1])).id,1)
 }
 // Clay includes the rectangular client cell even where opaque border pixels paint above it.
 testing.expect(t,wlr.wlr_scene_node_at(&scene.tree.node,20,1,&x,&y)!=&surface.node)
 testing.expect_value(t,layout.hit(&output.ui,20,1).id,1)
 testing.expect(t,reconcile(&output,commands))
 testing.expect_value(t,output.mutations,0)
 testing.expect_value(t,output.rasters,0)
}

@(test)
command_kinds_and_square_round_transitions_preserve_order :: proc(t: ^testing.T) {
 scene := wlr.wlr_scene_create()
 defer wlr.wlr_scene_node_destroy(&scene.tree.node)
 output := Output{tree=&scene.tree,chrome=make(map[u64]^sp.Node)}
 defer clear_chrome(&output)
 commands := [?]layout.Command{
  {7,{0,0,40,40},layout.Rectangle{{1,0,0,1},{}},{}},
  {7,{0,0,40,40},layout.Border{{0,1,0,1},{},{3,3,3,3}},{}},
  {8,{50,0,40,40},layout.Rectangle{{0,0,1,1},{}},{}},
 }
 testing.expect(t,sp.key(commands[0])!=sp.key(commands[1]))
 testing.expect(t,reconcile(&output,commands[:]))
 sibling := output.chrome[sp.key(commands[2])].root
 for rounded in ([]bool{true,false,true,false}) {
  radius: f32
  if rounded { radius=20 }
  commands[0].content = layout.Rectangle{{1,0,0,1},{radius,radius,radius,radius}}
  testing.expect(t,reconcile(&output,commands[:]))
  testing.expect_value(t,len(output.chrome),3)
  testing.expect(t,output.chrome[sp.key(commands[2])].root==sibling)
  previous := &scene.tree.children
  for c in commands {
   node := output.chrome[sp.key(c)].root
   testing.expect(t,node.link.prev==previous)
   previous = &node.link
  }
  testing.expect(t,reconcile(&output,commands[:]))
  testing.expect_value(t,output.mutations,0)
  testing.expect_value(t,output.rasters,0)
 }
}
