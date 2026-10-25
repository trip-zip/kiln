package scene_paint

import sf "../surfaces"

import "../gles"
import wl "../wayland"
import "../buffers"
import "base:runtime"

Source :: struct {
	scene:           ^Scene,
	surface:         ^sf.Surface,
	buffer:          ^buffers.Buffer,
	texture:         ^gles.Texture,
	commit, destroy: wl.Listener,
}

attach_compositor :: proc(s: ^Scene, c: ^sf.Compositor, r: ^gles.Renderer) {
	s.renderer = r
	wl.listen(&c.events.new_surface, &s.new_surface, source_added)
}

source_added :: proc (listener: ^wl.Listener, data: rawptr) {
	s := wl.owner(listener, Scene, "new_surface")
	context.allocator = s.allocator
	source := new(Source)
	source.scene = s
	source.surface = (^sf.Surface)(data)
	s.sources[source.surface] = source
	wl.listen(&source.surface.events.commit, &source.commit, source_committed)
	wl.listen(&source.surface.events.destroy, &source.destroy, source_destroyed)
}

source_committed :: proc (listener: ^wl.Listener, data: rawptr) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	source := wl.owner(listener, Source, "commit")
	s := source.scene
	context.allocator = s.allocator
	surface := source.surface
	b := surface.current.buffer
	// Commit listeners borrow the buffer before its immediate release.
	if b == nil && surface.current.width > 0 && surface.current.height > 0 {
		if source.texture != nil {b = source.texture.buffer} else {return}
		if b == nil {return}
	}
	if b != nil {
		boxes := sf.damage(surface)
		damage := make([]gles.Box, len(boxes), context.temp_allocator)
		for box, i in boxes {damage[i] = gles.Box(box)}
		gles.update(s.renderer, b, damage)
	}
	next := gles.texture_retain(gles.import_buffer(s.renderer, b))
	retained: ^buffers.Buffer
	if gles.needs_buffer(next) {retained = buffers.lock(b)}
	if source.buffer != nil {buffers.unlock(source.buffer)}
	gles.texture_release(source.texture)
	source.buffer, source.texture = retained, next
}

source_remove :: proc(source: ^Source) {
	context.allocator = source.scene.allocator
	wl.unlisten(&source.commit)
	wl.unlisten(&source.destroy)
	if source.buffer != nil {buffers.unlock(source.buffer)}
	gles.texture_release(source.texture)
	delete_key(&source.scene.sources, source.surface)
	free(source)
}

source_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
	source_remove(wl.owner(listener, Source, "destroy"))
}

surface_texture :: proc(o: ^Output, surface: ^sf.Surface) -> ^gles.Texture {
	source := o.scene.sources[surface]
	if source == nil {return nil}
	return source.texture
}
