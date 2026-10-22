package layout

Clip :: struct {
	box:                  Box,
	horizontal, vertical: bool,
}
intersect_clip :: proc(a, b: Clip) -> Clip {
	r := a
	if b.horizontal {
		far := b.box.x + b.box.width
		if a.horizontal {far = min(far, a.box.x + a.box.width)}
		r.box.x = a.horizontal ? max(a.box.x, b.box.x) : b.box.x
		r.box.width = max(0, far - r.box.x)
		r.horizontal = true
	}
	if b.vertical {
		far := b.box.y + b.box.height
		if a.vertical {far = min(far, a.box.y + a.box.height)}
		r.box.y = a.vertical ? max(a.box.y, b.box.y) : b.box.y
		r.box.height = max(0, far - r.box.y)
		r.vertical = true
	}
	return r
}
crop :: proc(b: Box, clip: Clip) -> Box {
	return intersect_clip(Clip{b, true, true}, clip).box
}
