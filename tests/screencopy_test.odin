package tests

import "core:fmt"
import "core:image/png"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
grim_matches_committed_lua_screenshot :: proc(t: ^testing.T) {
	s, ok := boot(t, `
local ui = require('kiln').ui
core.set_frame_handler(function()
    ui.column({id='root',w='grow',h='grow',color='#18334f',pad=13,gap=7},function()
        ui.box({id='red',w=111,h=79,color='#ee4433'})
        ui.box({id='alpha',w=87,h=55,color='#11ff3388',radius=17})
    end)
end)
`)
	if !ok { stop(&s); return }
	defer quit(t, &s)
	env := make([dynamic]string, 0, len(s.env)+1, context.temp_allocator)
	for entry in s.env { if !strings.has_prefix(entry, "WAYLAND_DISPLAY=") { append(&env, entry) } }
	append(&env, fmt.tprintf("WAYLAND_DISPLAY=kiln-%d", s.process.pid))
	name := strings.trim_space(eval(&s, "return core.output.list()[1].name"))
	for scale in ([2]int{1, 2}) {
		expect_eval(t, &s, fmt.tprintf("core.output.set_scale(%q,%d)", name, scale), "\n")
		time.sleep(200*time.Millisecond)
		lua_path := fmt.tprintf("%s/lua-%d.png", s.work, scale)
		grim_path := fmt.tprintf("%s/grim-%d.png", s.work, scale)
		if !expect_eval(t, &s, fmt.tprintf("return core.screenshot(%q,%q) ~= nil", name, lua_path), "true\n") { return }
		child, err := os.process_start({command = {"grim", "-s", fmt.tprintf("%d", scale), "-o", name, grim_path}, env = env[:]})
		if !testing.expectf(t, err == nil, "start grim: %v", err) { return }
		state, wait_err := os.process_wait(child, 10*time.Second)
		if !state.exited { _ = os.process_kill(child); _, _ = os.process_wait(child) }
		if !testing.expectf(t, wait_err == nil && state.exited && state.exit_code == 0, "grim: %v %v", state, wait_err) { return }
		a, ae := png.load_from_file(lua_path, allocator = context.temp_allocator)
		b, be := png.load_from_file(grim_path, allocator = context.temp_allocator)
		if !testing.expect(t, ae == nil && be == nil) { return }
		if !testing.expect(t, a.width == b.width && a.height == b.height && a.channels >= 3 && b.channels >= 3) { return }
		differences := 0
		for i in 0..<a.width*a.height {
			aa := a.pixels.buf[i*a.channels+3] if a.channels == 4 else 255
			ba := b.pixels.buf[i*b.channels+3] if b.channels == 4 else 255
			if aa != ba || string(a.pixels.buf[i*a.channels:][:3]) != string(b.pixels.buf[i*b.channels:][:3]) { differences += 1 }
		}
		testing.expect_value(t, differences, 0)
		fmt.printf("Screencopy %v scale %d: %dx%d, %d differing pixels; %s\n", backend(), scale, a.width, a.height, differences, s.work)
		if directory := os.get_env("KILN_TEST_ARTIFACTS", context.temp_allocator); directory != "" {
			for path, i in ([2]string{lua_path, grim_path}) {
				bytes, read_err := os.read_entire_file(path, context.temp_allocator)
				testing.expect(t, read_err == nil && os.write_entire_file(fmt.tprintf("%s/%v-%d-%s.png", directory,
					backend(), scale, "lua" if i == 0 else "grim"), bytes) == nil)
			}
			testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%v-server.log", directory, backend()), read_log(&s)) == nil)
		}
	}
}
