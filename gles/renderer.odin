package gles

import "../gbm"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import gl "vendor:OpenGL"
import egl "vendor:egl"

Box :: struct {
	x, y, width, height: i32,
}

FBox :: struct {
	x, y, width, height: f64,
}

Renderer :: struct {
	device:                            ^gbm.Device,
	fd:                                i32,
	display:                           egl.Display,
	ctx:                               egl.Context,
	image_texture, image_renderbuffer: proc "c" (target: u32, image: egl.Image),
	query_formats:                     proc "c" (
		display: egl.Display,
		max: i32,
		formats: [^]i32,
		count: ^i32,
	) -> u32,
	query_modifiers:                   proc "c" (
		display: egl.Display,
		format: i32,
		max: i32,
		modifiers: [^]u64,
		external: [^]u32,
		count: ^i32,
	) -> u32,
	bgra, loaded:                      bool,
	rect_program, texture_program:     Program,
	formats:                           []i32,
	textures:                          map[rawptr]^Texture,
	rejected:                          map[u32]bool,
	allocator:                         runtime.Allocator,
}

has :: proc(extensions: string, name: string) -> bool {
	for word in strings.split(extensions, " ", context.temp_allocator) {
		if word == name {return true}
	}
	return false
}

current :: proc(r: ^Renderer) -> bool {
	return egl.MakeCurrent(r.display, egl.NO_SURFACE, egl.NO_SURFACE, r.ctx) != false
}

create :: proc(backend_fd: i32) -> ^Renderer {
	r := new(Renderer)
	r.fd = -1
	r.allocator = context.allocator
	ok := false
	defer {
		if !ok {destroy(r)}
	}
	if backend_fd >= 0 {
		r.fd = i32(posix.fcntl(posix.FD(backend_fd), .DUPFD_CLOEXEC, i32(0)))
	} else {
		for i in 128 ..< 256 {
			path := fmt.ctprintf("/dev/dri/renderD%d", i)
			r.fd = i32(posix.open(path, {.RDWR, .CLOEXEC}))
			if r.fd >= 0 {break}
		}
	}
	if r.fd < 0 {
		fmt.eprintln("GLES: no render node opens")
		return nil
	}
	r.device = gbm.create(r.fd)
	if r.device == nil {return nil}
	r.display = egl.GetPlatformDisplay(.GBM_KHR, r.device, nil)
	if egl.Initialize(r.display, nil, nil) == false {
		fmt.eprintln("GLES: EGL initialization failed")
		return nil
	}
	ext := string(egl.QueryString(r.display, egl.EXTENSIONS))
	for name in ([]string{"EGL_KHR_image_base", "EGL_EXT_image_dma_buf_import"}) {
		if !has(ext, name) {
			fmt.eprintf("GLES: required extension %s missing\n", name)
			return nil
		}
	}
	if egl.BindAPI(egl.OPENGL_ES_API) == false {return nil}
	attrs := [?]i32 {
		egl.SURFACE_TYPE,
		0,
		egl.RENDERABLE_TYPE,
		egl.OPENGL_ES2_BIT,
		egl.RED_SIZE,
		8,
		egl.GREEN_SIZE,
		8,
		egl.BLUE_SIZE,
		8,
		egl.NONE,
	}
	config: egl.Config
	count: i32
	if egl.ChooseConfig(r.display, &attrs[0], &config, 1, &count) == false ||
	   count == 0 {return nil}
	ctx := [?]i32{egl.CONTEXT_CLIENT_VERSION, 2, egl.NONE}
	r.ctx = egl.CreateContext(r.display, config, egl.NO_CONTEXT, &ctx[0])
	if r.ctx == egl.NO_CONTEXT || !current(r) {return nil}
	gl.load_up_to(3, 0, egl.gl_set_proc_address)
	r.loaded = true
	gl_ext := string(cstring(gl.GetString(gl.EXTENSIONS)))
	if !has(gl_ext, "GL_OES_EGL_image") {
		fmt.eprintln("GLES: required extension GL_OES_EGL_image missing")
		return nil
	}
	r.image_texture = cast(type_of(r.image_texture))egl.GetProcAddress(
		"glEGLImageTargetTexture2DOES",
	)
	r.image_renderbuffer = cast(type_of(r.image_renderbuffer))egl.GetProcAddress(
		"glEGLImageTargetRenderbufferStorageOES",
	)
	if r.image_texture == nil || r.image_renderbuffer == nil {
		fmt.eprintln("GLES: EGL image entry points unavailable")
		return nil
	}
	if has(ext, "EGL_EXT_image_dma_buf_import_modifiers") {
		r.query_formats = cast(type_of(r.query_formats))egl.GetProcAddress(
			"eglQueryDmaBufFormatsEXT",
		)
		r.query_modifiers = cast(type_of(r.query_modifiers))egl.GetProcAddress(
			"eglQueryDmaBufModifiersEXT",
		)
	}
	if r.query_formats != nil {
		n: i32
		if r.query_formats(r.display, 0, nil, &n) == 0 {return nil}
		r.formats = make([]i32, int(n))
		if r.query_formats(r.display, n, raw_data(r.formats), &n) == 0 {return nil}
		r.formats = r.formats[:n]
	}
	r.bgra = has(gl_ext, "GL_EXT_read_format_bgra")
	r.rect_program = program(false)
	r.texture_program = program(true)
	if r.rect_program.name == 0 || r.texture_program.name == 0 {return nil}
	r.textures = make(map[rawptr]^Texture)
	r.rejected = make(map[u32]bool)
	fmt.printf("GLES: %s; BGRA readback %v\n", cstring(gl.GetString(gl.RENDERER)), r.bgra)
	ok = true
	return r
}

destroy :: proc(r: ^Renderer) {
	if r == nil {return}
	context.allocator = r.allocator
	if r.ctx != egl.NO_CONTEXT {
		for len(r.textures) > 0 {
			for _, t in r.textures {
				texture_destroy(t)
				break
			}
		}
		if r.loaded && current(r) {
			gl.DeleteProgram(r.rect_program.name)
			gl.DeleteProgram(r.texture_program.name)
		}
		egl.MakeCurrent(r.display, egl.NO_SURFACE, egl.NO_SURFACE, egl.NO_CONTEXT)
		egl.DestroyContext(r.display, r.ctx)
	}
	delete(r.textures)
	delete(r.rejected)
	delete(r.formats)
	if r.display != egl.NO_DISPLAY {egl.Terminate(r.display)}
	egl.ReleaseThread()
	if r.device != nil {gbm.destroy(r.device)}
	if r.fd >= 0 {posix.close(posix.FD(r.fd))}
	free(r)
}

Plane :: struct {
	fd:             i32,
	stride, offset: u32,
}

image :: proc(
	r: ^Renderer,
	width, height: i32,
	format: u32,
	modifier: u64,
	planes: []Plane,
) -> egl.Image {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	attrs := make([dynamic]int, context.temp_allocator)
	append(
		&attrs,
		egl.WIDTH,
		int(width),
		egl.HEIGHT,
		int(height),
		EGL_LINUX_DRM_FOURCC_EXT,
		int(format),
	)
	plane_attrs := [4][5]int {
		{
			EGL_DMA_BUF_PLANE0_FD_EXT,
			EGL_DMA_BUF_PLANE0_OFFSET_EXT,
			EGL_DMA_BUF_PLANE0_PITCH_EXT,
			EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,
			EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,
		},
		{
			EGL_DMA_BUF_PLANE1_FD_EXT,
			EGL_DMA_BUF_PLANE1_OFFSET_EXT,
			EGL_DMA_BUF_PLANE1_PITCH_EXT,
			EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT,
			EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT,
		},
		{
			EGL_DMA_BUF_PLANE2_FD_EXT,
			EGL_DMA_BUF_PLANE2_OFFSET_EXT,
			EGL_DMA_BUF_PLANE2_PITCH_EXT,
			EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT,
			EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT,
		},
		{
			EGL_DMA_BUF_PLANE3_FD_EXT,
			EGL_DMA_BUF_PLANE3_OFFSET_EXT,
			EGL_DMA_BUF_PLANE3_PITCH_EXT,
			EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT,
			EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT,
		},
	}
	for p, i in planes {
		keys := plane_attrs[i]
		append(&attrs, keys[0], int(p.fd), keys[1], int(p.offset), keys[2], int(p.stride))
		if r.query_modifiers != nil && modifier != gbm.INVALID {
			append(&attrs, keys[3], int(u32(modifier)), keys[4], int(u32(modifier >> 32)))
		}
	}
	append(&attrs, egl.NONE)
	return egl.CreateImage(r.display, egl.NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nil, raw_data(attrs))
}

modifiers :: proc(r: ^Renderer, format: u32, offered: []u64) -> []u64 {
	result := make([dynamic]u64, context.temp_allocator)
	if r.query_modifiers == nil {
		for m in offered {
			if m == 0 || m == gbm.INVALID {append(&result, m)}
		}
		return result[:]
	}
	n: i32
	if r.query_modifiers(r.display, i32(format), 0, nil, nil, &n) == 0 {return nil}
	mods := make([]u64, int(n), context.temp_allocator)
	ext := make([]u32, int(n), context.temp_allocator)
	if r.query_modifiers(r.display, i32(format), n, raw_data(mods), raw_data(ext), &n) == 0 {return nil}
	for m in offered {
		if m == gbm.INVALID {
			append(&result, m)
			continue
		}
		for v, i in mods {
			if v == m && ext[i] == 0 {
				append(&result, m)
				break
			}
		}
	}
	return result[:]
}
