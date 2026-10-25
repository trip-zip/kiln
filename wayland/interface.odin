package wayland

Interface :: struct {
	name: cstring,
	version, method_count: i32,
	methods: [^]Message,
	event_count: i32,
	events: [^]Message,
}

Message :: struct {
	name, signature: cstring,
	types: [^]^Interface,
}

Fixed :: distinct i32

// C consumers may release arrays we fill, so their storage must use libc's allocator.
Array :: struct { size, alloc: uint, data: rawptr }

#assert(size_of(Interface) == 40 && align_of(Interface) == 8)
#assert(offset_of(Interface, name) == 0)
#assert(offset_of(Interface, version) == 8)
#assert(offset_of(Interface, method_count) == 12)
#assert(offset_of(Interface, methods) == 16)
#assert(offset_of(Interface, event_count) == 24)
#assert(offset_of(Interface, events) == 32)
#assert(size_of(Message) == 24 && align_of(Message) == 8)
#assert(offset_of(Message, name) == 0)
#assert(offset_of(Message, signature) == 8)
#assert(offset_of(Message, types) == 16)
#assert(size_of(Fixed) == 4 && align_of(Fixed) == 4)
#assert(size_of(Array) == 24 && align_of(Array) == 8)
#assert(offset_of(Array, size) == 0)
#assert(offset_of(Array, alloc) == 8)
#assert(offset_of(Array, data) == 16)
