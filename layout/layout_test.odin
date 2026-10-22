package layout

import "core:testing"
import "core:strings"
import paint "../paint"
import clay "../clay"

@(test)
negative_float_uses_current_parent_geometry :: proc(t: ^testing.T) {
	l: Layout
	testing.expect(t,init(&l))
	defer destroy(&l)
	nodes := [?]Node{
		{name="root",named=true,end=4,declaration={layout={
			sizing={clay.SizingGrow(),clay.SizingGrow()},layoutDirection=.TopToBottom,padding=clay.PaddingAll(5)}}},
		{end=2,declaration={layout={sizing={clay.SizingGrow(),clay.SizingGrow()}}}},
		{end=4,declaration={layout={sizing={clay.SizingGrow(),clay.SizingFixed(20)}}}},
		{name="core.surface",index=7,named=true,end=4,client={7},declaration={
			layout={sizing={clay.SizingFixed(100),clay.SizingFixed(20)}},
			floating={attachTo=.Parent,zIndex=-998,attachment={.CenterBottom,.CenterBottom}}}},
	}
	for dimensions in ([?][2]i32{{200,150},{300,180},{200,150}}) {
		commands,ok:=solve(&l,dimensions[0],dimensions[1],nodes[:])
		testing.expect(t,ok)
		testing.expect_value(t,len(commands),1)
		expected:=Box{f32(dimensions[0]-100)/2,f32(dimensions[1]-25),100,20}
		testing.expect_value(t,commands[0].box,expected)
		b,found:=box(&l,"core.surface",7)
		testing.expect(t,found)
		testing.expect_value(t,b,expected)
		testing.expect_value(t,hit(&l,b.x+10,b.y+10).id,7)
	}
}

@(test)
cells_resize_and_hit_test :: proc(t: ^testing.T) {
	l: Layout
	testing.expect(t, init(&l))
	defer destroy(&l)
	clients := [?]Client{{1}, {2}}
	commands, ok := solve_fixture(&l, 1280, 720, clients[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(commands), 4)
	testing.expect_value(t, commands[2].box, Box{16, 52, 616, 652})
	testing.expect_value(t, commands[3].box, Box{648, 52, 616, 652})
	testing.expect(t, hit(&l, 100, 100).id == 1)
	testing.expect(t, hit(&l, 1000, 100).id == 2)
	testing.expect(t, hit(&l, 640, 100).id == 0)
	testing.expect(t, hit(&l, 100, 20).id == 0)
	testing.expect(t, hit(&l, -1, 100).id == 0)
	id := commands[2].id
	commands, ok = solve_fixture(&l, 1000, 600, clients[:1])
	testing.expect(t, ok)
	testing.expect_value(t, commands[2].id, id)
	testing.expect_value(t, commands[2].box, Box{16, 52, 968, 532})
	testing.expect(t, hit(&l, 900, 100).id == 1)
	commands, ok = solve_fixture(&l, 1000, 600, nil)
	testing.expect(t, ok)
	testing.expect_value(t, len(commands), 2)
	testing.expect(t, hit(&l, 100, 100).id == 0)
}

@(test)
contexts_keep_independent_trees :: proc(t: ^testing.T) {
	a, b: Layout
	testing.expect(t, init(&a))
	defer destroy(&a)
	testing.expect(t, init(&b))
	defer destroy(&b)
	first := [?]Client{{1}}
	second := [?]Client{{2}}
	_, ok := solve_fixture(&a, 800, 600, first[:])
	testing.expect(t, ok)
	_, ok = solve_fixture(&b, 1200, 900, second[:])
	testing.expect(t, ok)
	testing.expect(t, hit(&a, 100, 100).id == 1)
	testing.expect(t, hit(&b, 100, 100).id == 2)
	testing.expect_value(t, hit(&a, 900, 100).id, 0)
	testing.expect_value(t, hit(&b, 900, 100).id, 2)
	abox, aok := box(&a, "core.surface", 1)
	bbox, bok := box(&b, "core.surface", 2)
	testing.expect(t, aok && bok)
	testing.expect_value(t, abox, Box{16,52,768,532})
	testing.expect_value(t, bbox, Box{16,52,1168,832})
}

solve_fixture :: proc(l: ^Layout, width, height: i32, clients: []Client) -> ([]Command, bool) {
	nodes := make([dynamic]Node)
	defer delete(nodes)
	append(&nodes, Node{name="screen", named=true, end=3+len(clients), declaration={
		layout={sizing={clay.SizingGrow(),clay.SizingGrow()},layoutDirection=.TopToBottom},
		backgroundColor={24,28,36,255}}})
	append(&nodes, Node{name="strip", named=true, end=2, declaration={
		layout={sizing={clay.SizingGrow(),clay.SizingFixed(36)}},backgroundColor={55,131,151,255}}})
	append(&nodes, Node{name="clients", named=true, end=3+len(clients), declaration={
		layout={sizing={clay.SizingGrow(),clay.SizingGrow()},padding=clay.PaddingAll(16),childGap=16}}})
	for client, i in clients {
		append(&nodes, Node{name="core.surface", index=client.id, named=true, end=4+i, client=client,
			declaration={layout={sizing={clay.SizingGrow(),clay.SizingGrow()}}}})
	}
	return solve(l,width,height,nodes[:])
}

@(test)
failed_clay_solve_keeps_the_active_tree :: proc(t: ^testing.T) {
    for persistent in ([2]bool{false,true}) {
	l: Layout
	testing.expect(t, init(&l))
	defer destroy(&l)
	if persistent { inspector_set(&l,true) }
	clients := [?]Client{{7}}
	commands, ok := solve_fixture(&l, 800, 600, clients[:])
	testing.expect(t, ok)
	previous := commands[2]
	broken := [?]Node{
		{name="duplicate", named=true, end=1, declaration={layout={sizing={clay.SizingFixed(20),clay.SizingFixed(20)}}}},
		{name="duplicate", named=true, end=2, declaration={layout={sizing={clay.SizingFixed(20),clay.SizingFixed(20)}}}},
	}
	_, ok = solve(&l, 800, 600, broken[:])
	testing.expect(t, !ok)
	testing.expect_value(t, l.solves, 1)
	testing.expect_value(t, l.commands[2], previous)
	testing.expect_value(t, hit(&l, 100, 100).id, 7)
	_, found := box(&l, "duplicate", 0)
	testing.expect(t, !found)
	_, ok = solve_fixture(&l, 800, 600, clients[:])
	testing.expect(t, ok)
	testing.expect_value(t, l.solves, 2)
	forget_client(&l, 7)
	testing.expect_value(t, hit(&l, 100, 100).id, 0)
	h := hits(&l, 100, 100)
	defer delete(h)
	for value in h { testing.expect(t, value.name != "core.surface") }
	_, found = box(&l, "core.surface", 7)
	testing.expect(t, found)
    }
}

@(test)
density_changes_reset_both_public_measurement_caches :: proc(t: ^testing.T) {
    l:Layout
    testing.expect(t,init(&l))
    defer destroy(&l)
    f:Frame
    defer destroy_frame(&f)
    append(&f.nodes,Node{text=strings.clone("Handgloves WWW iii"),is_text=true,text_config={fontSize=17},end=1})
    for scale in ([6]f32{1,1,1.5,1.5,2,2}) {
        l.scale=scale
        commands,ok:=prepare(&l,500,200,f.nodes[:])
        testing.expect(t,ok)
        expected_w,expected_h:=paint.measure(&l.measurer,&l.fallback_fonts,"Handgloves WWW iii",0,17,scale)
        found:=false
        for cmd in commands {
            if _,text:=cmd.content.(Text);text {
                found=true
                testing.expect_value(t,cmd.box.width,expected_w)
                testing.expect_value(t,cmd.box.height,expected_h)
            }
        }
        testing.expect(t,found)
        publish(&l,f.nodes[:])
        testing.expect_value(t,l.cache_scale[l.active],scale)
    }
}
