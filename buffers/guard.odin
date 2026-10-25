package buffers

import "base:intrinsics"
import "core:sys/linux"
import "core:sys/posix"

Guard :: struct { mapping: ^Mapping, next: ^Guard }
@(thread_local) guards: ^Guard
previous_bus: posix.sigaction_t
bus_installed: bool
#assert(size_of(posix.sigaction_t) == 152 && offset_of(posix.sigaction_t, sa_flags) == 136)
#assert(size_of(posix.siginfo_t) == 128 && offset_of(posix.siginfo_t, si_addr) == 16)
guard_begin :: proc(g: ^Guard, m: ^Mapping) -> bool {
	if !bus_installed {
		action := posix.sigaction_t{sa_sigaction = handle_bus, sa_flags = {.SIGINFO, .SA_NODEFER}}
		if posix.sigaction(.SIGBUS, &action, &previous_bus) != .OK { return false }
		bus_installed = true
	}
	m.refs += 1; g.mapping, g.next = m, intrinsics.atomic_load(&guards)
	intrinsics.atomic_store(&guards, g)
	return true
}
guard_end :: proc(g: ^Guard) {
	link := &guards
	for intrinsics.atomic_load(link) != g { link = &intrinsics.atomic_load(link).next }
	intrinsics.atomic_store(link, g.next)
	mapping_unref(g.mapping); g^ = {}
}
handle_bus :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, ctx: rawptr) {
	address := uintptr(info.si_addr)
	for g := intrinsics.atomic_load(&guards); g != nil; g = intrinsics.atomic_load(&g.next) {
		m := g.mapping
		if address >= uintptr(m.data) && address-uintptr(m.data) < uintptr(m.size) {
			_, err := linux.mmap(uintptr(m.data), m.size, {.READ, .WRITE}, {.PRIVATE, .FIXED, .ANONYMOUS})
			if err == nil { return }
			break
		}
	}
	if rawptr(previous_bus.sa_handler) == posix.SIG_DFL || rawptr(previous_bus.sa_handler) == posix.SIG_IGN {
		posix.sigaction(sig, &previous_bus, nil)
		posix.raise(sig)
	} else if .SIGINFO in previous_bus.sa_flags { previous_bus.sa_sigaction(sig, info, ctx) } else { previous_bus.sa_handler(sig) }
}
