package desktop_bus

import "core:testing"
@(test)
inline_pixels_validate_before_read :: proc(t:^testing.T) {
    pixels:=[]u8{255,0,0,255,0,255,0,128,99,99,99,99,0,0,255,255,255,255,255,255}
    decoded:=decode_inline(2,2,12,true,8,4,pixels);defer delete(decoded)
    testing.expect_value(t,len(decoded),4)
    if len(decoded)==4 { testing.expect_value(t,decoded[0],u32(0xffff0000));testing.expect_value(t,decoded[1],u32(0x8000ff00));testing.expect_value(t,decoded[2],u32(0xff0000ff)) }
    rgb:=decode_inline(1,1,4,false,8,3,[]u8{12,34,56,99});defer delete(rgb)
    testing.expect_value(t,len(rgb),1)
    if len(rgb)==1 { testing.expect_value(t,rgb[0],u32(0xff0c2238)) }
    for v in ([][6]i32{{-1,2,8,1,8,4},{2,2,7,1,8,4},{2,2,8,1,16,4},{2,2,8,1,8,3},{max(i32),max(i32),max(i32),1,8,4},{4096,4096,16384,1,8,4},{2,3,12,1,8,4}}) {
        bad:=decode_inline(v[0],v[1],v[2],v[3]!=0,v[4],v[5],pixels)
        testing.expect_value(t,len(bad),0);delete(bad)
    }
}
