package wayland

import "core:fmt"
import "core:os"
import "core:sys/linux"

log_handler: proc(string)
log :: proc(message: string) { if log_handler != nil { log_handler(message) } else { fmt.eprint(message) } }
trace :: proc(resource: ^Resource, message: ^Message, args: []Argument, send: bool) {
	if !resource.client.display.debug { return }
	ts, _ := linux.clock_gettime(.REALTIME)
	buffer: [8192]u8
	at := len(fmt.bprintf(buffer[:], "[%02d:%02d:%02d.%06d] %s%s#%d.%s(", (ts.time_sec/3600)%24, (ts.time_sec/60)%60, ts.time_sec%60, ts.time_nsec/1000, " -> " if send else "", resource.interface.name, resource.id, message.name))
	signature := Signature{text = string(message.signature)}
	for arg, index in args {
		kind, _, _ := argument_next(&signature)
		if index > 0 { at += len(fmt.bprintf(buffer[at:], ", ")) }
		switch value in arg {
		case Int: at += len(fmt.bprintf(buffer[at:], "%d", value))
		case Uint: at += len(fmt.bprintf(buffer[at:], "%d", value))
		case Fixed: at += len(fmt.bprintf(buffer[at:], "%.8f", f64(value)/256))
		case String: at += len(fmt.bprintf(buffer[at:], "%q", value.value)) if !value.is_null else len(fmt.bprintf(buffer[at:], "nil"))
		case Object:
			if kind == 'n' { at += len(fmt.bprintf(buffer[at:], "new id ")) }
			if value == nil { at += len(fmt.bprintf(buffer[at:], "nil")) } else { at += len(fmt.bprintf(buffer[at:], "%s#%d", value.interface.name, value.id)) }
		case New_Id:
			iface := message.types[index]
			at += len(fmt.bprintf(buffer[at:], "new id %s#%d", string(iface.name) if iface != nil else "[unknown]", value))
		case Proxy_Object:
			if value == nil { at += len(fmt.bprintf(buffer[at:], "nil")) } else { at += len(fmt.bprintf(buffer[at:], "%s#%d", value.interface.name, value.id)) }
		case Array: at += len(fmt.bprintf(buffer[at:], "array[%d]", value.size))
		case Fd: at += len(fmt.bprintf(buffer[at:], "fd %d", value))
		}
	}
	at += len(fmt.bprintf(buffer[at:], ")\n"))
	os.write(os.stderr, buffer[:at])
}
