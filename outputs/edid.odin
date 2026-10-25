package outputs

import "core:fmt"
import "core:strings"

edid :: proc(bytes: []u8) -> (make_, model, serial: string) {
	if len(bytes) < 128 || bytes[0] != 0 || bytes[7] != 0 { return }
	for b in bytes[1:7] { if b != 255 { return } }
	checksum: u8; for b in bytes[:128] { checksum += b }; if checksum != 0 { return }
	id := u16(bytes[8])<<8 | u16(bytes[9]); name: [3]u8
	for &c,i in name { value := u8(id>>u32(10-5*i)&31); if value == 0 || value > 26 { return }; c = 'A'+value-1 }
	make_ = strings.clone(string(name[:]))
	for at := 54; at < 126; at += 18 {
		if bytes[at] != 0 || bytes[at+1] != 0 || bytes[at+2] != 0 { continue }
		end := at+5
		for end < at+18 && bytes[end] != 10 && bytes[end] != 0 { end += 1 }
		value := strings.trim_space(string(bytes[at+5:end]))
		if bytes[at+3] == 0xfc { delete(model); model = strings.clone(value) }
		if bytes[at+3] == 0xff { delete(serial); serial = strings.clone(value) }
	}
	if model == "" { model = fmt.aprintf("%04X",u16(bytes[10]) | u16(bytes[11])<<8) }
	if serial == "" { n := u32(bytes[12]) | u32(bytes[13])<<8 | u32(bytes[14])<<16 | u32(bytes[15])<<24; if n != 0 { serial = fmt.aprintf("%d",n) } }
	return
}
