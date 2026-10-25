package wayland

import "core:testing"
import "core:sys/linux"

proxy_test_event :: proc(c: ^Remote, id, opcode: u32, values: []u32) {
	bytes: [64]u8
	word_write(bytes[:],0,id); word_write(bytes[:],4,u32(8+4*len(values))<<16|opcode)
	for value,i in values { word_write(bytes[:],8+4*i,value) }
	ring_put(&c.wire.input,bytes[:8+4*len(values)])
}
@(test)
proxy_recycles_only_acknowledged_ids_and_discards_late_events :: proc(t: ^testing.T) {
	a,b := pair_open(t)
	defer connection_close(&b)
	c := remote_adopt(nil,a.fd)
	defer remote_close(c)
	types: [1]^Interface
	events := [1]Message{{"done","u",&types[0]}}
	iface := Interface{name="callback",version=1,event_count=1,events=&events[0]}
	calls := 0
	p := proxy_new(c,&iface,1,proc(p: ^Proxy, op: u32, args: []Argument) { (cast(^int)p.data)^ += 1 },&calls)
	id := p.id
	proxy_release(p)
	q := proxy_new(c,&iface,1)
	testing.expect(t,q.id != id)
	proxy_test_event(c,id,0,[]u32{9})
	testing.expect(t,remote_dispatch(c) && calls == 0)
	// A local display interface keeps this test independent of protocol bootstrap order.
	display_events := [2]Message{{"error","",&types[0]},{"delete_id","u",&types[0]}}
	display := Interface{name="wl_display",version=1,event_count=2,events=&display_events[0]}
	c.objects[1].interface = &display
	proxy_test_event(c,1,1,[]u32{id})
	testing.expect(t,remote_dispatch(c))
	r := proxy_new(c,&iface,1)
	testing.expect_value(t,r.id,id)
	proxy_test_event(c,1,1,[]u32{q.id})
	testing.expect(t,!remote_dispatch(c) && c.failed)
}
@(test)
proxy_checks_event_version_and_waits_for_complete_frames :: proc(t: ^testing.T) {
	for version: u32 = 1; version <= 2; version += 1 {
		a,b := pair_open(t)
		defer connection_close(&b)
		c := remote_adopt(nil,a.fd)
		defer remote_close(c)
		types: [1]^Interface
		events := [1]Message{{"new_event","2u",&types[0]}}
		iface := Interface{name="test",version=2,event_count=1,events=&events[0]}
		got: u32
		p := proxy_new(c,&iface,version,proc(p: ^Proxy,op: u32,args: []Argument) { (cast(^u32)p.data)^ = u32(args[0].(Uint)) },&got)
		bytes: [12]u8
		word_write(bytes[:],0,p.id); word_write(bytes[:],4,12<<16); word_write(bytes[:],8,71)
		ring_put(&c.wire.input,bytes[:8])
		testing.expect(t,remote_dispatch(c) && got == 0)
		ring_put(&c.wire.input,bytes[8:])
		testing.expect(t,remote_dispatch(c) == (version == 2))
		testing.expect_value(t,got,71 if version == 2 else 0)
	}
}
@(test)
proxy_closes_inside_listener_without_using_freed_objects :: proc(t: ^testing.T) {
	a,b := pair_open(t)
	defer connection_close(&b)
	c := remote_adopt(nil,a.fd)
	types: [1]^Interface
	events := [1]Message{{"done","",&types[0]}}
	iface := Interface{name="callback",version=1,event_count=1,events=&events[0]}
	p := proxy_new(c,&iface,1,proc(p: ^Proxy,op: u32,args: []Argument) { remote_close(p.remote) })
	proxy_test_event(c,p.id,0,nil)
	proxy_test_event(c,p.id,0,nil)
	testing.expect(t,!remote_dispatch(c))
	_, err := linux.fcntl(a.fd,linux.F_GETFD)
	testing.expect_value(t,err,.EBADF)
}
@(test)
proxy_requests_duplicate_fds_and_ignored_events_close_theirs :: proc(t: ^testing.T) {
	a,b := pair_open(t)
	defer connection_close(&b)
	c := remote_adopt(nil,a.fd)
	defer remote_close(c)
	types: [1]^Interface
	messages := [1]Message{{"file","h",&types[0]}}
	iface := Interface{name="test",version=1,method_count=1,methods=&messages[0],event_count=1,events=&messages[0]}
	p := proxy_new(c,&iface,1)
	pipe: [2]linux.Fd
	linux.pipe2(&pipe,{.CLOEXEC})
	defer linux.close(pipe[0]); defer linux.close(pipe[1])
	testing.expect(t,proxy_request(p,0,Fd(pipe[1])))
	n,err := connection_read(&b)
	testing.expect(t,n == 8 && err == .NONE)
	fd := fd_take(&b.fds_in)
	fd_put(&c.wire.fds_in,fd)
	proxy_test_event(c,p.id,0,nil)
	testing.expect(t,remote_dispatch(c))
	_, closed := linux.fcntl(fd,linux.F_GETFD)
	testing.expect_value(t,closed,.EBADF)
	_, alive := linux.fcntl(pipe[1],linux.F_GETFD)
	testing.expect_value(t,alive,.NONE)
}
