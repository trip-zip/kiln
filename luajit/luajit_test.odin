package luajit

import "base:runtime"
import "core:c"
import "core:strings"
import "core:testing"

fresh :: proc() -> ^State {
	L := L_newstate()
	L_openlibs(L)
	return L
}

@(test)
dostring_returns_values :: proc(t: ^testing.T) {
	L := fresh()
	defer close(L)

	testing.expect_value(t, L_dostring(L, "return 6 * 7, jit ~= nil"), Status.OK)
	testing.expect_value(t, tointeger(L, -2), 42)
	testing.expect(t, toboolean(L, -1) == true)
}

@(test)
syntax_error_reports_status :: proc(t: ^testing.T) {
	L := fresh()
	defer close(L)

	testing.expect_value(t, L_dostring(L, "return ("), Status.ERRSYNTAX)
}

@(export, link_name = "kiln_luajit_test_add")
kiln_luajit_test_add :: proc "c" (a, b: c.int) -> c.int {
	return a + b
}

// Fails with "undefined symbol" unless the binary links with --export-dynamic.
@(test)
ffi_calls_exported_odin_proc :: proc(t: ^testing.T) {
	L := fresh()
	defer close(L)

	status := L_dostring(L, `
		local ffi = require("ffi")
		ffi.cdef[[int kiln_luajit_test_add(int a, int b);]]
		return ffi.C.kiln_luajit_test_add(2, 3)
	`)
	testing.expectf(t, status == .OK, "ffi call failed: %s", tostring(L, -1))
	testing.expect_value(t, tointeger(L, -1), 5)
}

checked_double :: proc "c" (L: ^State) -> c.int {
	L_argcheck(L, isnumber(L, 1) == true, 1, "number expected")
	pushnumber(L, tonumber(L, 1) * 2)
	return 1
}

// The error raised in checked_double unwinds through an Odin frame on its
// way back to pcall.
@(test)
error_from_odin_cfunction_reaches_pcall :: proc(t: ^testing.T) {
	L := fresh()
	defer close(L)
	register(L, "checked_double", checked_double)

	testing.expect_value(t, L_dostring(L, "return checked_double(21)"), Status.OK)
	testing.expect_value(t, tonumber(L, -1), 42)
	pop(L, 1)

	testing.expect_value(t, L_dostring(L, "return checked_double('x')"), Status.ERRRUN)
	msg := string(tostring(L, -1))
	testing.expectf(t, strings.contains(msg, "number expected"), "unexpected error: %s", msg)
}

// LuaJIT fills the buffer up to its own idea of L_BUFFERSIZE, so if ours is
// smaller it writes past the struct and into the canary.
@(test)
buffer_stays_inside_struct :: proc(t: ^testing.T) {
	L := fresh()
	defer close(L)

	Guarded :: struct {
		B:      L_Buffer,
		canary: [64]u64,
	}
	g: Guarded
	for &w in g.canary {
		w = 0xdeadbeefdeadbeef
	}

	long := strings.repeat("a", 3000, context.temp_allocator)
	L_buffinit(L, &g.B)
	L_addlstring(&g.B, cstring(raw_data(long)), c.size_t(len(long)))
	L_pushresult(&g.B)

	testing.expect_value(t, objlen(L, -1), 3000)
	for w in g.canary {
		testing.expect_value(t, w, 0xdeadbeefdeadbeef)
	}
}

// L_addchar flushes to the Lua stack only once the buffer is full.
@(test)
addchar_fills_before_flushing :: proc(t: ^testing.T) {
	L := fresh()
	defer close(L)

	top := gettop(L)
	B: L_Buffer
	L_buffinit(L, &B)
	for _ in 0 ..< 100 {
		L_addchar(&B, 'a')
	}
	testing.expect_value(t, gettop(L), top)

	for _ in 100 ..< L_BUFFERSIZE + 1 {
		L_addchar(&B, 'a')
	}
	L_pushresult(&B)
	testing.expect_value(t, objlen(L, -1), L_BUFFERSIZE + 1)
}

counting_alloc :: proc "c" (ud, ptr: rawptr, osize, nsize: c.size_t) -> rawptr {
	ctx := (^runtime.Context)(ud)
	context = ctx^
	(^int)(ctx.user_ptr)^ += 1
	if nsize == 0 {
		runtime.mem_free(ptr)
		return nil
	}
	if ptr == nil {
		data, _ := runtime.mem_alloc(int(nsize))
		return raw_data(data)
	}
	data, _ := runtime.mem_resize(ptr, int(osize), int(nsize))
	return raw_data(data)
}

@(test)
newstate_uses_odin_allocator :: proc(t: ^testing.T) {
	calls := 0
	ctx := context
	ctx.user_ptr = &calls

	L := newstate(counting_alloc, &ctx)
	testing.expect(t, L != nil)
	defer close(L)
	L_openlibs(L)

	testing.expect_value(t, L_dostring(L, "local t = {} for i = 1, 1000 do t[i] = tostring(i) end"), Status.OK)
	testing.expect(t, calls > 0)
}
