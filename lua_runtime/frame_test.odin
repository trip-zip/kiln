package lua_runtime

import "core:strings"
import "core:fmt"
import "core:testing"
import layout "../layout"
import lua "../luajit"

fixture_client :: proc(data: rawptr, id: u32, screen: string) -> bool { return id == 7 }

@(test)
frames_are_transactional_and_gc_safe :: proc(t: ^testing.T) {
	r := Runtime{valid_client = fixture_client}
	testing.expect(t, init(&r))
	defer destroy(&r)
	l: layout.Layout
	testing.expect(t, layout.init(&l))
	defer layout.destroy(&l)
	good :: `core.set_frame_handler(function(s,w,h)
		previous=core.box({'leaf',7})
		local d={id={'leaf',7}, layout={sizing={width=101.5,height=40.5}},
			backgroundColor={r=12,g=34,b=56}}
		core.open(d); d.layout.sizing.width=900; d.id[1]='mutated'
		collectgarbage('collect'); core.close()
	end)`
	bad := []string{
		`core.close()`, `core.open({})`, `core.open({});core.open({});error('nested')`,
		`core.open(false)`, `core.open({id={'bad','index'}})`,
		`core.open({border={width={left=-1}}})`, `core.open({layout={sizing={width=0/0}}})`,
		`core.surface(0)`, `core.surface(999)`, `core.surface(7);core.surface(7)`,
		`core.open({id='dup'});core.open({id='dup'})`,
		`core.open(setmetatable({}, {__index=function() error('metatable') end}))`,
	}
	lua.pushinteger(r.state, 123)
	for _ in 0..<3 {
		for source in bad {
			reply := evaluate(&r, good)
			testing.expect_value(t, reply, "\n")
			delete(reply)
			nodes, valid := declare(&r, &l, "TEST", 800, 600)
			testing.expect(t, valid)
			_, solved := layout.solve(&l, 800, 600, nodes)
			testing.expect(t, solved)
			b, found := layout.box(&l, "leaf", 7)
			testing.expect(t, found)
			testing.expect_value(t, b, layout.Box{0,0,101.5,40.5})
			handler := fmt.aprintf("core.set_frame_handler(function() %s end)", source)
			reply = evaluate(&r, handler)
			delete(handler)
			delete(reply)
			_, valid = declare(&r, &l, "TEST", 800, 600)
			testing.expect(t, !valid)
			b, found = layout.box(&l, "leaf", 7)
			testing.expect(t, found)
			testing.expect_value(t, b, layout.Box{0,0,101.5,40.5})
			hits := layout.hits(&l, 10, 10)
			testing.expect(t, len(hits)>0 && hits[0].name == "leaf" && hits[0].index == 7)
			delete(hits)
			reply = evaluate(&r, `collectgarbage('collect'); local b=core.box({'leaf',7}); return b.width,b.height`)
			testing.expect_value(t, reply, "102\t41\n")
			delete(reply)
			testing.expect_value(t, lua.gettop(r.state), 1)
			testing.expect_value(t, lua.tointeger(r.state, 1), 123)
		}
	}
	reply := evaluate(&r, good)
	delete(reply)
	nodes, valid := declare(&r, &l, "TEST", 800, 600)
	testing.expect(t, valid)
	_, solved := layout.solve(&l, 800, 600, nodes)
	testing.expect(t, solved)
	reply = evaluate(&r, "return previous.width,previous.height")
	testing.expect_value(t, reply, "102\t41\n")
	delete(reply)
	reply = evaluate(&r, "core.set_frame_handler(function() end)")
	delete(reply)
	nodes, valid = declare(&r, &l, "TEST", 800, 600)
	testing.expect(t, valid)
	_, solved = layout.solve(&l, 800, 600, nodes)
	testing.expect(t, solved)
	_, found := layout.box(&l, "leaf", 7)
	testing.expect(t, found)
	hits := layout.hits(&l, 10, 10)
	defer delete(hits)
	for hit in hits { testing.expect(t, hit.name != "leaf") }
	outside := []string{`core.open({})`, `core.close()`, `core.surface(7)`,
		`core.set_frame_handler(nil)`, `core.set_event_handler(false)`}
	for source in outside {
		reply = evaluate(&r, source)
		testing.expect(t, strings.has_prefix(reply, "ERROR:"))
		delete(reply)
	}
}

@(test)
event_replacement_and_errors_preserve_vm :: proc(t: ^testing.T) {
	r: Runtime
	testing.expect(t, init(&r))
	defer destroy(&r)
	reply := evaluate(&r, `events={}; core.set_event_handler(function(e)
		events[#events+1]=e
		core.set_event_handler(function(next) events[#events+1]=next end)
		collectgarbage('collect'); error('event failure')
	end)`)
	delete(reply)
	mapped := Event{name="map",handle=7,width=800,height=600,app_id="foot",has_app_id=true,fullscreen=true}
	testing.expect(t, !deliver(&r,&mapped))
	unmapped := Event{name="unmap",handle=7}
	testing.expect(t, deliver(&r,&unmapped))
	destroyed := Event{name="destroy",handle=7}
	testing.expect(t, deliver(&r,&destroyed))
	reply = evaluate(&r, `return #events,events[1].class,events[1].name,events[1].handle,
		events[1].width,events[1].height,events[1].app_id,events[1].title,
		events[1].fullscreen,events[1].maximized,events[2].name,events[3].name`)
	defer delete(reply)
	testing.expect_value(t, reply, "3\tclient\tmap\t7\t800\t600\tfoot\tnil\ttrue\tnil\tunmap\tdestroy\n")
	testing.expect_value(t, lua.gettop(r.state), 0)
}
