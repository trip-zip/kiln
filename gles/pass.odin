package gles

import "core:fmt"
import gl "vendor:OpenGL"

Program :: struct {
	name:                                  u32,
	ramp_size, ramp, image, opaque, color: i32,
}

Pass :: struct {
	buffer:     ^Buffer,
	gamma:      u32,
	gamma_size: i32,
}

vertex_source :: `attribute vec2 position;
attribute vec2 uv;
varying vec2 texcoord;
void main() {
 gl_Position=vec4(position,0.0,1.0);
 texcoord=uv;
}`
gamma_source :: `precision highp float;
varying vec2 texcoord;
uniform sampler2D ramp;
uniform float ramp_size;
vec4 gamma_color(vec4 c) {
 if (ramp_size>0.0 && c.a>0.0) {
  vec3 v=clamp(c.rgb/c.a,0.0,1.0)*(1.0-1.0/ramp_size)+0.5/ramp_size;
  c.rgb=vec3(texture2D(ramp,vec2(v.r,0.5)).r,texture2D(ramp,vec2(v.g,0.5)).g,texture2D(ramp,vec2(v.b,0.5)).b)*c.a;
 }
 return c;
}
`
program :: proc(textured: bool) -> Program {
	fragment := gamma_source + `uniform vec4 color; void main(){gl_FragColor=gamma_color(color);}`
	if textured {
		fragment =
			gamma_source +
			`uniform sampler2D image;
uniform float opaque;
 void main() {
 vec4 c=texture2D(image,texcoord);
 c.a=mix(c.a,1.0,opaque);
 gl_FragColor=gamma_color(c);
}`
	}
	p := gl.CreateProgram()
	for source, i in ([]string{vertex_source, fragment}) {
		kind := u32(gl.VERTEX_SHADER)
		if i == 1 {kind = gl.FRAGMENT_SHADER}
		shader := gl.CreateShader(kind)
		ptr := cstring(raw_data(source))
		length := i32(len(source))
		gl.ShaderSource(shader, 1, &ptr, &length)
		gl.CompileShader(shader)
		status: i32
		gl.GetShaderiv(shader, gl.COMPILE_STATUS, &status)
		if status == 0 {
			log: [2048]u8
			gl.GetShaderInfoLog(shader, len(log), nil, &log[0])
			fmt.eprintf("GLES shader: %s\n", cstring(&log[0]))
			gl.DeleteShader(shader)
			gl.DeleteProgram(p)
			return {}
		}
		gl.AttachShader(p, shader)
		gl.DeleteShader(shader)
	}
	gl.BindAttribLocation(p, 0, "position")
	gl.BindAttribLocation(p, 1, "uv")
	gl.LinkProgram(p)
	status: i32
	gl.GetProgramiv(p, gl.LINK_STATUS, &status)
	if status == 0 {
		gl.DeleteProgram(p)
		return {}
	}
	return Program {
		name = p,
		ramp_size = gl.GetUniformLocation(p, "ramp_size"),
		ramp = gl.GetUniformLocation(p, "ramp"),
		image = gl.GetUniformLocation(p, "image"),
		opaque = gl.GetUniformLocation(p, "opaque"),
		color = gl.GetUniformLocation(p, "color"),
	}
}

begin :: proc(b: ^Buffer, gamma: Gamma = {}) -> (Pass, bool) {
	if b == nil || !current(b.renderer) {return {}, false}
	gl.BindFramebuffer(gl.FRAMEBUFFER, b.fbo)
	gl.Viewport(0, 0, b.width, b.height)
	gl.Enable(gl.SCISSOR_TEST)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
	gl.Enable(gl.DITHER)
	return Pass{buffer = b, gamma = gamma.name, gamma_size = gamma.size}, true
}

gamma_lut :: proc(table: []u16) -> []u8 {
	n := len(table) / 3
	out := make([]u8, n * 4)
	for i in 0 ..< n {
		for j in 0 ..< 3 {out[i * 4 + j] = u8((u32(table[j * n + i]) + 128) / 257)}
		out[i * 4 + 3] = 255
	}
	return out
}
// GBM row zero is the scanout top, so the projection maps GL y=0 to that row.
scissor :: proc(p: ^Pass, b: $B) {
	gl.Scissor(b.x, b.y, max(b.width, 0), max(b.height, 0))
}

clear :: proc(p: ^Pass, b: $B) {
	scissor(p, b)
	gl.ClearColor(0, 0, 0, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)
}

transform_invert :: proc(t: i32) -> i32 {
	if t & 1 != 0 && t & 4 == 0 {return t ~ 2}
	return t
}

transform_compose :: proc(a, b: i32) -> i32 {
	rot := a + b
	if b & 4 != 0 {rot = b - a}
	return ((a ~ b) & 4) | (rot & 3)
}

point :: proc(x, y: f32, t: i32) -> [2]f32 {
	switch t {
	case 1:
		return {1 - y, x}
	case 2:
		return {1 - x, 1 - y}
	case 3:
		return {y, 1 - x}
	case 4:
		return {1 - x, y}
	case 5:
		return {y, x}
	case 6:
		return {x, 1 - y}
	case 7:
		return {1 - y, 1 - x}
	}
	return {x, y}
}

transform_box :: proc(b: $B, t, w, h: i32) -> B {
	out := b
	if t % 2 != 0 {out.width, out.height = b.height, b.width}
	switch t {
	case 1:
		out.x, out.y = h - b.y - b.height, b.x
	case 2:
		out.x, out.y = w - b.x - b.width, h - b.y - b.height
	case 3:
		out.x, out.y = b.y, w - b.x - b.width
	case 4:
		out.x = w - b.x - b.width
	case 5:
		out.x, out.y = b.y, b.x
	case 6:
		out.y = h - b.y - b.height
	case 7:
		out.x, out.y = h - b.y - b.height, w - b.x - b.width
	}
	return out
}

quad :: proc(
	p: ^Pass,
	program: Program,
	box: Box,
	source: FBox,
	t: ^Texture,
	transform: i32,
	clips: []$B,
	color: [4]f32,
) {
	gl.UseProgram(program.name)
	gl.Uniform1f(program.ramp_size, f32(p.gamma_size))
	gl.Uniform1i(program.ramp, 1)
	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_2D, p.gamma)
	if t != nil {
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, t.name)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.Uniform1i(program.image, 0)
		gl.Uniform1f(program.opaque, f32(int(t.opaque)))
	} else {gl.Uniform4f(program.color, color[0], color[1], color[2], color[3])}
	vertices: [16]f32
	corners := [4][2]f32 {
		{0, 0},
		{1, 0},
		{0, 1},
		{1, 1},
	}
	for c, i in corners {
		vertices[i * 4] = 2 * (f32(box.x) + c[0] * f32(box.width)) / f32(p.buffer.width) - 1
		vertices[i * 4 + 1] = 2 * (f32(box.y) + c[1] * f32(box.height)) / f32(p.buffer.height) - 1
		uv := point(c[0], c[1], transform)
		if t != nil {
			vertices[i * 4 + 2] = f32((source.x + f64(uv[0]) * source.width) / f64(t.width))
			vertices[i * 4 + 3] = f32((source.y + f64(uv[1]) * source.height) / f64(t.height))
		}
	}
	gl.BindBuffer(gl.ARRAY_BUFFER, 0)
	gl.EnableVertexAttribArray(0)
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 16, uintptr(&vertices[0]))
	gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 16, uintptr(&vertices[2]))
	for clip in clips {
		scissor(p, clip)
		gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4)
	}
	gl.DisableVertexAttribArray(0)
	gl.DisableVertexAttribArray(1)
}

rect :: proc(p: ^Pass, box: $B, color: [4]f32, clip: []$C) {
	quad(p, p.buffer.renderer.rect_program, Box(box), {}, nil, 0, clip, color)
}

texture :: proc(
	p: ^Pass,
	t: ^Texture,
	source: $F,
	dest: $B,
	clip: []$C,
	transform: i32 = 0,
) {quad(p, p.buffer.renderer.texture_program, Box(dest), FBox(source), t, transform, clip, {})
}

submit :: proc(p: ^Pass) -> bool {
	r := p.buffer.renderer
	if r.lost {return false}
	gl.Flush()
	if r.reset_status != nil {
		status := r.reset_status()
		if status != gl.NO_ERROR {
			fmt.eprintf("GLES: GPU reset, context lost (0x%04x)\n", status)
			r.lost = true
			return false
		}
	}
	return gl.GetError() == gl.NO_ERROR
}

texture_parameters :: proc() {
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
}
