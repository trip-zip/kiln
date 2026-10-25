package buffers

import wl "../wayland"
import p "../protocols"
import "core:sys/linux"
import "core:sys/posix"

Params :: struct { manager: ^Dmabuf, attrs: Dmabuf_Attributes, used: bool }
Dmabuf_Buffer :: struct { resource: Resource, attrs: Dmabuf_Attributes }
Prime_Handle :: struct { handle, flags: u32, fd: i32 }
Gem_Close :: struct { handle, pad: u32 }
#assert(size_of(Prime_Handle) == 12 && align_of(Prime_Handle) == 4 && offset_of(Prime_Handle, handle) == 0 && offset_of(Prime_Handle, flags) == 4 && offset_of(Prime_Handle, fd) == 8)
#assert(size_of(Gem_Close) == 8 && align_of(Gem_Close) == 4 && offset_of(Gem_Close, handle) == 0 && offset_of(Gem_Close, pad) == 4)
close_planes :: proc(a: ^Dmabuf_Attributes) { for &fd in a.fd { if fd >= 0 { posix.close(posix.FD(fd)); fd = -1 } } }
dmabuf_buffer_destroy :: proc(base: ^Buffer) { b := cast(^Dmabuf_Buffer)base; close_planes(&b.attrs); free(b) }
dmabuf_attributes :: proc(base: ^Buffer) -> (Dmabuf_Attributes, bool) { return (cast(^Dmabuf_Buffer)base).attrs, true }
params_destroy :: proc(r: ^wl.Resource) { params := cast(^Params)r.data; close_planes(&params.attrs); free(params) }
params_error :: proc(r: ^wl.Resource, code: p.Zwp_Linux_Buffer_Params_V1_Error, message: string) { wl.post_error(r, u32(code), message) }
params_request :: proc(r: ^wl.Resource, op: p.Zwp_Linux_Buffer_Params_V1_Request, args: []wl.Argument) {
	params := cast(^Params)r.data
	if op == .destroy { wl.resource_destroy(r); return }
	if op == .add {
		fd, plane := i32(args[0].(wl.Fd)), u32(args[1].(wl.Uint))
		accepted := false
		defer if !accepted { posix.close(posix.FD(fd)) }
		if params.used { params_error(r, .already_used, "params already used"); return }
		if plane >= 4 { params_error(r, .plane_idx, "invalid plane index"); return }
		if params.attrs.fd[plane] >= 0 { params_error(r, .plane_set, "plane already set"); return }
		modifier := u64(args[4].(wl.Uint))<<32 | u64(args[5].(wl.Uint))
		if params.attrs.n_planes > 0 && params.attrs.modifier != modifier { params_error(r, .invalid_format, "plane modifiers differ"); return }
		params.attrs.fd[plane], params.attrs.modifier = fd, modifier
		params.attrs.offset[plane], params.attrs.stride[plane] = u32(args[2].(wl.Uint)), u32(args[3].(wl.Uint))
		params.attrs.n_planes += 1; accepted = true
		return
	}
	if params.used { params_error(r, .already_used, "params already used"); return }
	params.used = true
	id: u32
	a := args
	if op == .create_immed { id = u32(a[0].(wl.New_Id)); a = a[1:] }
	attrs := params.attrs
	params.attrs.fd = {-1, -1, -1, -1}
	defer close_planes(&attrs)
	attrs.width, attrs.height, attrs.format = i32(a[0].(wl.Int)), i32(a[1].(wl.Int)), u32(a[2].(wl.Uint))
	if attrs.n_planes == 0 { params_error(r, .incomplete, "no planes"); return }
	for i in 0..<attrs.n_planes { if attrs.fd[i] < 0 { params_error(r, .incomplete, "missing plane"); return } }
	if attrs.width <= 0 || attrs.height <= 0 { params_error(r, .invalid_dimensions, "invalid dimensions"); return }
	if u32(a[3].(wl.Uint)) != 0 || !offered(params.manager, attrs.format, attrs.modifier) { params_error(r, .invalid_format, "unsupported format, modifier or flags"); return }
	for i in 0..<attrs.n_planes {
		extent := u64(attrs.offset[i]) + u64(attrs.stride[i])*u64(attrs.height)
		size := posix.lseek(posix.FD(attrs.fd[i]), 0, .END)
		// Auxiliary planes may have fewer rows than the RGB image.
		minimum := extent if i == 0 else u64(attrs.offset[i])+u64(attrs.stride[i])
		if extent > u64(max(u32)) || (size >= 0 && (attrs.stride[i] == 0 || minimum > u64(size))) {
			params_error(r, .out_of_bounds, "plane exceeds buffer"); return
		}
	}
	if !check_import(params.manager.check_fd, &attrs) {
		if id == 0 { wl.post(r, u32(p.Zwp_Linux_Buffer_Params_V1_Event.failed)) } else { params_error(r, .invalid_wl_buffer, "dmabuf import failed") }
		return
	}
	b := new(Dmabuf_Buffer)
	init(&b.resource.base, attrs.width, attrs.height)
	b.resource.base.destroy, b.resource.base.dmabuf = dmabuf_buffer_destroy, dmabuf_attributes
	b.attrs = attrs; attrs.fd = {-1, -1, -1, -1}
	if !resource_create(&b.resource, r.client, id) { return }
	if id == 0 { wl.post(r, u32(p.Zwp_Linux_Buffer_Params_V1_Event.created), wl.Object(b.resource.resource)) }
}
check_import :: proc(fd: i32, a: ^Dmabuf_Attributes) -> bool {
	if fd < 0 { return true }
	for i in 0..<a.n_planes {
		prime := Prime_Handle{fd = a.fd[i]}
		if int(linux.ioctl(linux.Fd(fd), 0xC00C642E, uintptr(&prime))) < 0 { return false }
		close := Gem_Close{handle = prime.handle}
		if int(linux.ioctl(linux.Fd(fd), 0x40086409, uintptr(&close))) < 0 { return false }
	}
	return true
}
