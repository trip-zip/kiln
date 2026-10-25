package backend

import out "../outputs"
import wl "../wayland"
import "core:fmt"
import "core:os"

Backend :: struct {
	events:              struct {
		new_output, new_input, destroy: wl.Signal,
	},
	session:             ^Session,
	drm_fd:              i32,
	loop:                ^wl.Loop,
	display:             ^wl.Display,
	impl:                ^Backend_Impl,
	data:                rawptr,
	started, destroying: bool,
	display_destroy:     wl.Listener,
}

Backend_Impl :: struct {
	start:      proc(_: ^Backend) -> bool,
	destroy:    proc(_: ^Backend),
	add_output: proc(_: ^Backend) -> ^out.Output,
}

init :: proc(b: ^Backend, display: ^wl.Display, impl: ^Backend_Impl) {
	b.display, b.loop, b.impl, b.drm_fd = display, display.loop, impl, -1
	wl.signal_init(&b.events.new_output)
	wl.signal_init(&b.events.new_input)
	wl.signal_init(&b.events.destroy)
	wl.listen(&display.destroy_signal, &b.display_destroy, display_destroyed)
}

display_destroyed :: proc(l: ^wl.Listener, data: rawptr) {
	destroy(wl.owner(l, Backend, "display_destroy"))
}

selected_name :: proc() -> string {
	name := os.get_env("KILN_BACKEND", context.temp_allocator)
	if name != "" {return name}
	return "nested" if os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" else "drm"
}

create :: proc(display: ^wl.Display, name: string) -> ^Backend {
	if name == "headless" {
		b := headless_create(display)
		(cast(^Headless)b.data).default_outputs = true
		return b
	}
	if name == "nested" {return nested_create(display)}
	if name == "drm" {return drm_create(display)}
	fmt.eprintf("Unknown or unavailable backend: %s\n", name)
	return nil
}

start :: proc(b: ^Backend) -> bool {
	if b.started {return true}
	return b.impl.start(b)
}

destroy :: proc(b: ^Backend) {
	if b == nil || b.destroying {return}
	b.destroying = true
	wl.unlisten(&b.display_destroy)
	wl.signal_emit_final(&b.events.destroy, b)
	b.impl.destroy(b)
}

nested_add_output :: proc(b: ^Backend) -> ^out.Output {
	return b.impl.add_output(b) if b.impl.add_output != nil else nil
}
