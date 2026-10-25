package backend

import "../buffers"
import d "../drm"
import "../gbm"
import "../gles"
import out "../outputs"
import wl "../wayland"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

DRM :: struct {
	base: Backend,
	input: ^Input,
	hotplug: ^Hotplug,
	path: string,
	major, minor: u32,
	crtcs: [dynamic]^DRM_Crtc,
	planes: [dynamic]^DRM_Plane,
	outputs: [dynamic]^DRM_Output,
	fbs: [dynamic]^DRM_FB,
	retained: [dynamic]^gles.Buffer,
	flips: map[u64]^DRM_Output,
	next_flip: u64,
	active, device_gone: wl.Listener,
	source, failure: ^wl.Source,
	modifiers: bool,
	cursor_width, cursor_height: u64,
	ioctl: proc(i32,uint,rawptr) -> bool,
}
DRM_Property :: struct { id: u32, name: [32]u8, value: u64 }
DRM_Plane :: struct { id, possible, kind: u32, props: []DRM_Property, formats: [dynamic]buffers.Format }
DRM_Crtc :: struct { id, index: u32, primary, cursor: ^DRM_Plane, props: []DRM_Property, output: ^DRM_Output }
DRM_Output :: struct {
	output: out.Output,
	backend: ^DRM,
	id, possible: u32,
	crtc: ^DRM_Crtc,
	props: []DRM_Property,
	modes: []d.drm_mode_modeinfo,
	current, queued: ^gles.Buffer,
	pending: u64,
	seq: u32,
	vrr, non_desktop, modeset, synchronous: bool,
	committed: wl.Listener,
}
DRM_Connector :: struct { info: d.drm_mode_get_connector, modes: []d.drm_mode_modeinfo, encoders: []u32, props: []DRM_Property }
drm_impl := Backend_Impl{start=drm_start,destroy=drm_destroy}
drm_output_impl := out.Impl{commit=drm_commit,destroy=drm_output_destroy,schedule=drm_schedule}

drm_text :: proc(bytes: []u8) -> string { for c,i in bytes { if c == 0 { return string(bytes[:i]) } }; return string(bytes) }
drm_property :: proc(props: []DRM_Property, name: string) -> (p: DRM_Property) { for &value in props { if drm_text(value.name[:]) == name { return value } }; return }
drm_resources :: proc(fd: i32) -> (crtcs, connectors: []u32, ok: bool) {
	for _ in 0..<16 {
		r: d.drm_mode_card_res
		if !d.ioctl(fd,d.DRM_IOCTL_MODE_GETRESOURCES,&r) || r.count_crtcs > 32 || r.count_connectors > 4096 { return }
		crtcs, connectors = make([]u32,r.count_crtcs),make([]u32,r.count_connectors)
		r.crtc_id_ptr, r.connector_id_ptr = u64(uintptr(raw_data(crtcs))),u64(uintptr(raw_data(connectors)))
		r.count_fbs, r.count_encoders = 0,0
		if d.ioctl(fd,d.DRM_IOCTL_MODE_GETRESOURCES,&r) && int(r.count_crtcs) == len(crtcs) && int(r.count_connectors) == len(connectors) { return crtcs,connectors,true }
		delete(crtcs); delete(connectors); crtcs,connectors = nil,nil
	}
	return
}
drm_properties :: proc(fd: i32, id, kind: u32) -> []DRM_Property {
	for _ in 0..<16 {
		r := d.drm_mode_obj_get_properties{obj_id=id,obj_type=kind}
		if !d.ioctl(fd,d.DRM_IOCTL_MODE_OBJ_GETPROPERTIES,&r) || r.count_props > 4096 { return nil }
		ids := make([]u32,r.count_props); values := make([]u64,r.count_props)
		defer delete(ids); defer delete(values)
		r.props_ptr, r.prop_values_ptr = u64(uintptr(raw_data(ids))),u64(uintptr(raw_data(values)))
		if !d.ioctl(fd,d.DRM_IOCTL_MODE_OBJ_GETPROPERTIES,&r) || int(r.count_props) != len(ids) { continue }
		props := make([]DRM_Property,len(ids))
		for prop_id,i in ids {
			p := d.drm_mode_get_property{prop_id=prop_id}
			if d.ioctl(fd,d.DRM_IOCTL_MODE_GETPROPERTY,&p) { props[i] = {prop_id,p.name,values[i]} }
		}
		return props
	}
	return nil
}
drm_blob :: proc(fd: i32, id: u32) -> []u8 {
	r := d.drm_mode_get_blob{blob_id=id}
	if id == 0 || !d.ioctl(fd,d.DRM_IOCTL_MODE_GETPROPBLOB,&r) || r.length > 16*1024*1024 { return nil }
	bytes := make([]u8,r.length); r.data = u64(uintptr(raw_data(bytes)))
	if !d.ioctl(fd,d.DRM_IOCTL_MODE_GETPROPBLOB,&r) || int(r.length) != len(bytes) { delete(bytes); return nil }; return bytes
}
drm_connector :: proc(fd: i32, id: u32) -> (c: DRM_Connector, ok: bool) {
	for _ in 0..<16 {
		c.info = {connector_id=id}
		if !d.ioctl(fd,d.DRM_IOCTL_MODE_GETCONNECTOR,&c.info) || c.info.count_modes > 4096 || c.info.count_encoders > 4096 { return }
		c.modes = make([]d.drm_mode_modeinfo,c.info.count_modes); c.encoders = make([]u32,c.info.count_encoders)
		c.info.modes_ptr, c.info.encoders_ptr = u64(uintptr(raw_data(c.modes))),u64(uintptr(raw_data(c.encoders)))
		c.info.count_props = 0
		if d.ioctl(fd,d.DRM_IOCTL_MODE_GETCONNECTOR,&c.info) && int(c.info.count_modes) == len(c.modes) && int(c.info.count_encoders) == len(c.encoders) {
			c.props = drm_properties(fd,id,d.DRM_MODE_OBJECT_CONNECTOR); return c,true
		}
		delete(c.modes); delete(c.encoders); c.modes, c.encoders = nil,nil
	}
	return
}
drm_connector_finish :: proc(c: ^DRM_Connector) { delete(c.modes); delete(c.encoders); delete(c.props); c^ = {} }
drm_connector_name :: proc(type, id: u32) -> string {
	names := [?]string{"Unknown","VGA","DVI-I","DVI-D","DVI-A","Composite","SVIDEO","LVDS","Component","DIN","DP","HDMI-A","HDMI-B","TV","eDP","Virtual","DSI","DPI","Writeback","SPI","USB"}
	return fmt.tprintf("%s-%d",names[type] if type < len(names) else "Unknown",id)
}
drm_refresh :: proc(m: d.drm_mode_modeinfo) -> i32 {
	if m.htotal == 0 || m.vtotal == 0 { return 0 }
	r := (i64(m.clock)*1_000_000/i64(m.htotal)+i64(m.vtotal)/2)/i64(m.vtotal)
	if m.flags&d.DRM_MODE_FLAG_INTERLACE != 0 { r *= 2 }; if m.flags&d.DRM_MODE_FLAG_DBLSCAN != 0 { r /= 2 }; if m.vscan > 1 { r /= i64(m.vscan) }
	return i32(r)
}
drm_format_add :: proc(formats: ^[dynamic]buffers.Format, format: u32, modifier: u64) {
	for &f in formats { if f.format == format {
		for m in f.modifiers { if m == modifier { return } }
		mods := make([]u64,len(f.modifiers)+1); copy(mods,f.modifiers); mods[len(f.modifiers)] = modifier; delete(f.modifiers); f.modifiers = mods; return
	} }
	mods := make([]u64,1); mods[0] = modifier; append(formats,buffers.Format{format,mods})
}
drm_formats_blob :: proc(bytes: []u8, formats: ^[dynamic]buffers.Format) -> bool {
	if len(bytes) < size_of(d.drm_format_modifier_blob) { return false }
	h := (cast(^d.drm_format_modifier_blob)raw_data(bytes))^
	if h.version != 1 || u64(h.formats_offset)+u64(h.count_formats)*4 > u64(len(bytes)) || u64(h.modifiers_offset)+u64(h.count_modifiers)*24 > u64(len(bytes)) || h.formats_offset%4 != 0 || h.modifiers_offset%8 != 0 { return false }
	values := (cast([^]u32)(uintptr(raw_data(bytes))+uintptr(h.formats_offset)))[:h.count_formats]
	for m in (cast([^]d.drm_format_modifier)(uintptr(raw_data(bytes))+uintptr(h.modifiers_offset)))[:h.count_modifiers] {
		for bit: u32 = 0; bit < 64; bit += 1 { if m.formats&(u64(1)<<bit) != 0 {
			index := u64(m.offset)+u64(bit); if index >= u64(len(values)) { return false }; drm_format_add(formats,values[index],m.modifier)
		} }
	}
	return true
}
drm_load_planes :: proc(drm: ^DRM) -> bool {
	ids: []u32; defer delete(ids)
	for attempt in 0..<16 {
		r: d.drm_mode_get_plane_res
		if !d.ioctl(drm.base.drm_fd,d.DRM_IOCTL_MODE_GETPLANERESOURCES,&r) || r.count_planes > 4096 { return false }
		delete(ids); ids = make([]u32,r.count_planes); r.plane_id_ptr = u64(uintptr(raw_data(ids)))
		if d.ioctl(drm.base.drm_fd,d.DRM_IOCTL_MODE_GETPLANERESOURCES,&r) && int(r.count_planes) == len(ids) { break }
		if attempt == 15 { return false }
	}
	for id in ids {
		r := d.drm_mode_get_plane{plane_id=id}
		if !d.ioctl(drm.base.drm_fd,d.DRM_IOCTL_MODE_GETPLANE,&r) || r.count_format_types > 4096 { return false }
		formats := make([]u32,r.count_format_types); defer delete(formats)
		r.format_type_ptr = u64(uintptr(raw_data(formats)))
		if !d.ioctl(drm.base.drm_fd,d.DRM_IOCTL_MODE_GETPLANE,&r) || int(r.count_format_types) != len(formats) { return false }
		p := new(DRM_Plane); p.id, p.possible, p.props = id,r.possible_crtcs,drm_properties(drm.base.drm_fd,id,d.DRM_MODE_OBJECT_PLANE)
		p.kind = u32(drm_property(p.props,"type").value); append(&drm.planes,p)
		for format in formats { drm_format_add(&p.formats,format,gbm.INVALID); drm_format_add(&p.formats,format,0) }
		blob := drm_blob(drm.base.drm_fd,u32(drm_property(p.props,"IN_FORMATS").value)); defer delete(blob)
		if drm.modifiers && len(blob) > 0 && !drm_formats_blob(blob,&p.formats) { return false }
		for c in drm.crtcs { if p.possible&(1<<c.index) != 0 {
			if p.kind == 1 && c.primary == nil { c.primary = p; break }
			if p.kind == 2 && c.cursor == nil { c.cursor = p; break }
		} }
	}
	return true
}

drm_cap :: proc(drm: ^DRM, cap: u64) -> u64 { r := d.drm_get_cap{capability=cap}; drm.ioctl(drm.base.drm_fd,d.DRM_IOCTL_GET_CAP,&r); return r.value }
drm_create :: proc(display: ^wl.Display) -> ^Backend {
	s := session_create(display); if s == nil { return nil }
	drm := new(DRM); init(&drm.base,display,&drm_impl); drm.base.data,drm.base.session,drm.ioctl = drm,s,d.ioctl
	drm.flips = make(map[u64]^DRM_Output)
	ok := false; defer if !ok { destroy(&drm.base) }
	if !s.active { fmt.eprintln("DRM: logind session is inactive"); return nil }
	paths: [dynamic]string; defer delete(paths)
	if path := os.get_env("KILN_DRM_DEVICE",context.temp_allocator); path != "" { append(&paths,path) } else {
		entries,_ := os.read_all_directory_by_path("/dev/dri",context.temp_allocator)
		for e in entries { if strings.has_prefix(e.name,"card") { append(&paths,fmt.tprintf("/dev/dri/%s",e.name)) } }
	}
	for path in paths {
		st: posix.stat_t; if posix.stat(strings.clone_to_cstring(path,context.temp_allocator),&st) != .OK { continue }
		_,render := gles.render_node(gles.drm_directory(st.st_rdev)); if !render { continue }
		fd := session_open(s,path,i32(transmute(u32)linux.Open_Flags{.RDWR,.NONBLOCK})); if fd < 0 { continue }
		crtcs,connectors,found := drm_resources(fd); delete(crtcs)
		usable := false
		for id in connectors { c,valid := drm_connector(fd,id); if valid && c.info.connector_type != 18 { usable = true }; drm_connector_finish(&c) }; delete(connectors)
		if !found || !usable { session_close(s,fd); continue }
		drm.base.drm_fd,drm.path = fd,strings.clone(path); drm.major,drm.minor = device_numbers(u64(st.st_rdev)); break
	}
	if drm.base.drm_fd < 0 { fmt.eprintln("DRM: no usable card from logind"); return nil }
	for cap in ([]u64{d.DRM_CLIENT_CAP_UNIVERSAL_PLANES,d.DRM_CLIENT_CAP_ATOMIC}) {
		r := d.drm_set_client_cap{capability=cap,value=1}; if !drm.ioctl(drm.base.drm_fd,d.DRM_IOCTL_SET_CLIENT_CAP,&r) { fmt.eprintln("DRM: atomic modesetting is required"); return nil }
	}
	hotspot := d.drm_set_client_cap{capability=d.DRM_CLIENT_CAP_CURSOR_PLANE_HOTSPOT,value=1}; drm.ioctl(drm.base.drm_fd,d.DRM_IOCTL_SET_CLIENT_CAP,&hotspot)
	drm.modifiers = drm_cap(drm,d.DRM_CAP_ADDFB2_MODIFIERS) != 0
	drm.cursor_width,drm.cursor_height = drm_cap(drm,d.DRM_CAP_CURSOR_WIDTH),drm_cap(drm,d.DRM_CAP_CURSOR_HEIGHT)
	if drm.cursor_width == 0 { drm.cursor_width = 64 }; if drm.cursor_height == 0 { drm.cursor_height = 64 }
	if drm_cap(drm,d.DRM_CAP_TIMESTAMP_MONOTONIC) == 0 { fmt.eprintln("DRM: monotonic flip timestamps are required"); return nil }
	crtcs,connectors,found := drm_resources(drm.base.drm_fd); defer delete(crtcs); defer delete(connectors); if !found { return nil }
	for id,i in crtcs { c := new(DRM_Crtc); c.id,c.index,c.props = id,u32(i),drm_properties(drm.base.drm_fd,id,d.DRM_MODE_OBJECT_CRTC); append(&drm.crtcs,c) }
	if !drm_load_planes(drm) { return nil }
	drm.source = wl.loop_on_fd(display.loop,drm.base.drm_fd,{.Readable},drm_ready,drm); if drm.source == nil { return nil }
	wl.listen(&s.events.active,&drm.active,drm_active)
	wl.listen(&s.events.device_gone,&drm.device_gone,drm_device_gone)
	drm.hotplug = hotplug_create(drm); if drm.hotplug == nil { return nil }
	fmt.printf("DRM: atomic card %s, %d CRTCs, %d planes\n",drm.path,len(drm.crtcs),len(drm.planes))
	ok = true; return &drm.base
}
drm_assign :: proc(o: ^DRM_Output) -> bool {
	if o.crtc != nil { return true }
	for c in o.backend.crtcs { if c.output == nil && c.primary != nil && o.possible&(1<<c.index) != 0 {
		c.output,o.crtc = o,c; out.set_formats(&o.output,c.primary.formats[:]); return true
	} }; return false
}
drm_scan :: proc(drm: ^DRM) -> bool {
	crtcs,ids,ok := drm_resources(drm.base.drm_fd); delete(crtcs); if !ok { return false }; defer delete(ids)
	seen: [dynamic]u32; defer delete(seen)
	for id in ids {
		c,found := drm_connector(drm.base.drm_fd,id); if !found { return false }; defer drm_connector_finish(&c)
		if c.info.connection != 1 || c.info.connector_type == 18 || len(c.modes) == 0 { continue }; append(&seen,id)
		exists := false
		for o in drm.outputs { if o.id == id {
			if drm_property(c.props,"link-status").value == 1 { out.finish(&o.output) } else { exists = true }; break
		} }
		if drm.failure != nil { return false }; if exists { continue }
		o := new(DRM_Output); o.backend,o.id,o.modeset = drm,id,true
		o.props,o.modes = c.props,c.modes; c.props,c.modes = nil,nil
		out.init(&o.output,&drm_output_impl,drm.base.display,drm_connector_name(c.info.connector_type,c.info.connector_type_id)); o.output.data = o
		o.output.physical_width,o.output.physical_height = i32(c.info.mm_width),i32(c.info.mm_height)
		o.output.subpixel = i32(c.info.subpixel-1) if c.info.subpixel >= 1 && c.info.subpixel <= 6 else 0
		bytes := drm_blob(drm.base.drm_fd,u32(drm_property(o.props,"EDID").value)); defer delete(bytes)
		o.output.make,o.output.model,o.output.serial = out.edid(bytes)
		out.set_description(&o.output,strings.trim_space(fmt.tprintf("%s %s %s (%s)",o.output.make,o.output.model,o.output.serial,o.output.name)))
		for mode in o.modes { m := new(out.Mode); m^ = {i32(mode.hdisplay),i32(mode.vdisplay),drm_refresh(mode),mode.type&d.DRM_MODE_TYPE_PREFERRED != 0}; append(&o.output.modes,m) }
		m := out.preferred_mode(&o.output); o.output.current_mode,o.output.width,o.output.height,o.output.refresh = m,m.width,m.height,m.refresh
		o.vrr,o.non_desktop = drm_property(o.props,"vrr_capable").value != 0,drm_property(o.props,"non-desktop").value != 0
		o.output.non_desktop = o.non_desktop
		for encoder in c.encoders { e := d.drm_mode_get_encoder{encoder_id=encoder}; if drm.ioctl(drm.base.drm_fd,d.DRM_IOCTL_MODE_GETENCODER,&e) { o.possible |= e.possible_crtcs } }
		o.output.auto_enable = drm_assign(o) && !o.non_desktop; wl.listen(&o.output.events.commit,&o.committed,drm_committed); append(&drm.outputs,o)
		fmt.printf("DRM: connected %s, preferred %dx%d @ %d mHz\n",o.output.name,m.width,m.height,m.refresh)
		wl.signal_emit_mutable(&drm.base.events.new_output,&o.output)
	}
	for i := len(drm.outputs)-1; i >= 0; i -= 1 { o := drm.outputs[i]; found := false; for id in seen { if o.id == id { found = true } }; if !found { out.finish(&o.output) } }
	return true
}
drm_start :: proc(b: ^Backend) -> bool {
	drm := cast(^DRM)b.data; b.started = true
	drm.input = input_create(b); return drm.input != nil && drm_scan(drm)
}
DRM_Atomic :: struct { objects,counts,props: [dynamic]u32, values: [dynamic]u64, valid: bool }
drm_atomic_add :: proc(a: ^DRM_Atomic, object: u32, props: []DRM_Property, name: string, value: u64, optional := false) {
	p := drm_property(props,name); if p.id == 0 { if !optional { a.valid = false }; return }
	if len(a.objects) == 0 || a.objects[len(a.objects)-1] != object { append(&a.objects,object); append(&a.counts,0) }
	a.counts[len(a.counts)-1] += 1; append(&a.props,p.id); append(&a.values,value)
}
drm_atomic_finish :: proc(a: ^DRM_Atomic) { delete(a.objects); delete(a.counts); delete(a.props); delete(a.values) }
drm_atomic_submit :: proc(drm: ^DRM, a: ^DRM_Atomic, flags: u32, token: u64) -> bool {
	if !a.valid { return false }
	r := d.drm_mode_atomic{flags=flags,count_objs=u32(len(a.objects)),objs_ptr=u64(uintptr(raw_data(a.objects))),count_props_ptr=u64(uintptr(raw_data(a.counts))),props_ptr=u64(uintptr(raw_data(a.props))),prop_values_ptr=u64(uintptr(raw_data(a.values))),user_data=token}
	return drm.ioctl(drm.base.drm_fd,d.DRM_IOCTL_MODE_ATOMIC,&r)
}
drm_commit :: proc(output: ^out.Output, state: ^out.State) -> bool {
	o := cast(^DRM_Output)output.data; drm := o.backend
	if !session_active(drm.base.session) { return false }
	if o.pending != 0 { fmt.eprintf("DRM: %s already has a pending page flip\n",output.name); return false }
	enabled := state.enabled if .Enabled in state.committed else output.enabled
	if enabled && !drm_assign(o) { fmt.eprintf("DRM: no free CRTC for %s\n",output.name); return false }
	if o.crtc == nil { return !enabled }
	vrr := state.adaptive_sync if .Adaptive_Sync in state.committed else output.adaptive_sync_status != 0
	if vrr && (!o.vrr || drm_property(o.crtc.props,"VRR_ENABLED").id == 0) { return false }
	modeset := o.modeset || state.committed&{.Enabled,.Mode} != {}
	if !modeset && state.committed&{.Buffer,.Adaptive_Sync} == {} { return true }
	b := state.buffer if .Buffer in state.committed else o.current
	fb: u32; if enabled { if b == nil { return false }; fb = drm_fb(drm,b); if fb == 0 { return false } }
	mode: d.drm_mode_modeinfo; blob: d.drm_mode_create_blob
	if modeset && enabled {
		w,h,refresh := output.width,output.height,output.refresh
		if .Mode in state.committed { m := state.mode^ if state.mode != nil else state.custom_mode; w,h,refresh = m.width,m.height,m.refresh }
		found := false; for m in o.modes { if i32(m.hdisplay) == w && i32(m.vdisplay) == h && (refresh == 0 || drm_refresh(m) == refresh) { mode = m; found = true; break } }
		if !found { return false }
		blob.data,blob.length = u64(uintptr(&mode)),u32(size_of(mode))
		if !drm.ioctl(drm.base.drm_fd,d.DRM_IOCTL_MODE_CREATEPROPBLOB,&blob) { return false }
	}
	defer if blob.blob_id != 0 { r := d.drm_mode_destroy_blob{blob_id=blob.blob_id}; drm.ioctl(drm.base.drm_fd,d.DRM_IOCTL_MODE_DESTROYPROPBLOB,&r) }
	a := DRM_Atomic{valid=true}; defer drm_atomic_finish(&a)
	c := o.crtc; plane := c.primary
	if modeset {
		drm_atomic_add(&a,o.id,o.props,"CRTC_ID",u64(c.id) if enabled else 0)
		drm_atomic_add(&a,o.id,o.props,"link-status",0,true)
		drm_atomic_add(&a,c.id,c.props,"ACTIVE",u64(enabled)); drm_atomic_add(&a,c.id,c.props,"MODE_ID",u64(blob.blob_id))
	}
	if modeset || .Adaptive_Sync in state.committed { drm_atomic_add(&a,c.id,c.props,"VRR_ENABLED",u64(enabled && vrr),true) }
	drm_atomic_add(&a,plane.id,plane.props,"FB_ID",u64(fb)); drm_atomic_add(&a,plane.id,plane.props,"CRTC_ID",u64(c.id) if enabled else 0)
	if enabled {
		for name,i in ([]string{"SRC_X","SRC_Y","SRC_W","SRC_H","CRTC_X","CRTC_Y","CRTC_W","CRTC_H"}) {
			values := [8]u64{0,0,u64(b.width)<<16,u64(b.height)<<16,0,0,u64(b.width),u64(b.height)}; drm_atomic_add(&a,plane.id,plane.props,name,values[i])
		}
	}
	if modeset && c.cursor != nil { drm_atomic_add(&a,c.cursor.id,c.cursor.props,"FB_ID",0); drm_atomic_add(&a,c.cursor.id,c.cursor.props,"CRTC_ID",0) }
	if modeset && !drm_atomic_submit(drm,&a,d.DRM_MODE_ATOMIC_TEST_ONLY|d.DRM_MODE_ATOMIC_ALLOW_MODESET,0) { return false }
	drm.next_flip += 1; token := drm.next_flip
	if enabled { gles.buffer_retain(b) }
	flags := u32(d.DRM_MODE_ATOMIC_ALLOW_MODESET) if modeset else u32(d.DRM_MODE_ATOMIC_NONBLOCK|d.DRM_MODE_PAGE_FLIP_EVENT)
	if !drm_atomic_submit(drm,&a,flags,0 if modeset else token) { if enabled { gles.buffer_release(b) }; return false }
	if modeset {
		gles.buffer_release(o.current); gles.buffer_release(o.queued); o.current,o.queued = b if enabled else nil,nil
		o.modeset,o.synchronous = false,enabled
		if !enabled { c.output,o.crtc = nil,nil }
	} else { o.queued,o.pending,o.seq = b,token,output.commit_seq+1; drm.flips[token] = o }
	return true
}
drm_committed :: proc(l: ^wl.Listener, data: rawptr) {
	o := wl.owner(l,DRM_Output,"committed")
	if o.synchronous { o.synchronous = false; out.send_present(&o.output,out.Present_Event{commit_seq=o.output.commit_seq,presented=true}) }
	if o.output.needs_frame && o.pending == 0 { out.schedule_frame(&o.output) }
}
drm_schedule :: proc(output: ^out.Output) {
	o := cast(^DRM_Output)output.data
	if o.pending == 0 && session_active(o.backend.base.session) && output.idle_frame == nil { output.idle_frame = wl.on_idle(output.display,out.frame_idle,output) }
}
drm_flip :: proc(drm: ^DRM, e: d.drm_event_vblank) {
	o := drm.flips[e.user_data]; if o == nil || o.pending != e.user_data { return }
	delete_key(&drm.flips,e.user_data); o.pending = 0
	gles.buffer_release(o.current); o.current,o.queued = o.queued,nil
	out.send_present(&o.output,out.Present_Event{commit_seq=o.seq,presented=true,when_={tv_sec=posix.time_t(e.tv_sec),tv_nsec=i64(e.tv_usec)*1000}})
	if o.output.needs_frame { out.send_frame(&o.output) }
}
drm_ready :: proc(fd: i32, mask: wl.Mask, data: rawptr) -> i32 {
	drm := cast(^DRM)data
	if mask&{.Hangup,.Error} != {} { drm_failed(drm); return 0 }
	bytes: [4096]u8; count,err := linux.read(linux.Fd(fd),bytes[:])
	if err == .EAGAIN { return 0 }; if err != .NONE || count == 0 { drm_failed(drm); return 0 }
	for offset: int = 0; offset < count; {
		if int(count)-offset < size_of(d.drm_event) { drm_failed(drm); break }
		e := (cast(^d.drm_event)&bytes[offset])^
		if e.length < size_of(e) || int(e.length) > int(count)-offset { drm_failed(drm); break }
		if e.type == d.DRM_EVENT_FLIP_COMPLETE && e.length >= size_of(d.drm_event_vblank) { drm_flip(drm,(cast(^d.drm_event_vblank)&bytes[offset])^) }
		offset += int(e.length)
	}; return 0
}
drm_failed :: proc(drm: ^DRM) { if drm.failure == nil { drm.failure = wl.on_idle(drm.base.display,drm_failure,drm) } }
drm_failure :: proc(data: rawptr) { drm := cast(^DRM)data; drm.failure = nil; destroy(&drm.base) }
drm_device_gone :: proc(l: ^wl.Listener, data: rawptr) {
	drm := wl.owner(l,DRM,"device_gone"); device := cast(^Session_Device)data
	if device.fd == drm.base.drm_fd { drm_failed(drm) }
}
drm_active :: proc(l: ^wl.Listener, data: rawptr) {
	drm := wl.owner(l,DRM,"active")
	if drm.base.session.failed { drm_failed(drm) }
	if !drm.base.session.active {
		wl.remove_source(drm.source); drm.source = nil
		for o in drm.outputs { delete_key(&drm.flips,o.pending); o.pending = 0; o.modeset = true; o.output.frame_pending = false; wl.remove_source(o.output.idle_frame); o.output.idle_frame = nil }
		return
	}
	wl.remove_source(drm.source); drm.source = wl.loop_on_fd(drm.base.loop,drm.base.drm_fd,{.Readable},drm_ready,drm)
	if drm.source == nil { drm_failed(drm); return }
	// A monitor unplugged while inactive must disappear before its old mode is restored.
	if drm.base.started && !drm_scan(drm) { drm_failed(drm); return }
	for o in drm.outputs { if o.output.enabled && o.modeset {
		s: out.State; out.set_buffer(&s,o.queued if o.queued != nil else o.current)
		ok := out.commit(&o.output,&s); out.state_finish(&s); if !ok { fmt.eprintf("DRM: cannot restore %s\n",o.output.name); drm_failed(drm); return }
		out.schedule_frame(&o.output)
	} }
}
drm_output_destroy :: proc(output: ^out.Output) {
	o := cast(^DRM_Output)output.data; drm := o.backend
	wl.unlisten(&o.committed); delete_key(&drm.flips,o.pending); o.pending = 0
	if drm.base.drm_fd >= 0 && o.crtc != nil && session_active(drm.base.session) {
		s: out.State; out.set_enabled(&s,false)
		if !drm_commit(output,&s) { drm_failed(drm) }
	}
	// A revoked or failed card can still scan out either image until its fd closes.
	if drm.base.drm_fd >= 0 && (o.current != nil || o.queued != nil) {
		if o.current != nil { append(&drm.retained,o.current) }; if o.queued != nil { append(&drm.retained,o.queued) }
	} else { gles.buffer_release(o.current); gles.buffer_release(o.queued) }
	if o.crtc != nil { o.crtc.output = nil }
	for other,i in drm.outputs { if other == o { ordered_remove(&drm.outputs,i); break } }
	delete(o.props); delete(o.modes); free(o)
}
drm_destroy :: proc(b: ^Backend) {
	drm := cast(^DRM)b.data
	wl.unlisten(&drm.active); wl.unlisten(&drm.device_gone); wl.remove_source(drm.source); wl.remove_source(drm.failure); drm.failure = nil
	hotplug_destroy(drm.hotplug); input_destroy(drm.input)
	for len(drm.outputs) > 0 { out.finish(&drm.outputs[len(drm.outputs)-1].output) }
	wl.remove_source(drm.failure)
	// Closing the KMS fd ends its scanout references before the renderer may reclaim images.
	if b.drm_fd >= 0 { session_close(b.session,b.drm_fd); b.drm_fd = -1 }
	for len(drm.fbs) > 0 { drm_fb_destroy(drm.fbs[len(drm.fbs)-1]) }
	for buffer in drm.retained { gles.buffer_release(buffer) }
	for c in drm.crtcs { delete(c.props); free(c) }
	for p in drm.planes { delete(p.props); for f in p.formats { delete(f.modifiers) }; delete(p.formats); free(p) }
	session_destroy(b.session)
	delete(drm.retained); delete(drm.crtcs); delete(drm.planes); delete(drm.outputs); delete(drm.fbs); delete(drm.flips); delete(drm.path); free(drm)
}
