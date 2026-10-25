package drm

import "core:sys/linux"

ioctl :: proc(fd: i32, request: uint, data: rawptr) -> bool { return int(linux.ioctl(linux.Fd(fd),u32(request),uintptr(data))) >= 0 }

drm_get_cap :: struct {
	capability: u64,
	value: u64,
}
#assert(size_of(drm_get_cap) == 16 && align_of(drm_get_cap) == 8)
#assert(offset_of(drm_get_cap,capability) == 0 && offset_of(drm_get_cap,value) == 8)

drm_set_client_cap :: struct {
	capability: u64,
	value: u64,
}
#assert(size_of(drm_set_client_cap) == 16 && align_of(drm_set_client_cap) == 8)
#assert(offset_of(drm_set_client_cap,capability) == 0 && offset_of(drm_set_client_cap,value) == 8)

drm_prime_handle :: struct {
	handle: u32,
	flags: u32,
	fd: i32,
}
#assert(size_of(drm_prime_handle) == 12 && align_of(drm_prime_handle) == 4)
#assert(offset_of(drm_prime_handle,handle) == 0 && offset_of(drm_prime_handle,flags) == 4 && offset_of(drm_prime_handle,fd) == 8)

drm_gem_close :: struct {
	handle: u32,
	pad: u32,
}
#assert(size_of(drm_gem_close) == 8 && align_of(drm_gem_close) == 4)
#assert(offset_of(drm_gem_close,handle) == 0 && offset_of(drm_gem_close,pad) == 4)

drm_mode_modeinfo :: struct {
	clock: u32,
	hdisplay: u16,
	hsync_start: u16,
	hsync_end: u16,
	htotal: u16,
	hskew: u16,
	vdisplay: u16,
	vsync_start: u16,
	vsync_end: u16,
	vtotal: u16,
	vscan: u16,
	vrefresh: u32,
	flags: u32,
	type: u32,
	name: [32]u8,
}
#assert(size_of(drm_mode_modeinfo) == 68 && align_of(drm_mode_modeinfo) == 4)
#assert(offset_of(drm_mode_modeinfo,clock) == 0 && offset_of(drm_mode_modeinfo,hdisplay) == 4 && offset_of(drm_mode_modeinfo,hsync_start) == 6)
#assert(offset_of(drm_mode_modeinfo,hsync_end) == 8 && offset_of(drm_mode_modeinfo,htotal) == 10 && offset_of(drm_mode_modeinfo,hskew) == 12)
#assert(offset_of(drm_mode_modeinfo,vdisplay) == 14 && offset_of(drm_mode_modeinfo,vsync_start) == 16 && offset_of(drm_mode_modeinfo,vsync_end) == 18)
#assert(offset_of(drm_mode_modeinfo,vtotal) == 20 && offset_of(drm_mode_modeinfo,vscan) == 22 && offset_of(drm_mode_modeinfo,vrefresh) == 24)
#assert(offset_of(drm_mode_modeinfo,flags) == 28 && offset_of(drm_mode_modeinfo,type) == 32 && offset_of(drm_mode_modeinfo,name) == 36)

drm_mode_card_res :: struct {
	fb_id_ptr: u64,
	crtc_id_ptr: u64,
	connector_id_ptr: u64,
	encoder_id_ptr: u64,
	count_fbs: u32,
	count_crtcs: u32,
	count_connectors: u32,
	count_encoders: u32,
	min_width: u32,
	max_width: u32,
	min_height: u32,
	max_height: u32,
}
#assert(size_of(drm_mode_card_res) == 64 && align_of(drm_mode_card_res) == 8)
#assert(offset_of(drm_mode_card_res,fb_id_ptr) == 0 && offset_of(drm_mode_card_res,crtc_id_ptr) == 8 && offset_of(drm_mode_card_res,connector_id_ptr) == 16)
#assert(offset_of(drm_mode_card_res,encoder_id_ptr) == 24 && offset_of(drm_mode_card_res,count_fbs) == 32 && offset_of(drm_mode_card_res,count_crtcs) == 36)
#assert(offset_of(drm_mode_card_res,count_connectors) == 40 && offset_of(drm_mode_card_res,count_encoders) == 44 && offset_of(drm_mode_card_res,min_width) == 48)
#assert(offset_of(drm_mode_card_res,max_width) == 52 && offset_of(drm_mode_card_res,min_height) == 56 && offset_of(drm_mode_card_res,max_height) == 60)

drm_mode_get_encoder :: struct {
	encoder_id: u32,
	encoder_type: u32,
	crtc_id: u32,
	possible_crtcs: u32,
	possible_clones: u32,
}
#assert(size_of(drm_mode_get_encoder) == 20 && align_of(drm_mode_get_encoder) == 4)
#assert(offset_of(drm_mode_get_encoder,encoder_id) == 0 && offset_of(drm_mode_get_encoder,encoder_type) == 4 && offset_of(drm_mode_get_encoder,crtc_id) == 8)
#assert(offset_of(drm_mode_get_encoder,possible_crtcs) == 12 && offset_of(drm_mode_get_encoder,possible_clones) == 16)

drm_mode_get_connector :: struct {
	encoders_ptr: u64,
	modes_ptr: u64,
	props_ptr: u64,
	prop_values_ptr: u64,
	count_modes: u32,
	count_props: u32,
	count_encoders: u32,
	encoder_id: u32,
	connector_id: u32,
	connector_type: u32,
	connector_type_id: u32,
	connection: u32,
	mm_width: u32,
	mm_height: u32,
	subpixel: u32,
	pad: u32,
}
#assert(size_of(drm_mode_get_connector) == 80 && align_of(drm_mode_get_connector) == 8)
#assert(offset_of(drm_mode_get_connector,encoders_ptr) == 0 && offset_of(drm_mode_get_connector,modes_ptr) == 8 && offset_of(drm_mode_get_connector,props_ptr) == 16)
#assert(offset_of(drm_mode_get_connector,prop_values_ptr) == 24 && offset_of(drm_mode_get_connector,count_modes) == 32 && offset_of(drm_mode_get_connector,count_props) == 36)
#assert(offset_of(drm_mode_get_connector,count_encoders) == 40 && offset_of(drm_mode_get_connector,encoder_id) == 44 && offset_of(drm_mode_get_connector,connector_id) == 48)
#assert(offset_of(drm_mode_get_connector,connector_type) == 52 && offset_of(drm_mode_get_connector,connector_type_id) == 56 && offset_of(drm_mode_get_connector,connection) == 60)
#assert(offset_of(drm_mode_get_connector,mm_width) == 64 && offset_of(drm_mode_get_connector,mm_height) == 68 && offset_of(drm_mode_get_connector,subpixel) == 72)
#assert(offset_of(drm_mode_get_connector,pad) == 76)

drm_mode_get_plane_res :: struct {
	plane_id_ptr: u64,
	count_planes: u32,
}
#assert(size_of(drm_mode_get_plane_res) == 16 && align_of(drm_mode_get_plane_res) == 8)
#assert(offset_of(drm_mode_get_plane_res,plane_id_ptr) == 0 && offset_of(drm_mode_get_plane_res,count_planes) == 8)

drm_mode_get_plane :: struct {
	plane_id: u32,
	crtc_id: u32,
	fb_id: u32,
	possible_crtcs: u32,
	gamma_size: u32,
	count_format_types: u32,
	format_type_ptr: u64,
}
#assert(size_of(drm_mode_get_plane) == 32 && align_of(drm_mode_get_plane) == 8)
#assert(offset_of(drm_mode_get_plane,plane_id) == 0 && offset_of(drm_mode_get_plane,crtc_id) == 4 && offset_of(drm_mode_get_plane,fb_id) == 8)
#assert(offset_of(drm_mode_get_plane,possible_crtcs) == 12 && offset_of(drm_mode_get_plane,gamma_size) == 16 && offset_of(drm_mode_get_plane,count_format_types) == 20)
#assert(offset_of(drm_mode_get_plane,format_type_ptr) == 24)

drm_mode_obj_get_properties :: struct {
	props_ptr: u64,
	prop_values_ptr: u64,
	count_props: u32,
	obj_id: u32,
	obj_type: u32,
}
#assert(size_of(drm_mode_obj_get_properties) == 32 && align_of(drm_mode_obj_get_properties) == 8)
#assert(offset_of(drm_mode_obj_get_properties,props_ptr) == 0 && offset_of(drm_mode_obj_get_properties,prop_values_ptr) == 8 && offset_of(drm_mode_obj_get_properties,count_props) == 16)
#assert(offset_of(drm_mode_obj_get_properties,obj_id) == 20 && offset_of(drm_mode_obj_get_properties,obj_type) == 24)

drm_mode_get_property :: struct {
	values_ptr: u64,
	enum_blob_ptr: u64,
	prop_id: u32,
	flags: u32,
	name: [32]u8,
	count_values: u32,
	count_enum_blobs: u32,
}
#assert(size_of(drm_mode_get_property) == 64 && align_of(drm_mode_get_property) == 8)
#assert(offset_of(drm_mode_get_property,values_ptr) == 0 && offset_of(drm_mode_get_property,enum_blob_ptr) == 8 && offset_of(drm_mode_get_property,prop_id) == 16)
#assert(offset_of(drm_mode_get_property,flags) == 20 && offset_of(drm_mode_get_property,name) == 24 && offset_of(drm_mode_get_property,count_values) == 56)
#assert(offset_of(drm_mode_get_property,count_enum_blobs) == 60)

drm_mode_get_blob :: struct {
	blob_id: u32,
	length: u32,
	data: u64,
}
#assert(size_of(drm_mode_get_blob) == 16 && align_of(drm_mode_get_blob) == 8)
#assert(offset_of(drm_mode_get_blob,blob_id) == 0 && offset_of(drm_mode_get_blob,length) == 4 && offset_of(drm_mode_get_blob,data) == 8)

drm_mode_atomic :: struct {
	flags: u32,
	count_objs: u32,
	objs_ptr: u64,
	count_props_ptr: u64,
	props_ptr: u64,
	prop_values_ptr: u64,
	reserved: u64,
	user_data: u64,
}
#assert(size_of(drm_mode_atomic) == 56 && align_of(drm_mode_atomic) == 8)
#assert(offset_of(drm_mode_atomic,flags) == 0 && offset_of(drm_mode_atomic,count_objs) == 4 && offset_of(drm_mode_atomic,objs_ptr) == 8)
#assert(offset_of(drm_mode_atomic,count_props_ptr) == 16 && offset_of(drm_mode_atomic,props_ptr) == 24 && offset_of(drm_mode_atomic,prop_values_ptr) == 32)
#assert(offset_of(drm_mode_atomic,reserved) == 40 && offset_of(drm_mode_atomic,user_data) == 48)

drm_mode_fb_cmd2 :: struct {
	fb_id: u32,
	width: u32,
	height: u32,
	pixel_format: u32,
	flags: u32,
	handles: [4]u32,
	pitches: [4]u32,
	offsets: [4]u32,
	modifier: [4]u64,
}
#assert(size_of(drm_mode_fb_cmd2) == 104 && align_of(drm_mode_fb_cmd2) == 8)
#assert(offset_of(drm_mode_fb_cmd2,fb_id) == 0 && offset_of(drm_mode_fb_cmd2,width) == 4 && offset_of(drm_mode_fb_cmd2,height) == 8)
#assert(offset_of(drm_mode_fb_cmd2,pixel_format) == 12 && offset_of(drm_mode_fb_cmd2,flags) == 16 && offset_of(drm_mode_fb_cmd2,handles) == 20)
#assert(offset_of(drm_mode_fb_cmd2,pitches) == 36 && offset_of(drm_mode_fb_cmd2,offsets) == 52 && offset_of(drm_mode_fb_cmd2,modifier) == 72)

drm_mode_create_blob :: struct {
	data: u64,
	length: u32,
	blob_id: u32,
}
#assert(size_of(drm_mode_create_blob) == 16 && align_of(drm_mode_create_blob) == 8)
#assert(offset_of(drm_mode_create_blob,data) == 0 && offset_of(drm_mode_create_blob,length) == 8 && offset_of(drm_mode_create_blob,blob_id) == 12)

drm_mode_destroy_blob :: struct {
	blob_id: u32,
}
#assert(size_of(drm_mode_destroy_blob) == 4 && align_of(drm_mode_destroy_blob) == 4)
#assert(offset_of(drm_mode_destroy_blob,blob_id) == 0)

drm_event :: struct {
	type: u32,
	length: u32,
}
#assert(size_of(drm_event) == 8 && align_of(drm_event) == 4)
#assert(offset_of(drm_event,type) == 0 && offset_of(drm_event,length) == 4)

drm_event_vblank :: struct {
	base: drm_event,
	user_data: u64,
	tv_sec: u32,
	tv_usec: u32,
	sequence: u32,
	crtc_id: u32,
}
#assert(size_of(drm_event_vblank) == 32 && align_of(drm_event_vblank) == 8)
#assert(offset_of(drm_event_vblank,base) == 0 && offset_of(drm_event_vblank,user_data) == 8 && offset_of(drm_event_vblank,tv_sec) == 16)
#assert(offset_of(drm_event_vblank,tv_usec) == 20 && offset_of(drm_event_vblank,sequence) == 24 && offset_of(drm_event_vblank,crtc_id) == 28)

drm_format_modifier_blob :: struct {
	version: u32,
	flags: u32,
	count_formats: u32,
	formats_offset: u32,
	count_modifiers: u32,
	modifiers_offset: u32,
}
#assert(size_of(drm_format_modifier_blob) == 24 && align_of(drm_format_modifier_blob) == 4)
#assert(offset_of(drm_format_modifier_blob,version) == 0 && offset_of(drm_format_modifier_blob,flags) == 4 && offset_of(drm_format_modifier_blob,count_formats) == 8)
#assert(offset_of(drm_format_modifier_blob,formats_offset) == 12 && offset_of(drm_format_modifier_blob,count_modifiers) == 16 && offset_of(drm_format_modifier_blob,modifiers_offset) == 20)

drm_format_modifier :: struct {
	formats: u64,
	offset: u32,
	pad: u32,
	modifier: u64,
}
#assert(size_of(drm_format_modifier) == 24 && align_of(drm_format_modifier) == 8)
#assert(offset_of(drm_format_modifier,formats) == 0 && offset_of(drm_format_modifier,offset) == 8 && offset_of(drm_format_modifier,pad) == 12)
#assert(offset_of(drm_format_modifier,modifier) == 16)

DRM_IOCTL_GET_CAP :: 3222299660
DRM_IOCTL_SET_CLIENT_CAP :: 1074816013
DRM_IOCTL_PRIME_FD_TO_HANDLE :: 3222037550
DRM_IOCTL_GEM_CLOSE :: 1074291721
DRM_IOCTL_MODE_GETRESOURCES :: 3225445536
DRM_IOCTL_MODE_GETCONNECTOR :: 3226494119
DRM_IOCTL_MODE_GETENCODER :: 3222561958
DRM_IOCTL_MODE_GETPLANERESOURCES :: 3222299829
DRM_IOCTL_MODE_GETPLANE :: 3223348406
DRM_IOCTL_MODE_OBJ_GETPROPERTIES :: 3223348409
DRM_IOCTL_MODE_GETPROPERTY :: 3225445546
DRM_IOCTL_MODE_GETPROPBLOB :: 3222299820
DRM_IOCTL_MODE_ATOMIC :: 3224921276
DRM_IOCTL_MODE_ADDFB2 :: 3228067000
DRM_IOCTL_MODE_RMFB :: 3221513391
DRM_IOCTL_MODE_CREATEPROPBLOB :: 3222299837
DRM_IOCTL_MODE_DESTROYPROPBLOB :: 3221513406
DRM_CLIENT_CAP_UNIVERSAL_PLANES :: 2
DRM_CLIENT_CAP_ATOMIC :: 3
DRM_CLIENT_CAP_CURSOR_PLANE_HOTSPOT :: 6
DRM_CAP_ADDFB2_MODIFIERS :: 16
DRM_CAP_CURSOR_WIDTH :: 8
DRM_CAP_CURSOR_HEIGHT :: 9
DRM_CAP_TIMESTAMP_MONOTONIC :: 6
DRM_CAP_CRTC_IN_VBLANK_EVENT :: 18
DRM_MODE_OBJECT_CRTC :: 3435973836
DRM_MODE_OBJECT_CONNECTOR :: 3233857728
DRM_MODE_OBJECT_PLANE :: 4008636142
DRM_MODE_ATOMIC_TEST_ONLY :: 256
DRM_MODE_ATOMIC_NONBLOCK :: 512
DRM_MODE_ATOMIC_ALLOW_MODESET :: 1024
DRM_MODE_PAGE_FLIP_EVENT :: 1
DRM_MODE_FB_MODIFIERS :: 2
DRM_MODE_TYPE_PREFERRED :: 8
DRM_MODE_FLAG_INTERLACE :: 16
DRM_MODE_FLAG_DBLSCAN :: 32
DRM_EVENT_FLIP_COMPLETE :: 2
