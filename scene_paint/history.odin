package scene_paint

import gles "../gles"
import wl "../wayland"

// History borrows buffers so it cannot keep a swapchain slot acquired.
Buffer_History :: struct {
	output:    ^Output,
	buffer:    ^gles.Buffer,
	boxes:     [dynamic]gles.Box,
	destroy:   wl.Listener,
	presented: bool,
}

history_remove :: proc(h: ^Buffer_History) {
	context.allocator = h.output.scene.allocator
	wl.unlisten(&h.destroy)
	for other, i in h.output.history {
		if other == h {
			ordered_remove(&h.output.history, i)
			break
		}
	}
	delete(h.boxes)
	free(h)
}

history_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
	history_remove(wl.owner(listener, Buffer_History, "destroy"))
}

history_prune :: proc(o: ^Output) {
	for i := len(o.history) - 1; i >= 0; i -= 1 {
		h := o.history[i]
		found := false
		for b in o.swapchain.buffers {
			if b == h.buffer {
				found = true
				break
			}
		}
		if !found {history_remove(h)}
	}
}

history_acquire :: proc(o: ^Output, buffer: ^gles.Buffer) -> ^Buffer_History {
	for h in o.history {
		if h.buffer == buffer {return h}
	}
	context.allocator = o.scene.allocator
	h := new(Buffer_History)
	h.output, h.buffer = o, buffer
	wl.listen(&buffer.events.destroy, &h.destroy, history_destroyed)
	append(&o.history, h)
	return h
}

history_repaint :: proc(h: ^Buffer_History) -> [dynamic]gles.Box {
	boxes := make([dynamic]gles.Box, context.temp_allocator)
	if h.presented {
		append(&boxes, ..h.boxes[:])
		append(&boxes, ..h.output.damage[:])
	} else {
		append(&boxes, gles.Box{0, 0, h.output.width, h.output.height})
	}
	return boxes
}
// Failed passes keep their damage queued; only a successful presentation advances history.
history_presented :: proc(h: ^Buffer_History) {
	for other in h.output.history {
		if other != h {append(&other.boxes, ..h.output.damage[:])}
	}
	clear(&h.boxes)
	h.presented = true
}
