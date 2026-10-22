package xcb_ewmh
import "core:testing"
@(test)
icon_lengths_are_validated_before_iteration :: proc(t: ^testing.T) {
    testing.expect(t,valid_icons([]u32{1,1,0xff123456,2,1,1,2}))
    testing.expect(t,valid_icons([]u32{0,0,1,1,0}))
    testing.expect(t,!valid_icons(nil))
    testing.expect(t,!valid_icons([]u32{1}))
    testing.expect(t,!valid_icons([]u32{16,16,0}))
    testing.expect(t,!valid_icons([]u32{max(u32),max(u32)}))
    testing.expect(t,!valid_icons([]u32{1,1,0,7}))
}
