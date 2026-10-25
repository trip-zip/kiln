package backend

import wl "../wayland"
import db "../dbus"
import raw "../sd_bus"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:sys/linux"
import "core:testing"

Session_Observer :: struct { listener: wl.Listener, values: [dynamic]bool, paused: bool }
session_observe :: proc(l: ^wl.Listener, data: rawptr) { o := wl.owner(l,Session_Observer,"listener"); append(&o.values,(cast(^Session)data).active); sync.atomic_store(&o.paused,!(cast(^Session)data).active) }
@(test)
session_resume_replaces_fd_before_notifying :: proc(t: ^testing.T) {
	display := wl.create(); defer wl.destroy(display)
	s := new(Session); s.ctx,s.display,s.active,s.property_active = context,display,true,true
	wl.signal_init(&s.events.active); wl.signal_init(&s.events.device_gone); wl.signal_init(&s.events.destroy); defer session_destroy(s)
	o: Session_Observer; wl.listen(&s.events.active,&o.listener,session_observe); defer { wl.unlisten(&o.listener); delete(o.values) }
	peer: Session_Test_Logind; if !session_test_logind_start(t,&peer,s,&o) { return }; defer session_test_logind_stop(&peer)
	old_pipe,new_pipe: [2]linux.Fd
	testing.expect_value(t,linux.pipe2(&old_pipe,{.CLOEXEC,.NONBLOCK}),linux.Errno.NONE)
	testing.expect_value(t,linux.pipe2(&new_pipe,{.CLOEXEC,.NONBLOCK}),linux.Errno.NONE)
	defer linux.close(old_pipe[1]); defer linux.close(new_pipe[1])
	d := new(Session_Device); d^ = {fd=i32(old_pipe[0]),major=226,minor=1}; append(&s.devices,d)
	session_queue(s,Session_Event{kind=.Pause,major=226,minor=1,acknowledge=true}); wl.dispatch(display,0)
	testing.expect(t,!s.active); testing.expect(t,d.paused); testing.expect_value(t,len(o.values),1)
	testing.expect_value(t,sync.atomic_load(&peer.acks),1); testing.expect(t,peer.after_pause)
	testing.expect_value(t,peer.major,u32(226)); testing.expect_value(t,peer.minor,u32(1))
	session_queue(s,Session_Event{kind=.Active,active=true}); wl.dispatch(display,0)
	testing.expect(t,!s.active); testing.expect_value(t,len(o.values),1)
	session_queue(s,Session_Event{kind=.Resume,major=226,minor=1,fd=i32(new_pipe[0])}); wl.dispatch(display,0)
	testing.expect(t,s.active); testing.expect(t,!d.paused); testing.expect_value(t,len(o.values),2)
	message := [1]u8{42}; linux.write(new_pipe[1],message[:]); result: [1]u8
	n,err := linux.read(old_pipe[0],result[:]); testing.expect_value(t,err,linux.Errno.NONE); testing.expect_value(t,n,1); testing.expect_value(t,result[0],u8(42))
}

Session_Test_Logind :: struct {
	bus: db.Bus,
	slot: ^db.Slot,
	table: [4]db.Vtable,
	worker: ^thread.Thread,
	observer: ^Session_Observer,
	stop, after_pause: bool,
	acks, releases: int,
	major, minor: u32,
}
session_test_logind_call :: proc "c" (m: ^db.Message, data: rawptr, error: ^db.Error) -> i32 {
	context = runtime.default_context()
	p := cast(^Session_Test_Logind)data
	if db.member(m) == "PauseDeviceComplete" {
		db.read(m,'u',&p.major); db.read(m,'u',&p.minor)
		p.after_pause = sync.atomic_load(&p.observer.paused)
		sync.atomic_add(&p.acks,1)
	} else { sync.atomic_add(&p.releases,1) }
	reply := db.reply(m); raw.sd_bus_send(p.bus.handle,reply,nil); db.unref(reply)
	return 1
}
session_test_logind_run :: proc(data: rawptr) {
	p := cast(^Session_Test_Logind)data
	for !sync.atomic_load(&p.stop) {
		if raw.sd_bus_process(p.bus.handle,nil) <= 0 { time.sleep(time.Millisecond) }
	}
}
session_test_logind_start :: proc(t: ^testing.T, p: ^Session_Test_Logind, s: ^Session, o: ^Session_Observer) -> bool {
	if !testing.expect(t,raw.sd_bus_open_user(&p.bus.handle) >= 0,"run under dbus-run-session") { return false }
	if !testing.expect(t,db.request_name(&p.bus,LOGIN)) { db.close(&p.bus); return false }
	p.table = {db.vstart(),db.vmethod("PauseDeviceComplete","uu","",session_test_logind_call),db.vmethod("ReleaseDevice","uu","",session_test_logind_call),db.vend()}
	if !testing.expect(t,db.register(&p.bus,&p.slot,"/Session",SESSION,p.table[:],p)) { db.close(&p.bus); return false }
	p.observer = o
	p.worker = thread.create_and_start_with_data(p,session_test_logind_run)
	if !testing.expect(t,p.worker != nil) { db.cancel(&p.slot); db.close(&p.bus); return false }
	s.path = strings.clone("/Session")
	if !testing.expect(t,db.open(&s.bus,s.display)) { session_test_logind_stop(p); return false }
	return true
}
session_test_logind_stop :: proc(p: ^Session_Test_Logind) {
	sync.atomic_store(&p.stop,true); thread.join(p.worker); thread.destroy(p.worker)
	db.cancel(&p.slot); db.close(&p.bus)
}
@(test)
session_gone_does_not_pause_and_closes_without_release :: proc(t: ^testing.T) {
	display := wl.create(); defer wl.destroy(display)
	s := new(Session); s.ctx,s.display,s.active,s.property_active = context,display,true,true
	wl.signal_init(&s.events.active); wl.signal_init(&s.events.device_gone); wl.signal_init(&s.events.destroy); defer session_destroy(s)
	o: Session_Observer; wl.listen(&s.events.active,&o.listener,session_observe); defer { wl.unlisten(&o.listener); delete(o.values) }
	peer: Session_Test_Logind; if !session_test_logind_start(t,&peer,s,&o) { return }; defer session_test_logind_stop(&peer)
	s.controlled = true; defer s.controlled = false
	for minor in ([]u32{9,14}) {
		fds: [2]linux.Fd
		if !testing.expect_value(t,linux.pipe2(&fds,{.CLOEXEC,.NONBLOCK}),linux.Errno.NONE) { return }
		defer linux.close(fds[1])
		d := new(Session_Device); d^ = {fd=i32(fds[0]),major=13,minor=minor}; append(&s.devices,d)
		if minor == 9 { session_close(s,d.fd) }
		session_queue(s,Session_Event{kind=.Pause,major=13,minor=minor,gone=true}); wl.dispatch(display,0)
		testing.expect(t,s.active); testing.expect_value(t,len(o.values),0); testing.expect_value(t,len(s.devices),0)
		if minor == 14 {
			testing.expect(t,d.gone); testing.expect_value(t,len(s.gone_devices),1)
			_,err := linux.fcntl(fds[0],linux.F_GETFD); testing.expect_value(t,err,linux.Errno.NONE)
			session_close(s,d.fd); testing.expect_value(t,len(s.gone_devices),0)
		}
		_,err := linux.fcntl(fds[0],linux.F_GETFD); testing.expect_value(t,err,linux.Errno.EBADF)
	}
	testing.expect_value(t,sync.atomic_load(&peer.releases),1); testing.expect_value(t,sync.atomic_load(&peer.acks),0)
	session_queue(s,Session_Event{kind=.Pause,major=13,minor=9,acknowledge=true}); wl.dispatch(display,0)
	testing.expect(t,s.active); testing.expect_value(t,len(o.values),0); testing.expect_value(t,sync.atomic_load(&peer.acks),0)
}
@(test)
session_resume_only_unpauses_its_device :: proc(t: ^testing.T) {
	display := wl.create(); defer wl.destroy(display)
	s := new(Session); s.ctx,s.display,s.active,s.property_active = context,display,true,true
	wl.signal_init(&s.events.active); wl.signal_init(&s.events.device_gone); wl.signal_init(&s.events.destroy); defer session_destroy(s)
	o: Session_Observer; wl.listen(&s.events.active,&o.listener,session_observe); defer { wl.unlisten(&o.listener); delete(o.values) }
	fds: [2]linux.Fd
	if !testing.expect_value(t,linux.pipe2(&fds,{.CLOEXEC,.NONBLOCK}),linux.Errno.NONE) { return }
	for fd,i in fds {
		d := new(Session_Device); d^ = {fd=i32(fd),major=226,minor=u32(i)}; append(&s.devices,d)
		session_queue(s,Session_Event{kind=.Pause,major=226,minor=u32(i)})
	}
	wl.dispatch(display,0); testing.expect(t,!s.active); testing.expect_value(t,len(o.values),1)
	for fd,i in fds {
		copy,err := linux.fcntl(fd,linux.F_DUPFD_CLOEXEC,0)
		if !testing.expect_value(t,err,linux.Errno.NONE) { return }
		session_queue(s,Session_Event{kind=.Resume,major=226,minor=u32(i),fd=i32(copy)}); wl.dispatch(display,0)
		testing.expect_value(t,s.active,i == 1); testing.expect_value(t,len(o.values),i+1)
		testing.expect(t,!s.devices[i].paused)
	}
}
@(test)
session_gone_card_fails_backend_without_active_signal :: proc(t: ^testing.T) {
	display := wl.create(); defer wl.destroy(display)
	s := new(Session); s.ctx,s.display,s.active,s.property_active = context,display,true,true
	wl.signal_init(&s.events.active); wl.signal_init(&s.events.device_gone); wl.signal_init(&s.events.destroy); defer session_destroy(s)
	o: Session_Observer; wl.listen(&s.events.active,&o.listener,session_observe); defer { wl.unlisten(&o.listener); delete(o.values) }
	fds: [2]linux.Fd
	if !testing.expect_value(t,linux.pipe2(&fds,{.CLOEXEC,.NONBLOCK}),linux.Errno.NONE) { return }; defer linux.close(fds[1])
	d := new(Session_Device); d^ = {fd=i32(fds[0]),major=226,minor=1}; append(&s.devices,d)
	drm := DRM{base={display=display,session=s,drm_fd=d.fd}}
	wl.listen(&s.events.device_gone,&drm.device_gone,drm_device_gone); defer wl.unlisten(&drm.device_gone)
	append(&s.pending,Session_Event{kind=.Pause,major=226,minor=1,gone=true}); session_dispatch(s)
	testing.expect(t,s.active); testing.expect_value(t,len(o.values),0); testing.expect(t,d.gone)
	testing.expect_value(t,len(s.devices),0); testing.expect(t,drm.failure != nil); wl.remove_source(drm.failure)
}
