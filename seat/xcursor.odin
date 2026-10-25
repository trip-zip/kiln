package seat

import "core:os"
import "core:strings"
import "core:fmt"
import "core:math"

Cursor_Image :: struct { width, height, hotspot_x, hotspot_y, delay: u32, buffer: []u8 }
Cursor :: struct { images: [dynamic]^Cursor_Image }
Cursor_Cache :: struct { name: string, size: u32, cursor: ^Cursor }
Cursor_Manager :: struct { name: string, size: u32, paths: [dynamic]string, cache: [dynamic]Cursor_Cache }
xcursor_word :: proc(bytes: []u8, at: int) -> u32 {
	return u32(bytes[at]) | u32(bytes[at+1])<<8 | u32(bytes[at+2])<<16 | u32(bytes[at+3])<<24
}
xcursor_parse :: proc(bytes: []u8, size: u32) -> ^Cursor {
	if len(bytes) < 16 || string(bytes[:4]) != "Xcur" { return nil }
	header, count := int(xcursor_word(bytes, 4)), int(xcursor_word(bytes, 12))
	if header < 16 || header > len(bytes) || count > 65536 || count > (len(bytes)-header)/12 { return nil }
	best, distance := u32(0), max(i64)
	for i in 0..<count {
		at := header+i*12
		if xcursor_word(bytes, at) != 0xfffd0002 { continue }
		nominal := xcursor_word(bytes, at+4)
		diff := abs(i64(nominal)-i64(size))
		if diff < distance { best, distance = nominal, diff }
	}
	if distance == max(i64) { return nil }
	cursor := new(Cursor)
	ok := false
	defer if !ok { xcursor_destroy(cursor) }
	for i in 0..<count {
		at := header+i*12
		if xcursor_word(bytes, at) != 0xfffd0002 || xcursor_word(bytes, at+4) != best { continue }
		chunk := int(xcursor_word(bytes, at+8))
		if chunk > len(bytes)-36 { return nil }
		length := int(xcursor_word(bytes, chunk))
		if length < 36 || length > len(bytes)-chunk || xcursor_word(bytes, chunk+4) != 0xfffd0002 || xcursor_word(bytes, chunk+8) != best { return nil }
		w, h, hx, hy := xcursor_word(bytes, chunk+16), xcursor_word(bytes, chunk+20), xcursor_word(bytes, chunk+24), xcursor_word(bytes, chunk+28)
		if w == 0 || h == 0 || w > 32767 || h > 32767 || hx >= w || hy >= h || u64(w)*u64(h)*4 > u64(len(bytes)-chunk-length) { return nil }
		frame := new(Cursor_Image)
		frame^ = {w,h,hx,hy,xcursor_word(bytes, chunk+32),make([]u8,int(w)*int(h)*4)}
		copy(frame.buffer, bytes[chunk+length:][:len(frame.buffer)])
		append(&cursor.images, frame)
	}
	ok = len(cursor.images) > 0
	return cursor if ok else nil
}
xcursor_destroy :: proc(cursor: ^Cursor) {
	if cursor == nil { return }
	for frame in cursor.images { delete(frame.buffer); free(frame) }
	delete(cursor.images); free(cursor)
}
xcursor_manager_create :: proc(name: cstring, size: u32) -> ^Cursor_Manager {
	if size == 0 { return nil }
	m := new(Cursor_Manager)
	m.name, m.size = strings.clone(string(name) if name != nil else "default"), size
	home := os.get_env("HOME", context.temp_allocator)
	path := os.get_env("XCURSOR_PATH", context.temp_allocator)
	if path == "" {
		data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
		if !strings.has_prefix(data,"/") { data = fmt.tprintf("%s/.local/share",home) }
		path = fmt.tprintf("%s/icons:~/.icons:/usr/share/icons:/usr/share/pixmaps:~/.cursors:/usr/share/cursors/xorg-x11:/usr/X11R6/lib/X11/icons",data)
	}
	for dir in strings.split(path, ":", context.temp_allocator) {
		if strings.has_prefix(dir,"~/") { append(&m.paths, fmt.aprintf("%s/%s",home,dir[2:])) }
		else if dir != "" { append(&m.paths, strings.clone(dir)) }
	}
	return m
}
xcursor_manager_destroy :: proc(m: ^Cursor_Manager) {
	if m == nil { return }
	for entry in m.cache { delete(entry.name); xcursor_destroy(entry.cursor) }
	for path in m.paths { delete(path) }
	delete(m.paths); delete(m.cache); delete(m.name); free(m)
}
xcursor_find :: proc(m: ^Cursor_Manager, theme, name: string, size: u32, visited: ^[dynamic]string) -> ^Cursor {
	if len(visited^) >= 32 { return nil }
	for seen in visited^ { if seen == theme { return nil } }
	append(visited, strings.clone(theme, context.temp_allocator))
	parents := make([dynamic]string, context.temp_allocator)
	for path in m.paths {
		filename := fmt.tprintf("%s/%s/cursors/%s",path,theme,name)
		if bytes, ok := os.read_entire_file(filename, context.allocator); ok == nil {
			cursor := xcursor_parse(bytes, size); delete(bytes)
			if cursor != nil { return cursor }
		}
		if bytes, ok := os.read_entire_file(fmt.tprintf("%s/%s/index.theme",path,theme), context.allocator); ok == nil {
			for line in strings.split_lines(string(bytes), context.temp_allocator) {
				trimmed := strings.trim_space(line)
				if !strings.has_prefix(trimmed,"Inherits") { continue }
				parts := strings.split(trimmed,"=",context.temp_allocator)
				if len(parts) != 2 || strings.trim_space(parts[0]) != "Inherits" { continue }
				for parent in strings.fields_proc(parts[1], proc(c: rune)->bool { return c == ',' || c == ';' || c == ':' || c == ' ' || c == '\t' }, context.temp_allocator) {
					append(&parents, strings.clone(parent,context.temp_allocator))
				}
			}
			delete(bytes)
		}
	}
	for parent in parents { if cursor := xcursor_find(m,parent,name,size,visited); cursor != nil { return cursor } }
	return nil
}
xcursor_manager_get_xcursor :: proc(m: ^Cursor_Manager, name: cstring, scale: f32) -> ^Cursor {
	if m == nil || name == nil || scale <= 0 || math.is_nan(scale) || math.is_inf(scale) || f64(m.size)*f64(scale) > f64(max(u32)) { return nil }
	size := max(1,u32(f64(m.size)*f64(scale)))
	for entry in m.cache { if entry.size == size && entry.name == string(name) { return entry.cursor } }
	visited := make([dynamic]string, context.temp_allocator)
	cursor := xcursor_find(m,m.name,string(name),size,&visited)
	if cursor == nil { cursor = xcursor_find(m,"default",string(name),size,&visited) }
	append(&m.cache, Cursor_Cache{strings.clone(string(name)),size,cursor})
	return cursor
}
xcursor_manager_load :: proc(m: ^Cursor_Manager, scale: f32) -> bool { return xcursor_manager_get_xcursor(m,"default",scale) != nil }
