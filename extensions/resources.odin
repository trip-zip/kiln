package extensions

import "../buffers"

import sf "../surfaces"

import st "../seat"

import wl "../wayland"
import wlr "../wlroots"

output_of :: proc(r: ^wl.Resource) -> ^wlr.wlr_output { return wlr.wlr_output_from_resource(r) if r != nil else nil }
surface_of :: proc(r: ^wl.Resource) -> ^sf.Surface { return sf.of(r) if r != nil else nil }
seat_client_of :: proc(r: ^wl.Resource) -> ^st.Client { return st.client_of(r) if r != nil else nil }
pointer_seat_client_of :: proc(r: ^wl.Resource) -> ^st.Client { return st.pointer_client_of(r) if r != nil else nil }
// The lookup acquires a buffer lock, including on paths which reject its attributes.
buffer_of :: proc(r: ^wl.Resource) -> ^buffers.Buffer { return buffers.of(r) if r != nil else nil }
