package backend

import d "../drm"
import "../buffers"
import "../gbm"
import "../gles"
import out "../outputs"
import wl "../wayland"
import "core:testing"
import "core:sys/linux"

DRM_Test_IO :: struct { reject, reject_test, reject_fb: bool, flags: [dynamic]u32, closed: [dynamic]u32, removed: [dynamic]u32, next_fb: u32 }
drm_test_io: DRM_Test_IO
drm_test_ioctl :: proc(fd: i32, request: uint, data: rawptr) -> bool {
	switch request {
	case d.DRM_IOCTL_MODE_ATOMIC:
		r := cast(^d.drm_mode_atomic)data; append(&drm_test_io.flags,r.flags)
		return !drm_test_io.reject && !(drm_test_io.reject_test && r.flags&d.DRM_MODE_ATOMIC_TEST_ONLY != 0)
	case d.DRM_IOCTL_PRIME_FD_TO_HANDLE: (cast(^d.drm_prime_handle)data).handle = 7
	case d.DRM_IOCTL_GEM_CLOSE: append(&drm_test_io.closed,(cast(^d.drm_gem_close)data).handle)
	case d.DRM_IOCTL_MODE_ADDFB2:
		if drm_test_io.reject_fb { return false }; drm_test_io.next_fb += 1; (cast(^d.drm_mode_fb_cmd2)data).fb_id = drm_test_io.next_fb
	case d.DRM_IOCTL_MODE_RMFB: append(&drm_test_io.removed,(cast(^u32)data)^)
	case d.DRM_IOCTL_MODE_CREATEPROPBLOB: (cast(^d.drm_mode_create_blob)data).blob_id = 42
	case d.DRM_IOCTL_MODE_DESTROYPROPBLOB:
	case: return false
	}; return true
}
drm_test_finish :: proc() { delete(drm_test_io.flags); delete(drm_test_io.closed); delete(drm_test_io.removed); drm_test_io = {} }
drm_test_props :: proc(names: []string) -> []DRM_Property {
	props := make([]DRM_Property,len(names)); for name,i in names { props[i].id = u32(i+1); copy(props[i].name[:],transmute([]u8)name) }; return props
}
drm_test_output :: proc(display: ^wl.Display) -> ^DRM_Output {
	drm := new(DRM); init(&drm.base,display,&drm_impl); drm.base.data,drm.ioctl = drm,drm_test_ioctl; drm.flips = make(map[u64]^DRM_Output)
	plane := new(DRM_Plane); plane.id = 3; plane.props = drm_test_props({"FB_ID","CRTC_ID","SRC_X","SRC_Y","SRC_W","SRC_H","CRTC_X","CRTC_Y","CRTC_W","CRTC_H"}); append(&drm.planes,plane)
	c := new(DRM_Crtc); c.id,c.primary,c.props = 2,plane,drm_test_props({"ACTIVE","MODE_ID","VRR_ENABLED"}); append(&drm.crtcs,c)
	o := new(DRM_Output); o.backend,o.id,o.crtc,o.modeset,o.vrr = drm,1,c,true,true; c.output = o
	o.props = drm_test_props({"CRTC_ID","link-status"}); o.modes = make([]d.drm_mode_modeinfo,1); o.modes[0] = {hdisplay=64,vdisplay=32,htotal=100,vtotal=100,clock=600}
	out.init(&o.output,&drm_output_impl,display,"TEST-1"); o.output.data = o; o.output.width,o.output.height,o.output.refresh = 64,32,60000
	wl.listen(&o.output.events.commit,&o.committed,drm_committed); append(&drm.outputs,o); return o
}
drm_test_buffer :: proc(b: ^gles.Buffer) {
	b^ = gles.Buffer{width=64,height=32,n_planes=2,format=gbm.ARGB8888,modifier=gbm.INVALID}
	wl.signal_init(&b.events.retire); wl.signal_init(&b.events.destroy)
}
@(test)
drm_rejected_commit_flip_and_pause_ownership :: proc(t: ^testing.T) {
	defer drm_test_finish()
	display := wl.create(); defer wl.destroy(display)
	o := drm_test_output(display); drm := o.backend
	a,b: gles.Buffer; drm_test_buffer(&a); drm_test_buffer(&b)
	s: out.State; out.set_enabled(&s,true); out.set_buffer(&s,&a)
	drm_test_io.reject_test = true
	testing.expect(t,!out.commit(&o.output,&s)); testing.expect_value(t,a.locks,1); testing.expect_value(t,o.current,cast(^gles.Buffer)nil)
	drm_test_io.reject_test = false
	testing.expect(t,out.commit(&o.output,&s)); out.state_finish(&s); testing.expect_value(t,a.locks,1)
	testing.expect_value(t,drm_test_io.flags[len(drm_test_io.flags)-2],u32(d.DRM_MODE_ATOMIC_TEST_ONLY|d.DRM_MODE_ATOMIC_ALLOW_MODESET))
	testing.expect_value(t,drm_test_io.flags[len(drm_test_io.flags)-1],u32(d.DRM_MODE_ATOMIC_ALLOW_MODESET))
	s = {}; out.set_buffer(&s,&b); drm_test_io.reject = true
	testing.expect(t,!out.commit(&o.output,&s)); testing.expect_value(t,b.locks,1); testing.expect_value(t,a.locks,1)
	drm_test_io.reject = false; testing.expect(t,out.commit(&o.output,&s)); out.state_finish(&s)
	token := o.pending; testing.expect(t,token != 0)
	testing.expect_value(t,drm_test_io.flags[len(drm_test_io.flags)-1],u32(d.DRM_MODE_ATOMIC_NONBLOCK|d.DRM_MODE_PAGE_FLIP_EVENT))
	s = {}; out.set_buffer(&s,&a); testing.expect(t,!out.commit(&o.output,&s)); out.state_finish(&s)
	drm_flip(drm,d.drm_event_vblank{user_data=token+1}); testing.expect_value(t,o.pending,token)
	drm_flip(drm,d.drm_event_vblank{user_data=token,tv_sec=1}); testing.expect_value(t,a.locks,0); testing.expect_value(t,b.locks,1)
	s = {}; out.set_buffer(&s,&a); testing.expect(t,out.commit(&o.output,&s)); out.state_finish(&s); token = o.pending
	session := new(Session); session.ctx,session.display = context,display; wl.signal_init(&session.events.active); wl.signal_init(&session.events.destroy)
	drm.base.session = session; drm_active(&drm.active,nil)
	testing.expect_value(t,o.pending,u64(0)); testing.expect_value(t,a.locks,1); testing.expect_value(t,b.locks,1)
	drm_flip(drm,d.drm_event_vblank{user_data=token}); testing.expect_value(t,b.locks,1)
	// The fake fd deliberately prevents resume polling; exercise its identical full-state commit directly.
	session.active = true; s = {}; out.set_buffer(&s,o.queued); testing.expect(t,out.commit(&o.output,&s)); out.state_finish(&s)
	testing.expect_value(t,a.locks,1); testing.expect_value(t,b.locks,0); testing.expect(t,!o.modeset)
	fd,err := linux.open("/dev/null",{.RDWR,.CLOEXEC}); testing.expect_value(t,err,linux.Errno.NONE)
	drm.base.drm_fd = i32(fd); device := new(Session_Device); device.fd = i32(fd); append(&session.devices,device)
	drm_test_io.reject = true
	destroy(&drm.base); testing.expect_value(t,a.locks,0); testing.expect_value(t,b.locks,0)
}
@(test)
drm_framebuffer_shared_handles_and_failure :: proc(t: ^testing.T) {
	defer drm_test_finish()
	drm := DRM{ioctl=drm_test_ioctl}; b: gles.Buffer; drm_test_buffer(&b)
	drm_test_io.reject_fb = true; testing.expect_value(t,drm_fb(&drm,&b),u32(0)); testing.expect_value(t,len(drm_test_io.closed),1)
	drm_test_io.reject_fb = false; id := drm_fb(&drm,&b); testing.expect(t,id != 0); testing.expect_value(t,len(drm_test_io.closed),2)
	testing.expect_value(t,drm_fb(&drm,&b),id); testing.expect_value(t,len(drm_test_io.closed),2)
	wl.signal_emit_final(&b.events.destroy,&b); testing.expect_value(t,len(drm.fbs),0); testing.expect_value(t,len(drm_test_io.removed),1); delete(drm.fbs)
}
@(test)
drm_modifier_offsets_and_refresh :: proc(t: ^testing.T) {
	bytes: [80]u8; h := cast(^d.drm_format_modifier_blob)&bytes[0]; h^ = {version=1,count_formats=3,formats_offset=24,count_modifiers=1,modifiers_offset=40}
	formats := cast(^[3]u32)&bytes[24]; formats^ = {1,2,3}; m := cast(^d.drm_format_modifier)&bytes[40]; m^ = {formats=2,offset=1,modifier=123}
	result: [dynamic]buffers.Format; defer { for f in result { delete(f.modifiers) }; delete(result) }
	testing.expect(t,drm_formats_blob(bytes[:],&result)); testing.expect_value(t,len(result),1); testing.expect_value(t,result[0].format,u32(3)); testing.expect_value(t,result[0].modifiers[0],u64(123))
	m.offset = 3; testing.expect(t,!drm_formats_blob(bytes[:],&result)); h.modifiers_offset = 72; testing.expect(t,!drm_formats_blob(bytes[:],&result))
	mode := d.drm_mode_modeinfo{clock=148500,htotal=2200,vtotal=1125}; testing.expect_value(t,drm_refresh(mode),i32(60000))
	mode.flags = d.DRM_MODE_FLAG_INTERLACE; testing.expect_value(t,drm_refresh(mode),i32(120000)); mode.flags = d.DRM_MODE_FLAG_DBLSCAN; testing.expect_value(t,drm_refresh(mode),i32(30000))
}
@(test)
uevent_filters_and_session_pause :: proc(t: ^testing.T) {
	bytes := transmute([]u8)string("add@/devices/x\x00ACTION=add\x00SUBSYSTEM=input\x00DEVNAME=input/event12\x00")
	testing.expect_value(t,uevent_value(bytes,"SUBSYSTEM"),"input"); testing.expect_value(t,uevent_value(bytes,"DEV"),"")
	testing.expect(t,input_event_name("event12")); for name in ([]string{"event","event1/x","event-1","../event1"}) { testing.expect(t,!input_event_name(name)) }
	s := Session{active=true,property_active=true}; wl.signal_init(&s.events.active); device := Session_Device{paused=true}; append(&s.devices,&device); defer delete(s.devices)
	session_recompute(&s); testing.expect(t,!s.active); device.paused = false; s.property_active = false; session_recompute(&s); testing.expect(t,!s.active)
	s.property_active = true; session_recompute(&s); testing.expect(t,s.active); s.failed = true; session_recompute(&s); testing.expect(t,!s.active)
}
