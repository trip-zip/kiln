package compositor

import "core:testing"
import vm "../lua_runtime"
import wl "../wayland"
import wlr "../wlroots"

reject_output :: proc "c" (o: ^wlr.wlr_output, state: ^wlr.wlr_output_state) -> bool {
    return false
}
@(test)
rejected_output_preserves_facts_and_queue :: proc(t: ^testing.T) {
    s:=Server{display=wl.create()}
    defer wl.destroy(s.display)
    handle:=wlr.wlr_output{name="TEST",width=800,height=600,scale=1}
    o:=Output{server=&s,handle=&handle,facts={width=800,height=600,scale=1},lifetime=1}
    previous:=o.facts
    state:wlr.wlr_output_state
    wlr.wlr_output_state_init(&state)
    defer wlr.wlr_output_state_finish(&state)
    wlr.wlr_output_state_set_scale(&state,2)
    testing.expect(t,!commit_output(&o,&state,reject_output))
    testing.expect(t,o.facts==previous && !o.dirty && o.notices==0 && len(s.events)==0 && !s.failed)
}
@(test)
output_modes_and_lifetime_are_exact :: proc(t: ^testing.T) {
    m:=wlr.wlr_output_mode{width=1920,height=1080,refresh=59940}
    testing.expect(t,mode_matches(&m,{1920,1080,0}) && mode_matches(&m,{1920,1080,59940}))
    testing.expect(t,!mode_matches(&m,{1920,1080,60}) && !mode_matches(&m,{1280,720,59940}))
    s:Server
    h:=wlr.wlr_output{name="REUSED"}
    o:=Output{handle=&h,lifetime=2}
    append(&s.outputs,&o)
    defer delete(s.outputs)
    old:=vm.Event{class="output",name="change",output="REUSED",generation=1}
    testing.expect(t,!valid_output_event(&s,&old))
    old.generation=2
    testing.expect(t,valid_output_event(&s,&old))
}

@(test)
queued_motion_rejects_retired_devices_and_outputs :: proc(t: ^testing.T) {
    s:Server
    p:=Pointer{id=7}
    h:=wlr.wlr_output{enabled=true}
    o:=Output{handle=&h,lifetime=8}
    append(&s.pointers,&p);append(&s.outputs,&o)
    defer delete(s.pointers);defer delete(s.outputs)
    e:=vm.Event{pointer_device=7,motion_output=8}
    testing.expect(t,valid_motion(&s,&e))
    o.lifetime=9
    testing.expect(t,!valid_motion(&s,&e))
    e.motion_output=9;p.id=10
    testing.expect(t,!valid_motion(&s,&e))
    e.pointer_device=10;h.enabled=false
    testing.expect(t,!valid_motion(&s,&e))
}

fixture_vt:u32
record_vt :: proc(session:^wlr.wlr_session,vt:u32) -> bool { fixture_vt=vt;return true }
@(test)
native_vt_and_suspended_frame_recovery :: proc(t:^testing.T) {
    s:=Server{display=wl.create()}
    defer wl.destroy(s.display)
    syms:=[]u32{0x1008fe02}
    testing.expect(t,!native_vt(&s,syms,12,true,record_vt))
    session:wlr.wlr_session
    s.session=&session
    testing.expect(t,!native_vt(&s,syms,4,true,record_vt) && !native_vt(&s,syms,12,false,record_vt))
    testing.expect(t,native_vt(&s,syms,12,true,record_vt))
    testing.expect_value(t,fixture_vt,2)
    testing.expect_value(t,vt_number(0x1008fe0c,12),12)
    testing.expect_value(t,vt_number(0x1008fe0d,12),0)
    handle:=wlr.wlr_output{enabled=true}
    o:=Output{server=&s,handle=&handle}
    output_frame(&o.frame,nil)
    testing.expect(t,o.dirty && !s.failed && o.frames==0)
    o.dirty=false;output_commit_failed(&o)
    testing.expect(t,o.dirty && !s.failed)
    session.active=true;output_commit_failed(&o)
    testing.expect(t,s.failed)
}
