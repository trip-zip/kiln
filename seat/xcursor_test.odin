package seat

import "core:os"
import "core:fmt"
import "core:testing"

@(test)
xcursor_theme_inheritance_scales_frames_and_malformed_files :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "kiln-cursor-*", context.allocator)
	assert(err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	for theme in ([]string{"child","parent","default"}) { assert(os.make_directory_all(fmt.tprintf("%s/%s/cursors",dir,theme)) == nil) }
	assert(os.write_entire_file(fmt.tprintf("%s/child/index.theme",dir),"[Icon Theme]\nInherits=child,parent\n") == nil)
	assert(os.write_entire_file(fmt.tprintf("%s/parent/index.theme",dir),"[Icon Theme]\nInherits=child\n") == nil)
	// Distinct nominal sizes and animation delays expose TOC and chunk offset mistakes.
	bytes := make([]u8, 16+36+3*(36+16))
	defer delete(bytes)
	put :: proc(bytes: []u8, at: int, value: u32) { for i in 0..<4 { bytes[at+i] = u8(value>>uint(i*8)) } }
	copy(bytes,"Xcur"); put(bytes,4,16); put(bytes,8,0x10000); put(bytes,12,3)
	for i in 0..<3 {
		chunk := 52+i*52
		put(bytes,16+i*12,0xfffd0002); put(bytes,20+i*12,24 if i < 2 else 48); put(bytes,24+i*12,u32(chunk))
		put(bytes,chunk,36); put(bytes,chunk+4,0xfffd0002); put(bytes,chunk+8,24 if i < 2 else 48); put(bytes,chunk+12,1)
		put(bytes,chunk+16,2); put(bytes,chunk+20,2); put(bytes,chunk+24,1); put(bytes,chunk+28,1); put(bytes,chunk+32,u32(10+i))
		put(bytes,chunk+36,0xff112233+u32(i))
	}
	assert(os.write_entire_file(fmt.tprintf("%s/parent/cursors/default",dir),bytes) == nil)
	assert(os.write_entire_file(fmt.tprintf("%s/default/cursors/text",dir),bytes) == nil)
	old, present := os.lookup_env("XCURSOR_PATH",context.allocator)
	defer delete(old)
	defer if present { os.set_env("XCURSOR_PATH",old) } else { os.unset_env("XCURSOR_PATH") }
	assert(os.set_env("XCURSOR_PATH",dir) == nil)
	m := xcursor_manager_create("child",24)
	defer xcursor_manager_destroy(m)
	one := xcursor_manager_get_xcursor(m,"default",1)
	assert(one != nil)
	testing.expect_value(t,len(one.images),2)
	testing.expect_value(t,one.images[0].delay,u32(10))
	testing.expect_value(t,one.images[0].hotspot_x,u32(1))
	testing.expect_value(t,one.images[0].buffer[0],u8(0x33))
	testing.expect(t,xcursor_manager_get_xcursor(m,"default",1) == one)
	two := xcursor_manager_get_xcursor(m,"default",2)
	assert(two != nil)
	testing.expect_value(t,len(two.images),1)
	testing.expect_value(t,two.images[0].delay,u32(12))
	testing.expect(t,xcursor_manager_get_xcursor(m,"text",1) != nil,"default theme fallback")
	testing.expect(t,xcursor_manager_get_xcursor(m,"missing",1) == nil,"inheritance cycle terminates")
	for length in 0..<len(bytes) {
		cursor := xcursor_parse(bytes[:length],48)
		testing.expect(t,cursor == nil,"truncated file rejected")
		xcursor_destroy(cursor)
	}
	put(bytes,52+24,2)
	testing.expect(t,xcursor_parse(bytes,24) == nil,"hotspot outside image rejected")
	put(bytes,4,max(u32))
	testing.expect(t,xcursor_parse(bytes,24) == nil,"invalid TOC offset rejected")
}
