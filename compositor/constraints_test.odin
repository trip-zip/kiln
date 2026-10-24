package compositor

import "core:testing"
import wl "../wayland"
import wlr "../wlroots"
import vm "../lua_runtime"

@(test)
queued_motion_uses_preceding_claim_and_copies_raw_deltas :: proc(t: ^testing.T) {
    s:=Server{display=wl.create()}
    defer destroy(&s)
    s.seat=wlr.wlr_seat_create(s.display,"motion")
    s.layout=wlr.wlr_output_layout_create(s.display)
    s.cursor=wlr.wlr_cursor_create()
    s.cursor_manager=wlr.wlr_xcursor_manager_create(nil,24)
    s.lua.data=&s;s.lua.grab_pointer=runtime_grab_pointer
    testing.expect(t,vm.init(&s.lua))
    expect_eval(t,&s,`seen={};core.set_event_handler(function(e)
        if e.name=='claim-on' then core.input.grab_pointer(true)
        elseif e.name=='claim-off' then core.input.grab_pointer(false)
        elseif e.name=='motion' then seen[#seen+1]=e._claimed and 'claimed' or 'released' end
    end)`,"\n")
    pointer:wlr.wlr_pointer
    input:=wlr.wlr_pointer_motion_event{pointer=&pointer,time_msec=123,delta_x=5,delta_y=-2,unaccel_dx=7,unaccel_dy=-3}
    queue_event(&s,vm.Event{name="claim-on"})
    cursor_motion(&s.cursor_motion,&input)
    testing.expect_value(t,s.events[1].dx,f64(5))
    testing.expect_value(t,s.events[1].ux,f64(7))
    testing.expect_value(t,s.events[1].uy,f64(-3))
    testing.expect_value(t,s.events[1].time,u32(123))
    input.delta_x=99
    cursor_motion(&s.cursor_motion,&input)
    queue_event(&s,vm.Event{name="claim-off"})
    cursor_motion(&s.cursor_motion,&input)
    testing.expect_value(t,len(s.events),5)
    wl.remove_source(s.event_source);drain_pending(&s)
    expect_eval(t,&s,"return table.concat(seen,',')","claimed,claimed,released\n")
    // A lock does not manufacture desktop motion, including for absolute destinations.
    locked:=wlr.wlr_pointer_constraint_v1{type=0}
    s.active_constraint=&locked
    relative:=vm.Event{native=.DeviceMotion,dx=30,dy=20,time=125}
    absolute:=vm.Event{native=.DeviceMotion,absolute=true,px=50,py=40,time=126}
    device_motion(&s,&relative);device_motion(&s,&absolute)
    expect_eval(t,&s,"return #seen","3\n")
    s.active_constraint=nil
}
