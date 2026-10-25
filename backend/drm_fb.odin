package backend

import d "../drm"
import "../gbm"
import "../gles"
import wl "../wayland"

DRM_FB :: struct { backend: ^DRM, buffer: ^gles.Buffer, id: u32, destroy: wl.Listener }
drm_fb_destroy :: proc(f: ^DRM_FB) {
	wl.unlisten(&f.destroy)
	if f.backend.base.drm_fd >= 0 { f.backend.ioctl(f.backend.base.drm_fd,d.DRM_IOCTL_MODE_RMFB,&f.id) }
	for other,i in f.backend.fbs { if other == f { ordered_remove(&f.backend.fbs,i); break } }; free(f)
}
drm_fb_buffer_destroyed :: proc(l: ^wl.Listener, data: rawptr) { drm_fb_destroy(wl.owner(l,DRM_FB,"destroy")) }
drm_fb :: proc(drm: ^DRM, b: ^gles.Buffer) -> u32 {
	for f in drm.fbs { if f.buffer == b { return f.id } }
	if b.n_planes < 1 || b.n_planes > 4 { return 0 }
	r := d.drm_mode_fb_cmd2{width=u32(b.width),height=u32(b.height),pixel_format=b.format}
	if b.modifier != gbm.INVALID {
		if !drm.modifiers && b.modifier != 0 { return 0 }
		if drm.modifiers { r.flags = d.DRM_MODE_FB_MODIFIERS }
	}
	defer for handle,i in r.handles {
		if handle == 0 { continue }; duplicate := false
		for previous in r.handles[:i] { if previous == handle { duplicate = true } }
		if !duplicate { close := d.drm_gem_close{handle=handle}; drm.ioctl(drm.base.drm_fd,d.DRM_IOCTL_GEM_CLOSE,&close) }
	}
	for plane,i in b.planes[:b.n_planes] {
		prime := d.drm_prime_handle{fd=plane.fd}
		if !drm.ioctl(drm.base.drm_fd,d.DRM_IOCTL_PRIME_FD_TO_HANDLE,&prime) { return 0 }
		r.handles[i],r.pitches[i],r.offsets[i] = prime.handle,plane.stride,plane.offset
		if r.flags != 0 { r.modifier[i] = b.modifier }
	}
	if !drm.ioctl(drm.base.drm_fd,d.DRM_IOCTL_MODE_ADDFB2,&r) { return 0 }
	f := new(DRM_FB); f.backend,f.buffer,f.id = drm,b,r.fb_id
	wl.listen(&b.events.destroy,&f.destroy,drm_fb_buffer_destroyed); append(&drm.fbs,f)
	return f.id
}
