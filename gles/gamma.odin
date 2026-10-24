package gles

import gl "vendor:OpenGL"

Gamma :: struct {
	renderer: ^Renderer,
	name:     u32,
	size:     i32,
	table:    []u16,
}

gamma_update :: proc(r: ^Renderer, gamma: ^Gamma, table: []u16) -> bool {
	if r.lost {return false}
	same := len(gamma.table) == len(table)
	if same {
		for v, i in table {
			if gamma.table[i] != v {
				same = false
				break
			}
		}
	}
	if same {return true}
	if !current(r) {return false}
	if len(table) == 0 {
		gamma_finish(gamma)
		return true
	}
	context.allocator = r.allocator
	data := gamma_lut(table)
	defer delete(data)
	if gamma.name == 0 {gl.GenTextures(1, &gamma.name)}
	gamma.renderer = r
	gamma.size = i32(len(table) / 3)
	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_2D, gamma.name)
	texture_parameters()
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RGBA,
		gamma.size,
		1,
		0,
		gl.RGBA,
		gl.UNSIGNED_BYTE,
		raw_data(data),
	)
	if gl.GetError() != gl.NO_ERROR {return false}
	delete(gamma.table)
	gamma.table = make([]u16, len(table))
	copy(gamma.table, table)
	return true
}

gamma_finish :: proc(gamma: ^Gamma) {
	if gamma.renderer != nil {
		context.allocator = gamma.renderer.allocator
		if current(gamma.renderer) {gl.DeleteTextures(1, &gamma.name)}
		delete(gamma.table)
	}
	gamma^ = {}
}
