package dbus

import "base:runtime"
import "core:testing"
import "core:os"
import wl "../wayland"

Test_Peer :: struct { bus: Bus, slot, match_slot, pending: ^Slot, calls, signals, replies, errors: int }
echo :: proc "c" (m:^Message,data:rawptr,err:^Error) -> i32 {
    context=runtime.default_context()
    p:=(^Test_Peer)(data);p.calls+=1
    if member(m)=="Stall" { return 1 }
    s,_:=read_string(m)
    r:=reply(m);defer unref(r);put_string(r,s);send(&p.bus,r)
    return 1
}
got_reply :: proc "c" (m:^Message,data:rawptr,err:^Error) -> i32 {
    context=runtime.default_context()
    p:=(^Test_Peer)(data);p.replies+=1
    if failed(m) { p.errors+=1 }
    cancel(&p.pending)
    return 1
}
got_signal :: proc "c" (m:^Message,data:rawptr,err:^Error) -> i32 {
    context=runtime.default_context()
    p:=(^Test_Peer)(data);p.signals+=1
    return 0
}
@(test)
private_roundtrip :: proc(t:^testing.T) {
    address:=os.get_env("DBUS_SESSION_BUS_ADDRESS",context.allocator);defer delete(address)
    testing.expect(t,address!="","run under dbus-run-session")
    if address=="" { return }
    d:=wl.create();defer wl.destroy(d)
    a,b:Test_Peer
    testing.expect(t,open(&a.bus,d));defer close(&a.bus)
    testing.expect(t,open(&b.bus,d));defer close(&b.bus)
    defer { cancel(&a.slot);cancel(&b.match_slot);cancel(&b.pending) }
    testing.expect(t,request_name(&a.bus,"org.kiln.BoundaryTest"))
    testing.expect(t,!request_name(&b.bus,"org.kiln.BoundaryTest"))
    table:=[]Vtable{vstart(),vmethod("Echo","s","s",echo),vmethod("Stall","","",echo),vsignal("Changed",""),vend()}
    testing.expect(t,register(&a.bus,&a.slot,"/Test","org.kiln.Test",table,&a))
    testing.expect(t,match(&b.bus,&b.match_slot,"type='signal',interface='org.kiln.Test'",got_signal,&b))
    m:=method(&b.bus,"org.kiln.BoundaryTest","/Test","org.kiln.Test","Echo")
    put_string(m,"wire");testing.expect(t,call(&b.bus,m,&b.pending,got_reply,&b));unref(m)
    deadline:=now_usec()+2000000
    for b.replies<1 && now_usec()<deadline { wl.dispatch(d,10) }
    testing.expect_value(t,b.replies,1);testing.expect_value(t,b.errors,0);testing.expect_value(t,a.calls,1)
    s:=signal(&a.bus,"/Test","org.kiln.Test","Changed");send(&a.bus,s);unref(s)
    for b.signals<1 && now_usec()<deadline { wl.dispatch(d,10) }
    testing.expect_value(t,b.signals,1)
    m=method(&b.bus,"org.kiln.BoundaryTest","/Test","org.kiln.Test","Stall")
    testing.expect(t,call(&b.bus,m,&b.pending,got_reply,&b));unref(m)
    deadline=now_usec()+2000000
    for b.pending!=nil && now_usec()<deadline { wl.dispatch(d,10) }
    testing.expect_value(t,b.errors,1);testing.expect(t,b.pending==nil)
    m=method(&b.bus,"org.kiln.BoundaryTest","/Test","org.kiln.Test","Stall")
    testing.expect(t,call(&b.bus,m,&b.pending,got_reply,&b));unref(m);cancel(&b.pending)
    for _ in 0..<90 { wl.dispatch(d,10) }
    testing.expect_value(t,b.replies,2)
    before:=a.bus.dispatches+b.bus.dispatches
    for _ in 0..<10 { wl.dispatch(d,10) }
    testing.expect_value(t,a.bus.dispatches+b.bus.dispatches,before)
}
@(test)
deadline_and_vtable :: proc(t:^testing.T) {
    testing.expect_value(t,delay_ms(max(u64),4),i32(0))
    testing.expect_value(t,delay_ms(4,4),i32(1))
    testing.expect_value(t,delay_ms(3,4),i32(1))
    testing.expect_value(t,delay_ms(max(u64)-1,0),max(i32))
    v:=vstart();testing.expect_value(t,v.header,u64(0x3c));testing.expect_value(t,v.x.start.element_size,uint(56))
    testing.expect_value(t,v.x.start.features,u64(1));testing.expect_value(t,v.x.start.vtable_format_reference^,u32(242))
    testing.expect_value(t,vmethod("x","","",echo).header,u64(0x44d))
}
