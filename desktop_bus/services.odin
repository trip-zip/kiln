package desktop_bus

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import db "../dbus"
import images "../images"
import vm "../lua_runtime"
import wl "../wayland"

NOTIFY :: "org.freedesktop.Notifications"
NOTIFY_PATH :: "/org/freedesktop/Notifications"
WATCHER :: "org.kde.StatusNotifierWatcher"
WATCHER_PATH :: "/StatusNotifierWatcher"
ITEM :: "org.kde.StatusNotifierItem"
Services :: struct {
    bus:db.Bus,
    notify_slot,watcher_slot,owner_slot,item_slot:^db.Slot,
    notify_table:[8]db.Vtable,
    watcher_table:[10]db.Vtable,
    next_id:u32,
    next_item:u64,
    items:[dynamic]^Item,
    images:^images.Cache,
    emit:proc(rawptr,vm.Event),
    data:rawptr,
}
init :: proc(s:^Services,display:^wl.Display) {
    s.bus.data=s;s.bus.lost=lost
    if !db.open(&s.bus,display) { return }
    s.notify_table={db.vstart(),db.vmethod("Notify","susssasa{sv}i","u",notify_method),db.vmethod("CloseNotification","u","",notify_method),db.vmethod("GetCapabilities","","as",notify_method),db.vmethod("GetServerInformation","","ssss",notify_method),db.vsignal("NotificationClosed","uu"),db.vsignal("ActionInvoked","us"),db.vend()}
    if db.request_name(&s.bus,NOTIFY) {
        if !db.register(&s.bus,&s.notify_slot,NOTIFY_PATH,NOTIFY,s.notify_table[:],s) { fmt.eprintln("notify: cannot register object") }
    } else { fmt.eprintln("notify: name occupied; notifications disabled") }
    s.watcher_table={db.vstart(),db.vmethod("RegisterStatusNotifierItem","s","",register_item),db.vmethod("RegisterStatusNotifierHost","s","",register_item),db.vproperty("RegisteredStatusNotifierItems","as",watcher_property,true),db.vproperty("IsStatusNotifierHostRegistered","b",watcher_property),db.vproperty("ProtocolVersion","i",watcher_property),db.vsignal("StatusNotifierItemRegistered","s"),db.vsignal("StatusNotifierItemUnregistered","s"),db.vsignal("StatusNotifierHostRegistered",""),db.vend()}
    if db.request_name(&s.bus,WATCHER) {
        if db.register(&s.bus,&s.watcher_slot,WATCHER_PATH,WATCHER,s.watcher_table[:],s) {
            host:=fmt.aprintf("org.kde.StatusNotifierHost-%d",os.get_pid());db.request_name(&s.bus,host);delete(host)
            if !db.match(&s.bus,&s.owner_slot,"type='signal',sender='org.freedesktop.DBus',path='/org/freedesktop/DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'",owner_changed,s) ||
               !db.match(&s.bus,&s.item_slot,"type='signal',interface='org.kde.StatusNotifierItem'",item_changed,s) { lost(s) }
        }
    } else { fmt.eprintln("tray: name occupied; watcher disabled") }
    db.wake(&s.bus)
}
lost :: proc(data:rawptr) {
    s:=(^Services)(data)
    for len(s.items)>0 { remove_item(s,s.items[0],false) }
    db.cancel(&s.owner_slot);db.cancel(&s.item_slot);db.cancel(&s.notify_slot);db.cancel(&s.watcher_slot)
}
destroy :: proc(s:^Services) { lost(s);delete(s.items);db.close(&s.bus) }
notify_closed :: proc(s:^Services,id:u32,reason:i32) {
    key:=fmt.aprintf("notify:%d",id);images.forget(s.images,key);delete(key)
    if s.notify_slot==nil { return }
    m:=db.signal(&s.bus,NOTIFY_PATH,NOTIFY,"NotificationClosed");defer db.unref(m)
    db.put_u32(m,id);db.put_u32(m,u32(reason));db.send(&s.bus,m)
}
notify_action :: proc(s:^Services,id:u32,key:string) {
    if s.notify_slot==nil { return }
    m:=db.signal(&s.bus,NOTIFY_PATH,NOTIFY,"ActionInvoked");defer db.unref(m)
    db.put_u32(m,id);db.put_string(m,key);db.send(&s.bus,m)
}
notify_method :: proc "c" (m:^db.Message,data:rawptr,err:^db.Error) -> i32 {
    context=runtime.default_context()
    s:=(^Services)(data)
    r:=db.reply(m);defer db.unref(r)
    switch db.member(m) {
    case "GetServerInformation": for v in ([]string{"kiln","kiln","0.1","1.2"}) { db.put_string(r,v) }
    case "GetCapabilities": db.begin(r,'a',"s");for v in ([]string{"body","actions","icon-static"}) { db.put_string(r,v) };db.end(r)
    case "CloseNotification": id:u32;if db.read(m,'u',&id)<=0 { return -22 };s.emit(s.data,vm.Event{class="notify",name="close",id=u64(id)})
    case "Notify":
        n:vm.Notification
        n.app,_=db.read_string(m)
        if db.read(m,'u',&n.replaces)<=0 { return -22 }
        n.app_icon,_=db.read_string(m);n.summary,_=db.read_string(m);n.body,_=db.read_string(m)
        if n.replaces!=0 { n.id=n.replaces } else {
            if s.next_id==max(u32) { return -75 };s.next_id+=1;n.id=s.next_id
        }
        if db.enter(m,'a',"s")<=0 { return -22 }
        for {
            key,ok:=db.read_string(m);if !ok { break }
            label,has_label:=db.read_string(m);if !has_label { label=key }
            append(&n.actions,vm.Action{key,label})
        }
        defer delete(n.actions)
        db.leave(m)
        read_hints(s,m,&n)
        defer delete(n.hints)
        defer delete(n.image)
        if db.read(m,'i',&n.timeout)<=0 { return -22 }
        if n.image=="" {
            key:=fmt.aprintf("notify:%d",n.id);images.forget(s.images,key);delete(key)
        }
        s.emit(s.data,vm.Event{class="notify",name="notify",notification=&n})
        db.put_u32(r,n.id)
    }
    db.send(&s.bus,r);return 1
}
read_hints :: proc(s:^Services,m:^db.Message,n:^vm.Notification) {
    if db.enter(m,'a',"{sv}")<=0 { return }
    for db.enter(m,'e',"sv")>0 {
        key,_:=db.read_string(m);signature:=db.peek(m)
        if db.enter(m,'v',nil)<=0 { return }
        if key=="urgency" && signature=="y" {
            level:u8;db.read(m,'y',&level)
            levels:=[3]string{"low","normal","critical"};if level<3 { n.urgency=levels[level] }
        } else if (key=="image-data" || key=="image_data" || key=="icon_data") && signature=="(iiibiiay)" {
            if db.enter(m,'r',"iiibiiay")>0 {
                w,h,stride,alpha,bits,channels:i32
                db.read(m,'i',&w);db.read(m,'i',&h);db.read(m,'i',&stride);db.read(m,'b',&alpha);db.read(m,'i',&bits);db.read(m,'i',&channels)
                pixels:=db.bytes(m)
                decoded:=decode_inline(w,h,stride,alpha!=0,bits,channels,pixels)
                if len(decoded)>0 {
                    image:=fmt.aprintf("notify:%d",n.id)
                    if images.put_argb(s.images,image,w,h,decoded) { delete(n.image);n.image=image } else { delete(image) }
                    delete(decoded)
                }
                db.leave(m)
            }
        } else if hint,ok:=read_scalar(m,key,signature);ok { append(&n.hints,hint) }
        else { db.skip(m) }
        db.leave(m);db.leave(m)
    }
    db.leave(m)
}
read_scalar :: proc(m:^db.Message,key,signature:string) -> (h:vm.Hint,ok:bool) {
    h.key=key
    if len(signature)!=1 { return }
    v:struct #raw_union { s:cstring,b:i32,y:u8,n:i16,q:u16,i:i32,u:u32,x:i64,t:u64,d:f64 }
    if !strings.contains("sogbynqiuxtd",signature) { return }
    if db.read(m,signature[0],&v)<=0 { return }
    ok=true;h.kind=.Number
    switch signature[0] {
    case 's','o','g':h.kind=.Text;h.text=string(v.s)
    case 'b':h.kind=.Boolean;h.boolean=v.b!=0
    case 'y':h.number=f64(v.y)
    case 'n':h.number=f64(v.n)
    case 'q':h.number=f64(v.q)
    case 'i':h.number=f64(v.i)
    case 'u':h.number=f64(v.u)
    case 'x':h.number=f64(v.x)
    case 't':h.number=f64(v.t)
    case 'd':h.number=v.d
    }
    return
}
// Bound protocol images before multiplication, allocation or reading a row.
MAX_PIXELS :: 4*1024*1024
decode_inline :: proc(w,h,stride:i32,alpha:bool,bits,channels:i32,pixels:[]u8) -> []u32 {
    if w<=0 || h<=0 || w>4096 || h>4096 || i64(w)*i64(h)>MAX_PIXELS || bits!=8 || channels!=(alpha ? 4 : 3) || i64(stride)<i64(w)*i64(channels) { return nil }
    required:=i64(h-1)*i64(stride)+i64(w)*i64(channels)
    if required>i64(len(pixels)) || len(pixels)>16*1024*1024 { return nil }
    result:=make([]u32,int(w)*int(h))
    for y in 0..<int(h) { for x in 0..<int(w) {
        i:=y*int(stride)+x*int(channels);a:=alpha ? u32(pixels[i+3]) : 255
        result[y*int(w)+x]=a<<24 | u32(pixels[i])<<16 | u32(pixels[i+1])<<8 | u32(pixels[i+2])
    } }
    return result
}
