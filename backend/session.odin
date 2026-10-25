package backend

import db "../dbus"
import raw "../sd_bus"
import wl "../wayland"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

Session :: struct {
	active: bool,
	vt: u32,
	events: struct { active, device_gone, destroy: wl.Signal },
	switch_vt: proc(^Session,u32) -> bool,
	data: rawptr,
	bus: db.Bus,
	path, seat: string,
	devices, gone_devices: [dynamic]^Session_Device,
	slots: [2]^db.Slot,
	pending: [dynamic]Session_Event,
	idle: ^wl.Source,
	display: ^wl.Display,
	ctx: runtime.Context,
	controlled, property_active, failed, destroying: bool,
}
Session_Device :: struct { fd: i32, major, minor: u32, paused, gone: bool }
Session_Event :: struct { kind: enum { Active, Pause, Resume }, major, minor: u32, fd: i32, active, acknowledge, gone: bool }
LOGIN :: "org.freedesktop.login1"
SESSION :: "org.freedesktop.login1.Session"
session_active :: proc(s: ^Session) -> bool { return s == nil || s.active }
session_switch :: proc(s: ^Session, vt: u32) -> bool { return s != nil && s.switch_vt != nil && s.switch_vt(s,vt) }
device_numbers :: proc(device: u64) -> (u32,u32) { return u32(device>>8&0xfff | device>>32&0xfffff000),u32(device&0xff | device>>12&0xffffff00) }
session_call :: proc(s: ^Session, m: ^db.Message, error_code: ^i32 = nil) -> ^db.Message {
	if m == nil { return nil }; defer db.unref(m)
	error: raw.sd_bus_error; defer raw.sd_bus_error_free(&error)
	reply: ^db.Message
	if result := raw.sd_bus_call(s.bus.handle,m,5_000_000,&error,&reply); result < 0 {
		if error_code != nil { error_code^ = result }
		fmt.eprintf("logind %s: %s (%s)\n",db.member(m),error.message,error.name); return nil
	}
	db.wake(&s.bus)
	return reply
}
session_method :: proc(s: ^Session, member: string) -> ^db.Message { return db.method(&s.bus,LOGIN,s.path,SESSION,member) }
session_property :: proc(s: ^Session, name, signature: cstring) -> ^db.Message {
	reply: ^db.Message; error: raw.sd_bus_error; defer raw.sd_bus_error_free(&error)
	if raw.sd_bus_get_property(s.bus.handle,LOGIN,strings.clone_to_cstring(s.path,context.temp_allocator),SESSION,name,&error,&reply,signature) < 0 { return nil }
	return reply
}
session_create :: proc(display: ^wl.Display) -> ^Session {
	s := new(Session); s.display, s.ctx, s.switch_vt = display,context,session_change_vt
	wl.signal_init(&s.events.active); wl.signal_init(&s.events.device_gone); wl.signal_init(&s.events.destroy)
	ok := false; defer if !ok { session_destroy(s) }
	if !db.open(&s.bus,display,true) { return nil }
	s.bus.data, s.bus.lost = s,session_lost
	id := os.get_env("XDG_SESSION_ID",context.temp_allocator)
	m := db.method(&s.bus,LOGIN,"/org/freedesktop/login1","org.freedesktop.login1.Manager","GetSession" if id != "" else "GetSessionByPID")
	if m == nil { return nil }
	if id != "" { db.put_string(m,id) } else { db.put_u32(m,0) }
	reply := session_call(s,m)
	if reply == nil { fmt.eprintln("no logind session"); return nil }
	path: cstring; db.read(reply,'o',&path); s.path = strings.clone(string(path)); db.unref(reply)
	m = session_method(s,"TakeControl"); db.put_bool(m,false)
	reply = session_call(s,m); if reply == nil { return nil }; db.unref(reply); s.controlled = true
	reply = session_property(s,"Seat","(so)"); if reply == nil { return nil }
	db.enter(reply,'r',"so"); name: cstring; db.read(reply,'s',&name); db.read(reply,'o',&path)
	s.seat = strings.clone(string(path)); db.unref(reply)
	reply = session_property(s,"VTNr","u"); if reply != nil { db.read(reply,'u',&s.vt); db.unref(reply) }
	reply = session_property(s,"Active","b"); if reply == nil { return nil }
	active: i32; db.read(reply,'b',&active); db.unref(reply); s.property_active, s.active = active != 0,active != 0
	for iface,i in ([]string{SESSION,"org.freedesktop.DBus.Properties"}) {
		if !db.match(&s.bus,&s.slots[i],fmt.tprintf("type='signal',sender='%s',path='%s',interface='%s'",LOGIN,s.path,iface),session_signal,s) { return nil }
	}
	fmt.printf("logind: controlling %s on VT %d, active %v\n",s.path,s.vt,s.active)
	ok = true; return s
}
session_queue :: proc(s: ^Session, e: Session_Event) {
	if s.destroying { if e.kind == .Resume { linux.close(linux.Fd(e.fd)) }; return }
	append(&s.pending,e)
	if s.idle == nil { s.idle = wl.on_idle(s.display,session_dispatch,s) }
}
session_lost :: proc(data: rawptr) { s := cast(^Session)data; s.failed = true; session_queue(s,Session_Event{kind=.Active}) }
session_signal :: proc "c" (m: ^db.Message, data: rawptr, error: ^db.Error) -> i32 {
	s := cast(^Session)data; context = s.ctx
	e := Session_Event{fd=-1}
	switch db.member(m) {
	case "PauseDevice":
		e.kind = .Pause; kind: cstring
		if db.read(m,'u',&e.major) <= 0 || db.read(m,'u',&e.minor) <= 0 || db.read(m,'s',&kind) <= 0 { return 0 }
		e.acknowledge, e.gone = string(kind) == "pause",string(kind) == "gone"
	case "ResumeDevice":
		e.kind = .Resume; fd: i32
		if db.read(m,'u',&e.major) <= 0 || db.read(m,'u',&e.minor) <= 0 || db.read(m,'h',&fd) <= 0 { return 0 }
		duplicate, err := linux.fcntl(linux.Fd(fd),linux.F_DUPFD_CLOEXEC,0)
		if err != .NONE { return 0 }; e.fd = i32(duplicate)
	case "PropertiesChanged":
		iface,_ := db.read_string(m); if iface != SESSION { return 0 }
		db.enter(m,'a',"{sv}")
		for db.enter(m,'e',"sv") > 0 {
			name,_ := db.read_string(m)
			if name == "Active" && db.enter(m,'v',"b") > 0 {
				value: i32; db.read(m,'b',&value); session_queue(s,Session_Event{kind=.Active,active=value != 0}); return 0
			}
			db.skip(m); db.leave(m)
		}
		return 0
	case: return 0
	}
	session_queue(s,e); return 0
}
session_recompute :: proc(s: ^Session, reason := "device resumed") {
	active := s.property_active && !s.failed
	why := reason
	if !s.property_active { why = "Active property is false" }
	for d in s.devices { if d.paused { active = false; why = fmt.tprintf("device %d:%d is paused",d.major,d.minor) } }
	if s.failed { why = "session failed" }
	if active != s.active {
		s.active = active
		fmt.eprintf("logind: session %s (%s)\n","resumed" if active else "paused",why)
		wl.signal_emit_mutable(&s.events.active,s)
	}
}
session_dispatch :: proc(data: rawptr) {
	s := cast(^Session)data; s.idle = nil
	pending := s.pending; s.pending = nil
	defer delete(pending)
	for e in pending {
		d: ^Session_Device
		for v in s.devices { if v.major == e.major && v.minor == e.minor { d = v; break } }
		switch e.kind {
		case .Active:
			was_active := s.active; s.property_active = e.active; session_recompute(s,"Active property is true")
			if s.failed && !was_active { wl.signal_emit_mutable(&s.events.active,s) }
		case .Pause:
			if d == nil { continue }
			if e.gone {
				d.gone = true
				for v,i in s.devices { if v == d { ordered_remove(&s.devices,i); break } }
				// Consumers still own the fd until their close callback runs.
				append(&s.gone_devices,d)
				wl.signal_emit_mutable(&s.events.device_gone,d)
				continue
			}
			d.paused = true; session_recompute(s)
			// Listeners stop input and abandon queued flips before logind can revoke access.
			if e.acknowledge { m := session_method(s,"PauseDeviceComplete"); db.put_u32(m,e.major); db.put_u32(m,e.minor); db.unref(session_call(s,m)) }
		case .Resume:
			if d != nil {
				_, err := linux.dup3(linux.Fd(e.fd),linux.Fd(d.fd),{.CLOEXEC})
				if err == .NONE { d.paused = false } else { s.failed = true }
			}
			linux.close(linux.Fd(e.fd)); if d != nil { session_recompute(s) }
		}
	}
}
session_open :: proc(s: ^Session, path: string, flags: i32) -> i32 {
	if !s.controlled || s.failed { return -13 }
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(path,context.temp_allocator),&st) != .OK { return -i32(posix.get_errno()) }
	major,minor := device_numbers(u64(st.st_rdev))
	m := session_method(s,"TakeDevice"); db.put_u32(m,major); db.put_u32(m,minor)
	failure: i32; reply := session_call(s,m,&failure); if reply == nil { return failure if failure < 0 else -5 }; defer db.unref(reply)
	fd, inactive: i32
	if db.read(reply,'h',&fd) <= 0 || db.read(reply,'b',&inactive) <= 0 { session_release(s,major,minor); return -5 }
	copy, err := linux.fcntl(linux.Fd(fd),linux.F_DUPFD_CLOEXEC,0)
	if err != .NONE { session_release(s,major,minor); return -i32(err) }
	flag_error := linux.fcntl(copy,linux.F_SETFL,(transmute(linux.Open_Flags)u32(flags)))
	if flag_error != .NONE { linux.close(copy); session_release(s,major,minor); return -i32(flag_error) }
	d := new(Session_Device); d^ = {fd=i32(copy),major=major,minor=minor,paused=inactive != 0}; append(&s.devices,d)
	return d.fd
}
session_release :: proc(s: ^Session, major,minor: u32) {
	if s.bus.handle == nil || !s.controlled { return }
	m := session_method(s,"ReleaseDevice"); db.put_u32(m,major); db.put_u32(m,minor); db.unref(session_call(s,m))
}
session_close :: proc(s: ^Session, fd: i32) {
	for devices in ([]^[dynamic]^Session_Device{&s.devices,&s.gone_devices}) {
		for d,i in devices^ { if d.fd == fd {
			ordered_remove(devices,i); linux.close(linux.Fd(fd))
			if !d.gone { session_release(s,d.major,d.minor) }; free(d); return
		} }
	}
}
session_change_vt :: proc(s: ^Session, vt: u32) -> bool {
	if !s.controlled { return false }
	m := db.method(&s.bus,LOGIN,s.seat,"org.freedesktop.login1.Seat","SwitchTo"); db.put_u32(m,vt)
	reply := session_call(s,m); defer db.unref(reply); return reply != nil
}
session_destroy :: proc(s: ^Session) {
	if s == nil { return }; context = s.ctx; s.destroying = true
	wl.remove_source(s.idle)
	wl.signal_emit_final(&s.events.destroy,s)
	for &slot in s.slots { db.cancel(&slot) }
	for e in s.pending { if e.kind == .Resume { linux.close(linux.Fd(e.fd)) } }; delete(s.pending)
	for len(s.devices) > 0 { session_close(s,s.devices[len(s.devices)-1].fd) }; delete(s.devices)
	for len(s.gone_devices) > 0 { session_close(s,s.gone_devices[len(s.gone_devices)-1].fd) }; delete(s.gone_devices)
	if s.controlled && s.bus.handle != nil { db.unref(session_call(s,session_method(s,"ReleaseControl"))) }
	db.close(&s.bus); delete(s.path); delete(s.seat); free(s)
}
