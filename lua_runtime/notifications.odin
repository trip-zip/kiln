package lua_runtime

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sys/posix"
import lua "../luajit"

Action :: struct { key,label:string }
Hint :: struct { key,text:string, number:f64, boolean:bool, kind:enum { Text,Number,Boolean } }
Notification :: struct {
    id,replaces:u32,
    app,app_icon,summary,body,urgency,image:string,
    timeout:i32,
    actions:[dynamic]Action,
    hints:[dynamic]Hint,
}
clone_notification :: proc(n:^Notification) -> ^Notification {
    if n==nil { return nil }
    v:=new(Notification);v^=n^
    v.app,v.app_icon=strings.clone(n.app),strings.clone(n.app_icon)
    v.summary,v.body=strings.clone(n.summary),strings.clone(n.body)
    v.urgency,v.image=strings.clone(n.urgency),strings.clone(n.image)
    v.actions=nil;v.hints=nil
    for a in n.actions { append(&v.actions,Action{strings.clone(a.key),strings.clone(a.label)}) }
    for h in n.hints { h:=h;h.key,h.text=strings.clone(h.key),strings.clone(h.text);append(&v.hints,h) }
    return v
}
free_notification :: proc(n:^Notification) {
    if n==nil { return }
    delete(n.app);delete(n.app_icon);delete(n.summary);delete(n.body);delete(n.urgency);delete(n.image)
    for a in n.actions { delete(a.key);delete(a.label) };delete(n.actions)
    for h in n.hints { delete(h.key);delete(h.text) };delete(n.hints)
    free(n)
}
notification_fields :: proc(L:^lua.State,n:^Notification) {
    number(L,"id",f64(n.id))
    if n.replaces!=0 { number(L,"replaces_id",f64(n.replaces)) }
    for field,i in ([6]cstring{"app_name","app_icon","summary","body","urgency","image"}) {
        value:=([6]string{n.app,n.app_icon,n.summary,n.body,n.urgency,n.image})[i]
        if i<4 || value!="" { push_string(L,value);lua.setfield(L,-2,field) }
    }
    number(L,"expire_timeout",f64(n.timeout))
    lua.newtable(L)
    for a,i in n.actions {
        lua.newtable(L);push_string(L,a.key);lua.setfield(L,-2,"key");push_string(L,a.label);lua.setfield(L,-2,"label");lua.rawseti(L,-2,c.int(i+1))
    }
    lua.setfield(L,-2,"actions")
    lua.newtable(L)
    for h in n.hints {
        push_string(L,h.key)
        switch h.kind { case .Text:push_string(L,h.text);case .Number:lua.pushnumber(L,lua.Number(h.number));case .Boolean:lua.pushboolean(L,b32(h.boolean)) }
        lua.settable(L,-3)
    }
    lua.setfield(L,-2,"hints")
}
notify_closed :: proc "c" (L:^lua.State) -> c.int {
    context=runtime.default_context()
    id:=u32(lua.L_checkinteger(L,1));reason:=i32(lua.L_checkinteger(L,2));r:=self(L)
    if r.notify_closed!=nil { r.notify_closed(r.data,id,reason) };return 0
}
notify_action :: proc "c" (L:^lua.State) -> c.int {
    context=runtime.default_context()
    id:=u32(lua.L_checkinteger(L,1));key:=string(lua.L_checklstring(L,2,nil));r:=self(L)
    if r.notify_action!=nil { r.notify_action(r.data,id,key) };return 0
}
tray_activate :: proc "c" (L:^lua.State) -> c.int {
    context=runtime.default_context()
    service:=string(lua.L_checklstring(L,1,nil));kind:=string(lua.L_checklstring(L,2,nil))
    a:=i32(lua.L_optinteger(L,3,0));b:=string(lua.L_optlstring(L,4,"vertical",nil));r:=self(L)
    if r.tray_activate!=nil { r.tray_activate(r.data,service,kind,a,b) };return 0
}
monotonic :: proc "c" (L:^lua.State) -> c.int {
    context=runtime.default_context()
    ts:posix.timespec;posix.clock_gettime(.MONOTONIC,&ts)
    lua.pushnumber(L,lua.Number(f64(ts.tv_sec)+f64(ts.tv_nsec)/1e9));return 1
}
