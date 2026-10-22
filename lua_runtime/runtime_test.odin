package lua_runtime

import "core:strings"
import "core:testing"
import lua "../luajit"

@(test)
protected_evaluation_restores_stack :: proc(t: ^testing.T) {
	r: Runtime
	testing.expect(t, init(&r))
	defer destroy(&r)
	lua.pushinteger(r.state, 123)
	cases := []struct { source, reply: string }{
		{"6*7", "42\n"},
		{"answer=41", "\n"},
		{"answer+1", "42\n"},
		{"return 1,nil,false,'last'", "1\tnil\tfalse\tlast\n"},
		{"return setmetatable({}, {__tostring=function() error('bad') end}), 'ok'", "?\tok\n"},
		{"error({})", "ERROR:"},
		{"return (", "ERROR:"},
		{"error('broken')", "ERROR:"},
		{"core.spawn(false)", "ERROR:"},
		{"core.spawn({})", "\n"},
		{"core.spawn({'true', false})", "\n"},
		{"6*7", "42\n"},
	}
	for _ in 0..<50 {
		for test in cases {
			reply := evaluate(&r, test.source)
			if test.reply == "ERROR:" { testing.expect(t, strings.has_prefix(reply, "ERROR: ")) }
			else { testing.expect_value(t, reply, test.reply) }
			delete(reply)
			testing.expect_value(t, lua.gettop(r.state), 1)
			testing.expect_value(t, lua.tointeger(r.state, 1), 123)
		}
	}
}

fixture_output :: proc(data: rawptr, index: int) -> (Output, bool) {
	if index >= 20 { return {}, false }
	o := Output{name = "TEST", width = 1920, height = 1080, refresh = 60000,
		scale = 1.5, x = -1920, y = 10, enabled = true, mode_count = 2}
	o.modes[0] = {1920, 1080, 60000}
	o.modes[1] = {1280, 720, 59940}
	return o, true
}

@(test)
output_discovery_preserves_fields_and_cap :: proc(t: ^testing.T) {
	r := Runtime{output = fixture_output}
	testing.expect(t, init(&r))
	defer destroy(&r)
	reply := evaluate(&r, `local all=core.output.list(); local o=all[1]
	return #all,o.name,o.width,o.height,o.refresh,o.scale,o.x,o.y,o.enabled,
	#o.modes,o.modes[2].width,o.modes[2].height,o.modes[2].refresh`)
	defer delete(reply)
	testing.expect_value(t, reply, "16\tTEST\t1920\t1080\t60000\t1.5\t-1920\t10\ttrue\t2\t1280\t720\t59940\n")
	testing.expect_value(t, lua.gettop(r.state), 0)
}
