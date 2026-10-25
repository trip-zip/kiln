package compositor

import bk "../backend"
import out "../outputs"
import "../buffers"
import sf "../surfaces"
import xw "../xwayland"
import st "../seat"
import sh "../shells"
import ext "../extensions"
import auth "../authentication"
import services "../desktop_bus"
import ipc "../ipc"
import vm "../lua_runtime"
import sp "../scene_paint"
import wl "../wayland"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sys/linux"
import "../gles"

Server :: struct {
	screencopy: ^ext.Screencopy,
	screenshot_seq:                                                                       u64,
	auth:                                                                                 auth.Attempt,
	next_auth:                                                                            u64,
	lock_owner:                                                                           Lock_Owner,
	lock_generation:                                                                      u64,
	authenticated, lock_acknowledged:                                                     bool,
	ext_lock:                                                                             ^sh.Lock,
	new_lock, lock_new_surface, lock_unlock, lock_destroy:                                wl.Listener,
	lock_surfaces:                                                                        [dynamic]^Lock_Surface,
	idle_notifier:                                                                        ^ext.Idle_Notifier,
	new_idle_inhibitor:                                                                   wl.Listener,
	idle_inhibitors:                                                                      [dynamic]^Idle_Inhibitor,
	idle_timer:                                                                           ^wl.Event_Source,
	idle_timeout_ms:                                                                      i32,
	idle, idle_inhibited:                                                                 bool,
	services:                                                                             services.Services,
	lua:                                                                                  vm.Runtime,
	ipc:                                                                                  ipc.Server,
	quit_source, event_source:                                                            ^wl.Event_Source,
	events:                                                                               [dynamic]vm.Event,
	timers:                                                                               map[u64]^Timer,
	pipes:                                                                                map[u64]^Pipe,
	next_pipe, next_clock:                                                                u64,
	next_output:                                                                          u64,
	shutting_down:                                                                        bool,
	keyboard_grabbed, pointer_grabbed:                                                    bool,
	keyboard_epoch, pointer_epoch, next_keyboard:                                         u64,
	buttons:                                                                              map[u32]bool,
	display:                                                                              ^wl.Display,
	backend:                                                                              ^bk.Backend,
	session:                                                                              ^bk.Session,
	session_active, session_destroy:                                                      wl.Listener,
	gles:                                                                                 ^gles.Renderer,
	cursor_surface:                                                                       ^sf.Surface,
	cursor_hx, cursor_hy:                                                                 i32,
	cursor_surface_destroy, cursor_surface_commit:                                        wl.Listener,
	scene:                                                                                ^sp.Scene,
	xdg_output:                                                                           ^ext.Xdg_Output_Manager,
	gamma:                                                                                ^ext.Gamma,
	layout:                                                                               ^out.Layout,
	shell:                                                                                ^sh.Shell,
	xwayland:                                                                             ^xw.Server,
	x11_atoms:                                                                            [21]u32,
	xwayland_ready, xwayland_destroy, new_xwayland_surface:               wl.Listener,
	layer_shell:                                                                          ^sh.Layer_Shell,
	activation:                                                                           ^ext.Activation,
	foreign_manager:                                                                      ^ext.Foreign_Manager,
	request_activate:                                                                     wl.Listener,
	minted_tokens:                                                                        [dynamic]^Minted_Token,
	new_layer, new_decoration:                                                            wl.Listener,
	layers:                                                                               [dynamic]^Layer,
	popups:                                                                               [dynamic]^Popup,
	new_output, layout_change, backend_destroy:                                           wl.Listener,
	failed:                                                                               bool,
	seat:                                                                                 ^st.Seat,
	cursor_x, cursor_y: f64,
	cursor_manager:                                                                       ^st.Cursor_Manager,
	cursor_name:                                                                          cstring,
	cursor_name_allocator:                                                                runtime.Allocator,
	cursor_named:                                                                         bool,
	next_pointer:                                                                         u64,
	popup_grab, popup_previous_destroy: wl.Listener,
	popup_previous: ^sf.Surface,
	popup_grab_active: bool,
	new_toplevel, new_popup, new_input:                                                   wl.Listener,
	request_cursor, request_selection:                                                    wl.Listener,
	request_primary_selection, request_drag, start_drag, drag_destroy, drag_icon_destroy: wl.Listener,
	drag_active:                                                                          bool,
	drag_icon:                                                                            ^st.Drag_Icon,
	drag_dx, drag_dy:                                                                     i32,
	drag_commit:                                                                          wl.Listener,
	constraints:                                                                          ^st.Constraint_Manager,
	relative:                                                                             ^ext.Relative_Manager,
	active_constraint:                                                                    ^st.Constraint,
	constraint_owners:                                                                    [dynamic]^Constraint,
	new_constraint, pointer_focus_change, request_cursor_shape:                           wl.Listener,
	views:                                                                                [dynamic]^View,
	outputs:                                                                              [dynamic]^Output,
	next_view_id:                                                                         u32,
	keyboards:                                                                            [dynamic]^Keyboard,
	pointers:                                                                             [dynamic]^Pointer,
	focused:                                                                              ^View,
	requested_focus, pointer_client:                                                      u32,
	startup:                                                                              os.Process,
	startup_running:                                                                      bool,
}

fail :: proc(s: ^Server, message: string) {
	fmt.eprintln(message)
	s.failed = true
	wl.terminate(s.display)
}

stop :: proc(number: linux.Signal, data: rawptr) -> i32 {
	wl.terminate((^Server)(data).display)
	return 0
}

backend_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "backend_destroy")
	wl.unlisten(&s.new_output)
	wl.unlisten(listener)
	s.backend = nil
	wl.terminate(s.display)
}

destroy :: proc(s: ^Server) {
	s.shutting_down = true
	auth.shutdown(&s.auth)
	wl.unlisten(&s.new_lock)
	wl.remove_source(s.idle_timer)
	wl.unlisten(&s.new_idle_inhibitor)
	services.destroy(&s.services)
	wl.remove_source(s.event_source)
	for &event in s.events {free_event(&event)}
	delete(s.events)
	wl.remove_source(s.quit_source)
	ipc.destroy(&s.ipc)
	vm.destroy(&s.lua)
	for id in s.timers {runtime_timer_remove(s, id)}
	delete(s.timers)
	s.timers = nil
	shutdown_pipes(s)
	runtime_grab_keyboard(s, false)
	runtime_grab_pointer(s, false)
	if s.xwayland != nil {xw.server_destroy(s.xwayland)}
	if s.display != nil {wl.destroy_clients(s.display)}
	fmt.printf("Protocol cleanup: layers %d, popups %d\n", len(s.layers), len(s.popups))
	wl.unlisten(&s.new_constraint)
	wl.unlisten(&s.pointer_focus_change)
	wl.unlisten(&s.request_activate)
	for len(s.minted_tokens) > 0 {ext.activation_retire(s.minted_tokens[0].token)}
	fmt.printf(
		"Interaction cleanup: trusted tokens %d, constraints %d, drag %v\n",
		len(s.minted_tokens),
		len(s.constraint_owners),
		s.drag_active,
	)
	delete(s.minted_tokens)
	delete(s.constraint_owners)
	wl.unlisten(&s.new_toplevel)
	wl.unlisten(&s.new_popup)
	wl.unlisten(&s.popup_grab)
	wl.unlisten(&s.popup_previous_destroy)
	wl.unlisten(&s.new_layer)
	wl.unlisten(&s.new_decoration)
	wl.unlisten(&s.new_input)
	wl.unlisten(&s.request_cursor_shape)
	wl.unlisten(&s.request_cursor)
	wl.unlisten(&s.request_selection)
	wl.unlisten(&s.request_primary_selection)
	wl.unlisten(&s.request_drag)
	wl.unlisten(&s.start_drag)
	wl.unlisten(&s.drag_destroy)
	wl.unlisten(&s.new_output)
	wl.unlisten(&s.layout_change)
	wl.unlisten(&s.backend_destroy)
	wl.unlisten(&s.session_active)
	wl.unlisten(&s.session_destroy)
	if s.backend != nil {bk.destroy(s.backend)}
	fmt.printf(
		"Input cleanup: keyboards %d, pointers %d, keyboard claim %v, pointer claim %v\n",
		len(s.keyboards),
		len(s.pointers),
		s.keyboard_grabbed,
		s.pointer_grabbed,
	)
	wl.unlisten(&s.cursor_surface_destroy)
	wl.unlisten(&s.cursor_surface_commit)
	if s.cursor_manager != nil {st.xcursor_manager_destroy(s.cursor_manager)}
	if s.cursor_name != nil {delete(s.cursor_name, s.cursor_name_allocator)}
	if s.scene != nil {sp.scene_destroy(s.scene)}
	if s.layout != nil {out.layout_destroy(s.layout)}
	gles.destroy(s.gles)
	if s.display != nil {wl.destroy(s.display)}
	wl.unlisten(&s.new_lock)
	delete(s.lock_surfaces)
	delete(s.idle_inhibitors)
	delete(s.outputs)
	delete(s.views)
	delete(s.layers)
	delete(s.popups)
	delete(s.keyboards)
	delete(s.pointers)
	delete(s.buttons)
	finish_startup(s)
	fmt.printf("Paint cleanup: live buffers %d, live bytes %d\n", sp.live_buffers, sp.live_bytes)
}

// A disappearing selection reader must yield EPIPE to the protocol library.
// A caught disposition resets on exec, preserving child-program pipe semantics.
broken_pipe :: proc "c" (signal: linux.Signal) {}

run :: proc(startup_command := "") -> bool {
	pipe_action := linux.Sig_Action {
		handler = broken_pipe,
		flags   = {.RESTART},
	}
	previous_pipe_action: linux.Sig_Action
	if linux.rt_sigaction(.SIGPIPE, &pipe_action, &previous_pipe_action) != .NONE {return false}
	defer linux.rt_sigaction(.SIGPIPE, &previous_pipe_action, nil)
	s: Server
	fixture_attach(rawptr(&s))
	defer fixture_attach(nil)
	defer destroy(&s)
	s.display = wl.create()
	if s.display == nil {return false}
	s.backend = bk.create(s.display, bk.selected_name())
	if s.backend == nil {return false}
	s.session = s.backend.session
	if s.session != nil {
		wl.listen(&s.session.events.active, &s.session_active, session_changed)
		wl.listen(&s.session.events.destroy, &s.session_destroy, session_destroyed)
	}
	s.gles = gles.create(s.backend.drm_fd)
	if s.gles == nil {return false}
	fmt.printf("Renderer: GLES %s; native session: %v\n", gles.name(s.gles), s.session != nil)
	shm_formats, dmabuf_formats, device, formats_ok := gles.buffer_formats(s.gles)
	if !formats_ok || !buffers.create_globals(s.display, shm_formats, dmabuf_formats, device, s.gles.fd) {return false}
	compositor := sf.compositor_create(s.display, 5)
	if compositor == nil {return false}
	if sf.subcompositor_create(s.display) == nil {return false}
	if sf.viewporter_create(s.display) == nil || sf.fractional_scale_create(s.display) == nil {return false}
	s.layout = out.layout_create(s.display)
	if s.layout == nil {return false}
	wl.listen(&s.layout.events.change, &s.layout_change, output_layout_changed)
	s.xdg_output = ext.xdg_output_create(s.display, s.layout)
	if s.xdg_output == nil {return false}
	s.scene = sp.scene_create()
	if s.scene == nil {return false}
	sp.attach_compositor(s.scene, compositor, s.gles)
	s.screencopy = ext.screencopy_create(s.display, s.scene)
	if s.screencopy == nil {return false}
	s.gamma = ext.gamma_create(s.display, output_gamma, s.scene)
	if s.gamma == nil {return false}
	s.shell = sh.xdg_shell_create(s.display)
	if s.shell == nil {return false}
	wl.listen(&s.shell.events.new_toplevel, &s.new_toplevel, view_added)
	wl.listen(&s.shell.events.new_popup, &s.new_popup, popup_added)
	wl.listen(&s.shell.events.grab_changed, &s.popup_grab, popup_grab_changed)
	s.layer_shell = sh.layer_shell_create(s.display)
	if s.layer_shell == nil {return false}
	wl.listen(&s.layer_shell.events.new_surface, &s.new_layer, layer_added)
	deco := sh.decoration_create(s.display)
	if deco == nil {return false}
	wl.listen(&deco.events.new_toplevel_decoration, &s.new_decoration, decoration_added)
	if !init_input(&s) {return false}
	if !init_data(&s) {return false}
	if !init_constraints(&s) {return false}
	if !init_idle(&s) {return false}
	if !init_lock(&s) {return false}
	shape := ext.cursor_shape_create(s.display)
	if shape == nil {return false}
	wl.listen(&shape.events.request_set_shape, &s.request_cursor_shape, cursor_shape_requested)
	s.relative = ext.relative_create(s.display)
	if s.relative == nil {return false}
	s.foreign_manager = ext.foreign_manager_create(s.display)
	if s.foreign_manager == nil {return false}
	s.activation = ext.activation_create(s.display)
	if s.activation == nil {return false}
	wl.listen(&s.activation.events.request_activate, &s.request_activate, activation_requested)
	wl.listen(&s.backend.events.new_output, &s.new_output, output_added)
	wl.listen(&s.backend.events.destroy, &s.backend_destroy, backend_destroyed)

	term := wl.on_signal(s.display, .SIGTERM, stop, &s)
	if term == nil {return false}
	defer wl.remove_source(term)
	interrupt := wl.on_signal(s.display, .SIGINT, stop, &s)
	if interrupt == nil {return false}
	defer wl.remove_source(interrupt)

	socket := fmt.aprintf("kiln-%d", os.get_pid())
	defer delete(socket)
	if !wl.add_socket(s.display, socket) {return false}
	if !bk.start(s.backend) || s.failed {return false}
	init_xwayland(&s)
	runtime_cursor(&s, "default")
	child := wl.on_signal(s.display, .SIGCHLD, startup_exited, &s)
	if child == nil {return false}
	defer wl.remove_source(child)
	if os.set_env("WAYLAND_DISPLAY", socket) != nil {return false}
	s.lua.capture = runtime_screenshot
	s.lua.inspect, s.lua.inspect_scroll = runtime_inspector, runtime_inspector_scroll
	s.lua.authenticate, s.lua.lock_state = runtime_authenticate, runtime_lock_state
	s.lua.lock, s.lua.unlock = runtime_lock, runtime_unlock
	s.lua.set_idle_timeout = runtime_idle_timeout
	s.lua.configure_layer = runtime_layer_configure
	s.lua.output_set = runtime_output_set
	s.lua.request_reload = runtime_request_reload
	s.lua.reset_clocks = runtime_reset_clocks
	s.lua.tick = runtime_tick
	s.lua.spawn_pipe = runtime_spawn_pipe
	s.lua.mint_token, s.lua.retire_token = runtime_mint_token, runtime_retire_token
	s.lua.timer_add, s.lua.timer_remove = runtime_timer_add, runtime_timer_remove
	s.lua.data, s.lua.output, s.lua.quit = &s, runtime_output, request_quit
	s.lua.dirty, s.lua.find_layout, s.lua.valid_client =
		runtime_dirty, runtime_layout, runtime_client
	s.lua.replay, s.lua.discover = runtime_replay, runtime_discover
	s.lua.minimize = runtime_minimize
	s.lua.fullscreen, s.lua.maximize, s.lua.suspend =
		runtime_fullscreen, runtime_maximize, runtime_suspend
	s.lua.focus, s.lua.activate, s.lua.focused = runtime_focus, runtime_activate, runtime_focused
	s.lua.configure_client, s.lua.tiled_client, s.lua.mirror_client =
		runtime_client_configure, runtime_client_tiled, runtime_client_mirror
	s.lua.close_client, s.lua.kill_client, s.lua.focus_target =
		runtime_close, runtime_kill, runtime_focus_target
	s.lua.grab_keyboard, s.lua.grab_pointer = runtime_grab_keyboard, runtime_grab_pointer
	s.lua.set_keymap, s.lua.set_repeat, s.lua.set_numlock =
		runtime_keymap, runtime_repeat, runtime_numlock
	s.lua.set_pointer, s.lua.set_cursor, s.lua.set_cursor_theme =
		runtime_pointer, runtime_cursor, runtime_cursor_theme
	if !vm.init(&s.lua) {return false}
	ipc_path := ipc.socket_path()
	defer delete(ipc_path)
	if !ipc.init(&s.ipc, s.display, ipc_path, runtime_eval, &s) {
		fmt.eprintf("Cannot create IPC socket %s (existing paths are never replaced)\n", ipc_path)
		return false
	}
	s.services.images = &s.lua.images
	s.services.data, s.services.emit = &s, dbus_event
	s.lua.notify_closed, s.lua.notify_action, s.lua.tray_activate =
		runtime_notify_closed, runtime_notify_action, runtime_tray_activate
	services.init(&s.services, s.display)
	rc := vm.resolve_config()
	defer delete(rc)
	vm.load_config(&s.lua, rc)
	if startup_command != "" && !start_command(&s, socket, startup_command) {return false}
	fmt.printf("Running Wayland compositor on WAYLAND_DISPLAY=%s\n", socket)
	wl.run(s.display)
	return !s.failed
}
