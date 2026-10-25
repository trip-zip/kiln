package dbus

import "core:time"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import raw "../sd_bus"
import wl "../wayland"

Bus :: struct {
    handle: ^raw.sd_bus,
    fd, timer: ^wl.Event_Source,
    lost: proc(rawptr),
    data: rawptr,
    allocator: runtime.Allocator,
    dispatches: u64,
    failed:bool,
}
Message :: raw.sd_bus_message
Slot :: raw.sd_bus_slot
Error :: raw.sd_bus_error
Handle :: raw.sd_bus
Handler :: raw.sd_bus_message_handler_t
Property_Get :: raw.sd_bus_property_get_t
Vtable :: raw.sd_bus_vtable

now_usec :: proc() -> u64 {
    ts: posix.timespec
    posix.clock_gettime(.MONOTONIC,&ts)
    return u64(ts.tv_sec)*1000000+u64(ts.tv_nsec)/1000
}
delay_ms :: proc(deadline, now: u64) -> i32 {
    if deadline==max(u64) { return 0 }
    if deadline<=now { return 1 }
    return i32(min(u64(max(i32)),(deadline-now)/1000+1))
}
close :: proc(b: ^Bus) {
    wl.remove_source(b.fd);b.fd=nil
    wl.remove_source(b.timer);b.timer=nil
    if b.handle!=nil { raw.sd_bus_close_unref(b.handle);b.handle=nil }
}
disconnected :: proc(b: ^Bus) {
    if b.handle==nil { return }
    fmt.eprintln("dbus: disconnected; services disabled until compositor restart")
    // Owners cancel slots while the connection still exists.
    if b.lost!=nil { b.lost(b.data) }
    close(b)
}
wake :: proc(b: ^Bus) {
    if b.handle==nil { return }
    events:=raw.sd_bus_get_events(b.handle)
    deadline:u64
    if events<0 || raw.sd_bus_get_timeout(b.handle,&deadline)<0 { b.failed=true;wl.arm_timer(b.timer, 1*time.Millisecond);return }
    mask:wl.Mask
    if events&1!=0 { mask+=wl.READABLE }
    if events&4!=0 { mask+=wl.WRITABLE }
    if !wl.update_fd(b.fd,mask) || !wl.arm_timer(b.timer, time.Duration(delay_ms(deadline,now_usec()))*time.Millisecond) { b.failed=true;wl.arm_timer(b.timer, 1*time.Millisecond) }
}
drain :: proc(b: ^Bus) {
    if b.failed { disconnected(b);return }
    b.dispatches+=1
    // Bound a dispatch turn so a noisy peer cannot starve frames or IPC.
    for _ in 0..<64 {
        result:=raw.sd_bus_process(b.handle,nil)
        if b.failed { disconnected(b);return }
        if result<0 { disconnected(b);return }
        if result==0 { wake(b);return }
    }
    wake(b)
    if b.timer!=nil { wl.arm_timer(b.timer, 1*time.Millisecond) }
}
readable :: proc(fd:i32,mask: wl.Mask,data:rawptr) -> i32 {
    b:=(^Bus)(data);context.allocator=b.allocator
    drain(b);return 0
}
timeout :: proc(data:rawptr) -> i32 {
    b:=(^Bus)(data);context.allocator=b.allocator
    drain(b);return 0
}
open :: proc(b:^Bus,display:^wl.Display, system := false) -> bool {
    b.allocator=context.allocator
    connect := raw.sd_bus_open_system if system else raw.sd_bus_open_user
    if connect(&b.handle)<0 { b.handle=nil;fmt.eprintf("dbus: %s bus unavailable\n", "system" if system else "session");return false }
    b.fd=wl.on_fd(display,raw.sd_bus_get_fd(b.handle),wl.READABLE,readable,b)
    b.timer=wl.on_timer(display,timeout,b)
    if b.fd==nil || b.timer==nil { close(b);return false }
    wake(b)
    return b.handle!=nil
}
request_name :: proc(b:^Bus,name:string) -> bool {
    z:=strings.clone_to_cstring(name);defer delete(z)
    // Zero flags neither queue nor replace another daemon.
    return b.handle!=nil && raw.sd_bus_request_name(b.handle,z,0)>0
}
register :: proc(b:^Bus,slot:^^Slot,path,iface:cstring,table:[]Vtable,data:rawptr) -> bool {
    return raw.sd_bus_add_object_vtable(b.handle,slot,path,iface,raw_data(table),data)>=0
}
match :: proc(b:^Bus,slot:^^Slot,rule:string,callback:Handler,data:rawptr) -> bool {
    z:=strings.clone_to_cstring(rule);defer delete(z)
    return raw.sd_bus_add_match(b.handle,slot,z,callback,data)>=0
}
cancel :: proc(slot:^^Slot) { if slot^!=nil { raw.sd_bus_slot_unref(slot^);slot^=nil } }
call :: proc(b:^Bus,m:^Message,slot:^^Slot,callback:Handler,data:rawptr) -> bool {
    raw.sd_bus_message_set_auto_start(m,0)
    ok:=raw.sd_bus_call_async(b.handle,slot,m,callback,data,750000)>=0
    wake(b);return ok
}
method :: proc(b:^Bus,destination,path,iface,member:string) -> ^Message {
    d:=strings.clone_to_cstring(destination);defer delete(d)
    p:=strings.clone_to_cstring(path);defer delete(p)
    i:=strings.clone_to_cstring(iface);defer delete(i)
    n:=strings.clone_to_cstring(member);defer delete(n)
    m:^Message
    if raw.sd_bus_message_new_method_call(b.handle,&m,d,p,i,n)<0 { return nil }
    return m
}
signal :: proc(b:^Bus,path,iface,member:cstring) -> ^Message {
    m:^Message
    if b.handle==nil || raw.sd_bus_message_new_signal(b.handle,&m,path,iface,member)<0 { return nil }
    return m
}
reply :: proc(m:^Message) -> ^Message { result:^Message;raw.sd_bus_message_new_method_return(m,&result);return result }
send :: proc(b:^Bus,m:^Message) -> i32 {
    if m==nil || b.handle==nil { return -1 }
    result:=raw.sd_bus_send(b.handle,m,nil)
    wake(b)
    return result
}
forget_reply :: proc(m:^Message) { raw.sd_bus_message_set_expect_reply(m,0);raw.sd_bus_message_set_auto_start(m,0) }
unref :: proc(m:^Message) { if m!=nil { raw.sd_bus_message_unref(m) } }
member :: proc(m:^Message) -> string { return string(raw.sd_bus_message_get_member(m)) }
sender :: proc(m:^Message) -> string { return string(raw.sd_bus_message_get_sender(m)) }
path :: proc(m:^Message) -> string { return string(raw.sd_bus_message_get_path(m)) }
failed :: proc(m:^Message) -> bool { return raw.sd_bus_message_is_method_error(m,nil)>0 }
read :: raw.sd_bus_message_read_basic
enter :: raw.sd_bus_message_enter_container
leave :: raw.sd_bus_message_exit_container
begin :: raw.sd_bus_message_open_container
end :: raw.sd_bus_message_close_container
skip :: proc(m:^Message) { raw.sd_bus_message_skip(m,nil) }
peek :: proc(m:^Message) -> string { t:u8;s:cstring;raw.sd_bus_message_peek_type(m,&t,&s);return string(s) }
read_string :: proc(m:^Message) -> (string,bool) { s:cstring;r:=read(m,'s',&s);return string(s),r>0 }
bytes :: proc(m:^Message) -> []u8 { p:rawptr;n:uint;if raw.sd_bus_message_read_array(m,'y',&p,&n)<=0 || n>16*1024*1024 { return nil };return ([^]u8)(p)[:int(n)] }
put_string :: proc(m:^Message,s:string) { z:=strings.clone_to_cstring(s);defer delete(z);raw.sd_bus_message_append_basic(m,'s',rawptr(z)) }
put_u32 :: proc(m:^Message,v:u32) { x:=v;raw.sd_bus_message_append_basic(m,'u',&x) }
put_i32 :: proc(m:^Message,v:i32) { x:=v;raw.sd_bus_message_append_basic(m,'i',&x) }
put_bool :: proc(m:^Message,v:bool) { x:=i32(v ? 1 : 0);raw.sd_bus_message_append_basic(m,'b',&x) }
valid_service :: proc(s:string) -> bool { z:=strings.clone_to_cstring(s);defer delete(z);return raw.sd_bus_service_name_is_valid(z)>0 }
valid_path :: proc(s:string) -> bool { z:=strings.clone_to_cstring(s);defer delete(z);return raw.sd_bus_object_path_is_valid(z)>0 }
vstart :: proc() -> Vtable { v:=Vtable{header=0x3c};v.x.start={56,1,&raw.sd_bus_object_vtable_format};return v }
vend :: proc() -> Vtable { return {header=0x3e} }
vmethod :: proc(name,input,output:cstring,handler:Handler) -> Vtable { v:=Vtable{header=0x44d};v.x.method={name,input,output,handler,0,""};return v }
vsignal :: proc(name,signature:cstring) -> Vtable { v:=Vtable{header=0x53};v.x.signal={name,signature,""};return v }
vproperty :: proc(name,signature:cstring,get:Property_Get,changes:=false) -> Vtable { v:=Vtable{header=changes ? 0x2050 : 0x1050};v.x.property={name,signature,get,nil,0};return v }
