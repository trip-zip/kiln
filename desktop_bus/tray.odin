package desktop_bus

import "base:runtime"
import "core:strings"
import "core:fmt"
import db "../dbus"
import images "../images"
import vm "../lua_runtime"

Item :: struct {
    services:^Services,
    service,path,owner:string,
    pending:^db.Slot,
    step:int,
    order:u64,
    again,ready:bool,
    present:[4]bool,
    id,title,status,icon:string,
    pixels:[]u32,
    width,height:i32,
}
PROPERTIES := [5]string{"Id","Title","Status","IconName","IconPixmap"}
find_item :: proc(s:^Services,service:string) -> ^Item { for it in s.items { if it.service==service { return it } };return nil }
clear_facts :: proc(it:^Item) { delete(it.id);delete(it.title);delete(it.status);delete(it.icon);delete(it.pixels);it.id="";it.title="";it.status="";it.icon="";it.pixels=nil;it.width=0;it.height=0;it.present={} }
watcher_signal :: proc(s:^Services,member:cstring,service:string="") {
    m:=db.signal(&s.bus,WATCHER_PATH,WATCHER,member);defer db.unref(m)
    if service!="" { db.put_string(m,service) }
    db.send(&s.bus,m)
}
remove_item :: proc(s:^Services,it:^Item,signal:bool) {
    db.cancel(&it.pending)
    for entry,i in s.items { if entry==it { ordered_remove(&s.items,i);break } }
    s.emit(s.data,vm.Event{class="tray",name="gone",service=it.service})
    key:=fmt.aprintf("tray:%s",it.service);images.forget(s.images,key);delete(key)
    if signal { watcher_signal(s,"StatusNotifierItemUnregistered",it.service) }
    clear_facts(it);delete(it.service);delete(it.path);delete(it.owner);free(it)
}
add_item :: proc(s:^Services,service,path:string) {
    if it:=find_item(s,service);it!=nil { refresh(it);return }
    if len(s.items)>=256 { return }
    s.next_item+=1
    it:=new(Item);it^={services=s,service=strings.clone(service),path=strings.clone(path),step=-1,order=s.next_item}
    // The watcher's public property is newest-first, independently of Lua presentation.
    append(&s.items,it)
    for i:=len(s.items)-1;i>0;i-=1 { s.items[i]=s.items[i-1] };s.items[0]=it
    m:=db.method(&s.bus,"org.freedesktop.DBus","/org/freedesktop/DBus","org.freedesktop.DBus","GetNameOwner")
    defer db.unref(m)
    if m==nil { remove_item(s,it,true);return }
    db.put_string(m,service)
    if !db.call(&s.bus,m,&it.pending,owner_reply,it) { remove_item(s,it,true) }
}
owner_reply :: proc "c" (m:^db.Message,data:rawptr,err:^db.Error) -> i32 {
    context=runtime.default_context()
    it:=(^Item)(data);db.cancel(&it.pending)
    owner,ok:=db.read_string(m)
    if db.failed(m) || !ok || owner=="" { remove_item(it.services,it,true);return 1 }
    it.owner=strings.clone(owner);it.step=0;refresh(it)
    return 1
}
refresh :: proc(it:^Item) {
    if it.pending!=nil { it.again=true;return }
    if it.owner=="" { return }
    clear_facts(it);it.step=0;it.again=false
    read_property(it)
}
read_property :: proc(it:^Item) {
    s:=it.services
    if it.step==len(PROPERTIES) {
        if it.again { refresh(it);return }
        key:=fmt.aprintf("tray:%s",it.service);defer delete(key)
        icon:=it.icon
        has_icon:=it.present[3]
        if len(it.pixels)>0 && images.put_argb(s.images,key,it.width,it.height,it.pixels) { icon=key;has_icon=true }
        else { images.forget(s.images,key) }
        it.ready=true
        s.emit(s.data,vm.Event{class="tray",name="item",id=it.order,service=it.service,item_id=it.id,title=it.title,status=it.status,icon=icon,item_has_id=it.present[0],item_has_title=it.present[1],item_has_status=it.present[2],item_has_icon=has_icon})
        clear_facts(it)
        return
    }
    m:=db.method(&s.bus,it.owner,it.path,"org.freedesktop.DBus.Properties","Get");defer db.unref(m)
    if m==nil { it.step+=1;read_property(it);return }
    db.put_string(m,ITEM);db.put_string(m,PROPERTIES[it.step])
    if !db.call(&s.bus,m,&it.pending,property_reply,it) { it.step+=1;read_property(it) }
}
property_reply :: proc "c" (m:^db.Message,data:rawptr,err:^db.Error) -> i32 {
    context=runtime.default_context()
    it:=(^Item)(data);db.cancel(&it.pending)
    // Calls address the unique owner; cancellation retires the userdata before reuse.
    if !db.failed(m) && db.sender(m)==it.owner {
        if it.step<4 && db.peek(m)=="s" && db.enter(m,'v',"s")>0 {
            text,ok:=db.read_string(m)
            it.present[it.step]=ok
            switch it.step { case 0:it.id=strings.clone(text);case 1:it.title=strings.clone(text);case 2:it.status=strings.clone(text);case 3:it.icon=strings.clone(text) }
        } else if it.step==4 && db.peek(m)=="a(iiay)" && db.enter(m,'v',"a(iiay)")>0 { read_pixmaps(it,m) }
    }
    it.step+=1;read_property(it)
    return 1
}
read_pixmaps :: proc(it:^Item,m:^db.Message) {
    if db.enter(m,'a',"(iiay)")<=0 { return }
    for db.enter(m,'r',"iiay")>0 {
        w,h:i32;db.read(m,'i',&w);db.read(m,'i',&h);bytes:=db.bytes(m)
        if w>0 && h>0 && w<=4096 && h<=4096 && i64(w)*i64(h)<=MAX_PIXELS && i64(w)*i64(h)*4==i64(len(bytes)) && i64(w)*i64(h)>i64(it.width)*i64(it.height) {
            delete(it.pixels);it.pixels=make([]u32,int(w)*int(h));it.width,it.height=w,h
            for &p,i in it.pixels { j:=i*4;p=u32(bytes[j])<<24 | u32(bytes[j+1])<<16 | u32(bytes[j+2])<<8 | u32(bytes[j+3]) }
        }
        db.leave(m)
    }
    db.leave(m)
}
owner_changed :: proc "c" (m:^db.Message,data:rawptr,err:^db.Error) -> i32 {
    context=runtime.default_context()
    s:=(^Services)(data)
    name,_:=db.read_string(m);old,_:=db.read_string(m);owner,_:=db.read_string(m)
    if old=="" { return 0 }
    // A well-known name may change owners without an intermediate empty owner.
    if len(name)>0 && name[0]!=':' {
        if it:=find_item(s,name);it!=nil {
            path:=strings.clone(it.path)
            remove_item(s,it,true)
            if owner!="" { add_item(s,name,path);watcher_signal(s,"StatusNotifierItemRegistered",name) }
            delete(path)
        }
    } else {
        for i:=len(s.items)-1;i>=0;i-=1 {
            it:=s.items[i]
            if it.service==name || it.owner==name { remove_item(s,it,true) }
        }
    }
    return 0
}
item_changed :: proc "c" (m:^db.Message,data:rawptr,err:^db.Error) -> i32 {
    context=runtime.default_context()
    s:=(^Services)(data)
    for it in s.items { if it.owner==db.sender(m) && it.path==db.path(m) { refresh(it) } }
    return 0
}
register_item :: proc "c" (m:^db.Message,data:rawptr,err:^db.Error) -> i32 {
    context=runtime.default_context()
    s:=(^Services)(data)
    arg,ok:=db.read_string(m);if !ok { return -22 }
    if db.member(m)=="RegisterStatusNotifierHost" { watcher_signal(s,"StatusNotifierHostRegistered") }
    else {
        service,path:=arg,"/StatusNotifierItem"
        if len(arg)>0 && arg[0]=='/' { service,path=db.sender(m),arg }
        if !db.valid_service(service) || !db.valid_path(path) { return -22 }
        add_item(s,service,path);watcher_signal(s,"StatusNotifierItemRegistered",service)
    }
    r:=db.reply(m);defer db.unref(r);db.send(&s.bus,r);return 1
}
watcher_property :: proc "c" (bus:^db.Handle,path,iface,property:cstring,reply:^db.Message,data:rawptr,err:^db.Error) -> i32 {
    context=runtime.default_context()
    s:=(^Services)(data)
    switch string(property) {
    case "RegisteredStatusNotifierItems":db.begin(reply,'a',"s");for it in s.items { db.put_string(reply,it.service) };db.end(reply)
    case "IsStatusNotifierHostRegistered":db.put_bool(reply,true)
    case "ProtocolVersion":db.put_i32(reply,0)
    }
    return 1
}
activate :: proc(s:^Services,service,kind:string,a:i32,b:string) {
    it:=find_item(s,service)
    if it==nil || it.owner=="" || !it.ready { return }
    method:=kind=="scroll" ? "Scroll" : kind=="secondary" ? "SecondaryActivate" : "Activate"
    m:=db.method(&s.bus,it.owner,it.path,ITEM,method);if m==nil { return };defer db.unref(m)
    db.put_i32(m,a)
    if kind=="scroll" { db.put_string(m,b) } else { db.put_i32(m,0) }
    db.forget_reply(m);db.send(&s.bus,m)
}
