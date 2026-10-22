package tests

import "core:fmt"
import "core:image/png"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(test)
ipc_evaluates_and_formats_replies :: proc(t: ^testing.T) {
	s, ok := boot(t, "SESSION_VALUE = 73")
	if !ok { return }
	defer quit(t, &s)

	info: posix.stat_t
	testing.expect(t, posix.stat(strings.clone_to_cstring(s.sock, context.temp_allocator), &info) == .OK, "stat socket")
	testing.expectf(t, info.st_mode & ~posix.S_IFMT == posix.mode_t{.IRUSR, .IWUSR}, "socket is owner-only: %v", info.st_mode)

	expect_eval(t, &s, "SESSION_VALUE", "73\n")
	expect_eval(t, &s, "SESSION_VALUE = SESSION_VALUE + 1", "\n")
	expect_eval(t, &s, "SESSION_VALUE", "74\n")
	expect_eval(t, &s, "return 1, 2", "1\t2\n")
	expect_eval(t, &s, `return 1, nil, false, "end", nil`, "1\tnil\tfalse\tend\tnil\n")
	expect_eval(t, &s, `return setmetatable({}, { __tostring = function() error("boom") end }), "after"`, "?\tafter\n")
}

@(test)
one_output_is_present_with_typed_fields :: proc(t: ^testing.T) {
	s, ok := boot(t, "")
	if !ok { return }
	defer quit(t, &s)

	expect_eval(t, &s, "return #core.output.list()", "1\n")
	expect_eval(t, &s, "local o = core.output.list()[1]; return type(o.name), type(o.modes), type(o.scale), type(o.x), type(o.y), type(o.enabled)",
		"string\ttable\tnumber\tnumber\tnumber\tboolean\n")
	expect_eval(t, &s, "local o = core.output.list()[1]; return o.width > 0 and o.height > 0 and o.enabled", "true\n")
}

@(test)
stock_config_boots_and_draws :: proc(t: ^testing.T) {
	rc, _ := os.read_entire_file(ROOT + "kilnrc.lua", context.temp_allocator)
	s, ok := boot(t, string(rc))
	if !ok { return }
	defer quit(t, &s)

	expect_eventually(t, &s, "return #screen.all()", "1\n")

	// The screenshot verb reads the frame back through the renderer, so a
	// decodable image the size of the output proves the pipeline drew.
	path := fmt.tprintf("%s/shot.png", s.work)
	expect_eventually(t, &s, fmt.tprintf(`return core.screenshot(screen.all()[1].name, %q) ~= nil`, path), "true\n")
	size := eval(&s, "local o = core.output.list()[1]; return o.width, o.height")
	img, err := png.load_from_file(path, allocator = context.temp_allocator)
	if !testing.expectf(t, err == nil, "decode screenshot: %v", err) { return }
	testing.expect_value(t, fmt.tprintf("%d\t%d\n", img.width, img.height), size)
	first := img.pixels.buf[:img.channels]
	uniform := true
	for i := img.channels; i < len(img.pixels.buf); i += img.channels {
		if string(img.pixels.buf[i:i+img.channels]) != string(first) { uniform = false; break }
	}
	testing.expect(t, !uniform, "the frame has more than one colour")
}
