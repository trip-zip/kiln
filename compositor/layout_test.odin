package compositor

import sf "../surfaces"

import sh "../shells"

import clay "../clay"
import layout "../layout"
import vm "../lua_runtime"
import sp "../scene_paint"
import "core:testing"

@(test)
reconcile_retains_and_removes_rectangles :: proc(t: ^testing.T) {

	output := Output {
		chrome = make(map[u64]^sp.Node),
	}
	defer {clear_chrome(&output)
		sp.output_finish(&output.paint)}
	l: layout.Layout
	testing.expect(t, layout.init(&l))
	defer layout.destroy(&l)
	r: vm.Runtime
	testing.expect(t, vm.init(&r))
	defer vm.destroy(&r)
	output.ui.fonts = &r.fonts
	reply := vm.evaluate(
		&r,
		`package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
core.output.list = function() return {{name="TEST",width=1280,height=720}} end
` +
		#load("fixtures/strip.lua"),
	)
	defer delete(reply)
	testing.expect_value(t, reply, "\n")
	nodes, valid := vm.declare(&r, &l, "TEST", 1280, 720)
	testing.expect(t, valid)
	commands, ok := layout.solve(&l, 1280, 720, nodes)
	testing.expect(t, ok && reconcile(&output, commands))
	background := output.chrome[sp.key(commands[0])]
	strip := output.chrome[sp.key(commands[1])]
	testing.expect(t, reconcile(&output, commands))
	testing.expect(t, output.chrome[sp.key(commands[0])] == background)
	testing.expect(t, output.chrome[sp.key(commands[1])] == strip)
	nodes, valid = vm.declare(&r, &l, "TEST", 1000, 600)
	testing.expect(t, valid)
	commands, ok = layout.solve(&l, 1000, 600, nodes)
	testing.expect(t, ok && reconcile(&output, commands))
	testing.expect(t, output.chrome[sp.key(commands[0])] == background)
	testing.expect(t, output.chrome[sp.key(commands[1])] == strip)
	testing.expect(t, reconcile(&output, commands[:1]))
	testing.expect_value(t, len(output.chrome), 1)
	testing.expect(t, reconcile(&output, nil))
	testing.expect_value(t, len(output.chrome), 0)
}

@(test)
reconcile_keeps_borrowed_client_identity :: proc(t: ^testing.T) {

	output := Output {
		chrome = make(map[u64]^sp.Node),
	}
	defer {clear_chrome(&output)
		sp.output_finish(&output.paint)}
	surface: sf.Surface
	top := sh.Toplevel {
		surface = &surface,
	}
	s: Server
	defer delete(s.views)
	output.server = &s
	view := View {
		id               = 1,
		mapped           = true,
		output           = &output,
		protocol         = &top,
		requested_width  = 616,
		requested_height = 652,
	}
	append(&s.views, &view)
	commands := [?]layout.Command{{1, {16, 52, 616, 652}, layout.Client{1}, {}}}
	testing.expect(t, reconcile(&output, commands[:]))
	testing.expect(t, reconcile(&output, commands[:]))
	testing.expect(t, view_surface(&view) == &surface)
	x, y: i32
	testing.expect(t, view_position(&view, &x, &y))
	testing.expect_value(t, x, 16)
	testing.expect_value(t, y, 52)
	testing.expect_value(t, output.configures, 0)
	commands[0].box.x = 648
	testing.expect(t, reconcile(&output, commands[:]))
	testing.expect(t, view_surface(&view) == &surface)
	testing.expect(t, view_position(&view, &x, &y))
	testing.expect_value(t, x, 648)
	testing.expect(t, reconcile(&output, nil))
	testing.expect(t, !view_position(&view, &x, &y))
	testing.expect(t, view_surface(&view) == &surface)
	testing.expect(t, reconcile(&output, commands[:]))
	testing.expect(t, view_position(&view, &x, &y))
}

@(test)
client_commits_do_not_dirty_or_repeat_size_requests :: proc(t: ^testing.T) {
	output: Output
	toplevel := sh.Toplevel {
	}
	view := View {
		output   = &output,
		protocol = &toplevel,
	}
	testing.expect(t, request_size(&view, 616, 652))
	for _ in 0 ..< 10 {view_commit(&view.commit, nil)}
	testing.expect(t, !output.dirty)
	testing.expect(t, !request_size(&view, 616, 652))
	testing.expect(t, request_size(&view, 968, 532))
	testing.expect(t, !request_size(&view, 968, 532))
}

@(test)
raster_candidates_are_atomic_and_unchanged_frames_do_nothing :: proc(t: ^testing.T) {
	before, bytes := sp.live_buffers, sp.live_bytes

	output := Output {
		chrome = make(map[u64]^sp.Node),
	}
	defer {clear_chrome(&output)
		sp.output_finish(&output.paint)}
	testing.expect(t, layout.init(&output.ui))
	defer layout.destroy(&output.ui)
	r: vm.Runtime
	testing.expect(t, vm.init(&r))
	defer vm.destroy(&r)
	good :: `core.set_frame_handler(function()
 core.open({id='root',layout={sizing={width=300,height=80}}})
 core.open({id='fit'})
core.text('Owned text 123', {fontSize=18,textColor={r=255,g=255,b=255}})
core.close()
 core.open({id='sibling',layout={sizing={width=40,height=40}},backgroundColor={g=255},cornerRadius={topLeft=12}})
core.close()
 core.close()
collectgarbage('collect')
end)`
	delete(vm.evaluate(&r, good))
	nodes, ok := vm.declare(&r, &output.ui, "TEST", 800, 600)
	testing.expect(t, ok)
	commands, solved := layout.prepare(&output.ui, 800, 600, nodes)
	testing.expect(t, solved && reconcile(&output, commands))
	layout.publish(&output.ui, nodes)
	b, _ := layout.box(&output.ui, "fit", 0)
	count := sp.live_buffers
	for _ in 0 ..< 6 {
		nodes, ok = vm.declare(&r, &output.ui, "TEST", 800, 600)
		commands, solved = layout.prepare(&output.ui, 800, 600, nodes)
		testing.expect(t, ok && solved && reconcile(&output, commands))
		layout.publish(&output.ui, nodes)
		testing.expect_value(t, output.mutations, 0)
		testing.expect_value(t, output.rasters, 0)
		testing.expect_value(t, sp.live_buffers, count)
	}
	delete(
		vm.evaluate(
			&r,
			`core.set_frame_handler(function()
core.open({id='fit'})
core.text('invalidated?')
collectgarbage('collect')
error('after text') end)`,
		),
	)
	_, ok = vm.declare(&r, &output.ui, "TEST", 800, 600)
	testing.expect(t, !ok)
	actual, _ := layout.box(&output.ui, "fit", 0)
	testing.expect_value(t, actual, b)
	testing.expect(t, reconcile(&output, output.ui.commands[:]))
	testing.expect_value(t, output.mutations, 0)
	delete(
		vm.evaluate(
			&r,
			`core.set_frame_handler(function()
core.open({id='fit'})
core.text('prepared first',{textColor={r=255},fontSize=30})
core.close()
core.open({id='huge',layout={sizing={width=100000,height=100000}},backgroundColor={r=255},cornerRadius={topLeft=10}})
core.close()
end)`,
		),
	)
	nodes, ok = vm.declare(&r, &output.ui, "TEST", 800, 600)
	commands, solved = layout.prepare(&output.ui, 800, 600, nodes)
	testing.expect(t, ok && solved)
	testing.expect(t, !reconcile(&output, commands))
	testing.expect_value(t, sp.live_buffers, count)
	testing.expect_value(t, output.mutations, 0)
	actual, _ = layout.box(&output.ui, "fit", 0)
	testing.expect_value(t, actual, b)
	hits := layout.hits(&output.ui, 1, 1)
	testing.expect(t, len(hits) > 0)
	delete(hits)
	delete(vm.evaluate(&r, good))
	nodes, ok = vm.declare(&r, &output.ui, "TEST", 800, 600)
	commands, solved = layout.prepare(&output.ui, 800, 600, nodes)
	testing.expect(t, ok && solved && reconcile(&output, commands))
	layout.publish(&output.ui, nodes)
	testing.expect_value(t, output.rasters, 0)
	testing.expect_value(t, output.mutations, 0)
	testing.expect(t, reconcile(&output, nil))
	testing.expect_value(t, sp.live_buffers, before)
	testing.expect_value(t, sp.live_bytes, bytes)
}

@(test)
client_hit_uses_parts_and_clay_not_raster_alpha :: proc(t: ^testing.T) {

	output := Output {
		chrome = make(map[u64]^sp.Node),
	}
	defer {clear_chrome(&output)
		sp.output_finish(&output.paint)}
	testing.expect(t, layout.init(&output.ui))
	defer layout.destroy(&output.ui)
	s: Server
	defer delete(s.views)
	output.server = &s
	view := View {
		id               = 1,
		mapped           = true,
		output           = &output,
		requested_width  = 40,
		requested_height = 40,
	}
	append(&s.views, &view)
	nodes := [?]layout.Node {
		{
			name = "ring",
			named = true,
			end = 2,
			declaration = {
				layout = {sizing = {clay.SizingFixed(40), clay.SizingFixed(40)}},
				cornerRadius = {20, 20, 20, 20},
				border = {
					color = {255, 255, 255, 255},
					width = {left = 3, right = 3, top = 3, bottom = 3},
				},
			},
		},
		{
			name = "core.surface",
			index = 1,
			named = true,
			end = 2,
			client = {1},
			declaration = {layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}},
		},
	}
	commands, ok := layout.solve(&output.ui, 40, 40, nodes[:])
	testing.expect(t, ok && reconcile(&output, commands))
	for point in ([][2]f64{{2, 2}, {20, 8}, {20, 20}}) {
		testing.expect(
			t,
			sp.contains(output.paint.parts[0].box, point[0], point[1]) &&
			output.paint.parts[0].id == 1,
		)
		testing.expect_value(t, layout.hit(&output.ui, f32(point[0]), f32(point[1])).id, 1)
	}
	// Native targeting now follows the client box even beneath raster border coverage.
	testing.expect(
		t,
		sp.contains(output.paint.parts[0].box, 20, 1) && output.paint.parts[0].id == 1,
	)
	testing.expect_value(t, layout.hit(&output.ui, 20, 1).id, 1)
	testing.expect(t, reconcile(&output, commands))
	testing.expect_value(t, output.mutations, 0)
	testing.expect_value(t, output.rasters, 0)
}

@(test)
command_kinds_and_square_round_transitions_preserve_order :: proc(t: ^testing.T) {

	output := Output {
		chrome = make(map[u64]^sp.Node),
	}
	defer {clear_chrome(&output)
		sp.output_finish(&output.paint)}
	commands := [?]layout.Command {
		{7, {0, 0, 40, 40}, layout.Rectangle{{1, 0, 0, 1}, {}}, {}},
		{7, {0, 0, 40, 40}, layout.Border{{0, 1, 0, 1}, {}, {3, 3, 3, 3}}, {}},
		{8, {50, 0, 40, 40}, layout.Rectangle{{0, 0, 1, 1}, {}}, {}},
	}
	testing.expect(t, sp.key(commands[0]) != sp.key(commands[1]))
	testing.expect(t, reconcile(&output, commands[:]))
	sibling := output.chrome[sp.key(commands[2])]
	for rounded in ([]bool{true, false, true, false}) {
		radius: f32
		if rounded {radius = 20}
		commands[0].content = layout.Rectangle{{1, 0, 0, 1}, {radius, radius, radius, radius}}
		testing.expect(t, reconcile(&output, commands[:]))
		testing.expect_value(t, len(output.chrome), 3)
		testing.expect(t, output.chrome[sp.key(commands[2])] == sibling)
		index := 0
		for c in commands {
			n := output.chrome[sp.key(c)]
			for _ in n.parts {
				testing.expect_value(t, output.paint.parts[index].key, sp.key(c))
				index += 1
			}
		}
		testing.expect(t, reconcile(&output, commands[:]))
		testing.expect_value(t, output.mutations, 0)
		testing.expect_value(t, output.rasters, 0)
	}
}
