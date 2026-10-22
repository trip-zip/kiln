package compositor

import auth "../authentication"
import vm "../lua_runtime"

runtime_authenticate :: proc(data:rawptr,password:string)->u64 {
    s:=(^Server)(data)
    if s.lock_owner!=.Native || s.shutting_down || s.auth.pid!=0 || s.next_auth==vm.MAX_ASYNC_ID { return 0 }
    s.authenticated=false;s.next_auth+=1
    if !auth.submit(&s.auth,s.display,s.lock_generation,s.next_auth,password,s,authentication_complete) { return 0 }
    return s.next_auth
}
authentication_complete :: proc(data:rawptr,generation,id:u64,success:bool,reason:string) {
    s:=(^Server)(data)
    if s.shutting_down || s.lock_owner!=.Native || generation!=s.lock_generation || id!=s.next_auth { return }
    s.authenticated=success
    queue_event(s,vm.Event{class="session",name="authenticated",generation=generation,id=id,on=success,bytes=reason})
}
lock_reload :: proc(s:^Server) {
    auth.cancel(&s.auth);s.authenticated=false
    if locked(s) { s.lock_generation+=1;lock_reset_input(s) }
    vm.apply_reload(&s.lua)
    if locked(s) {
        kind:="native";if s.lock_owner==.External { kind="ext" }
        queue_event(s,vm.Event{class="session",name="lock",bytes=kind,generation=s.lock_generation})
        lock_cover(s);lock_focus(s)
    }
}
runtime_lock_state :: proc(data:rawptr)->vm.Lock_State {
    s:=(^Server)(data)
    kind:="unlocked";if s.lock_owner==.Native { kind="native" } else if s.lock_owner==.External { kind="ext" }
    return {kind,s.lock_generation,s.authenticated,s.auth.pid!=0,s.next_auth,len(s.lock_surfaces),len(s.idle_inhibitors)}
}
