package outputs

import "core:testing"

@(test)
edid_descriptors_and_corruption :: proc(t: ^testing.T) {
	bytes: [128]u8; for &b in bytes[1:7] { b = 255 }; bytes[8],bytes[9] = 4,67
	bytes[57] = 0xfc; copy(bytes[59:],transmute([]u8)string("Display X\n")); bytes[75] = 0xff; copy(bytes[77:],transmute([]u8)string("Serial 42\n"))
	for b in bytes[:127] { bytes[127] -= b }
	make_,model,serial := edid(bytes[:]); defer delete(make_); defer delete(model); defer delete(serial)
	testing.expect_value(t,make_,"ABC"); testing.expect_value(t,model,"Display X"); testing.expect_value(t,serial,"Serial 42")
	bytes[20] += 1; a,b,c := edid(bytes[:]); testing.expect_value(t,a,""); testing.expect_value(t,b,""); testing.expect_value(t,c,"")
}
