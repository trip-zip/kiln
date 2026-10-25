package backend

import wl "../wayland"
import "core:fmt"
import "core:strings"
import "core:sys/linux"

Hotplug :: struct { backend: ^DRM, source: ^wl.Source, fd: linux.Fd }
Netlink_Address :: struct { family, padding: u16, pid, groups: u32 }
#assert(size_of(Netlink_Address) == 12 && align_of(Netlink_Address) == 4 && offset_of(Netlink_Address,family) == 0 && offset_of(Netlink_Address,pid) == 4 && offset_of(Netlink_Address,groups) == 8)
hotplug_create :: proc(drm: ^DRM) -> ^Hotplug {
	fd,err := linux.socket(.NETLINK,.DGRAM,{.CLOEXEC,.NONBLOCK},linux.Protocol(15)); if err != .NONE { return nil }
	address := Netlink_Address{family=u16(linux.Address_Family.NETLINK),groups=1}
	if linux.syscall(linux.SYS_bind,uintptr(fd),uintptr(&address),size_of(address)) < 0 { linux.close(fd); return nil }
	h := new(Hotplug); h.backend,h.fd = drm,fd
	h.source = wl.loop_on_fd(drm.base.loop,i32(fd),{.Readable},hotplug_ready,h)
	if h.source == nil { hotplug_destroy(h); return nil }; return h
}
uevent_value :: proc(bytes: []u8, key: string) -> string {
	for field in strings.split(string(bytes),"\x00",context.temp_allocator) {
		if len(field) > len(key) && field[:len(key)] == key && field[len(key)] == '=' { return field[len(key)+1:] }
	}; return ""
}
hotplug_event :: proc(h: ^Hotplug, bytes: []u8) {
	drm := h.backend; subsystem := uevent_value(bytes,"SUBSYSTEM")
	if subsystem == "drm" {
		if uevent_value(bytes,"HOTPLUG") != "1" { return }
		path := uevent_value(bytes,"DEVPATH"); card := drm.path[len("/dev/dri/"):]
		suffix := fmt.tprintf("/drm/%s",card)
		if !strings.has_suffix(path,suffix) && !strings.contains(path,fmt.tprintf("%s/",suffix)) { return }
		if session_active(drm.base.session) && drm.base.started && !drm_scan(drm) { drm_failed(drm) }
	} else if subsystem == "input" && drm.input != nil {
		name := uevent_value(bytes,"DEVNAME")
		if !strings.has_prefix(name,"input/") || !input_event_name(name[6:]) { return }
		path := fmt.tprintf("/dev/%s",name)
		switch uevent_value(bytes,"ACTION") { case "add": if session_active(drm.base.session) { input_add(drm.input,path) }; case "remove": input_remove(drm.input,path) }
		input_ready(0,{},drm.input)
	}
}
hotplug_ready :: proc(fd: i32, mask: wl.Mask, data: rawptr) -> i32 {
	h := cast(^Hotplug)data
	if mask&{.Hangup,.Error} != {} { drm_failed(h.backend); return 0 }
	for {
		bytes: [16384]u8; address: Netlink_Address; size := u32(size_of(address))
		n := linux.syscall(linux.SYS_recvfrom,uintptr(fd),uintptr(&bytes[0]),len(bytes),32,uintptr(&address),uintptr(&size))
		if n == -int(linux.Errno.EAGAIN) { break }
		if n == -int(linux.Errno.ENOBUFS) { if session_active(h.backend.base.session) { if !drm_scan(h.backend) { drm_failed(h.backend) }; input_scan(h.backend.input) }; continue }
		if n < 0 || n > len(bytes) { if n < 0 { drm_failed(h.backend); break }; continue }
		if n > 0 && size == size_of(address) && address.pid == 0 { hotplug_event(h,bytes[:n]) }
	}; return 0
}
hotplug_destroy :: proc(h: ^Hotplug) { if h == nil { return }; wl.remove_source(h.source); linux.close(h.fd); free(h) }
