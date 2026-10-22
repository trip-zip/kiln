/*
	Bindings for LuaJIT 2.1, linked against the system libluajit-5.1.

	Altered from vendor:lua/5.1 of the Odin distribution: relinked to LuaJIT,
	trimmed to the symbols libluajit exports, corrected against the LuaJIT
	2.1 headers, and extended with the LuaJIT-only API.

	Copyright (c) 2016-2025 Ginger Bill. All rights reserved.

	This software is provided 'as-is', without any express or implied
	warranty. In no event will the authors be held liable for any damages
	arising from the use of this software.

	Permission is granted to anyone to use this software for any purpose,
	including commercial applications, and to alter it and redistribute it
	freely, subject to the following restrictions:

	1. The origin of this software must not be misrepresented; you must not
	   claim that you wrote the original software. If you use this software
	   in a product, an acknowledgment in the product documentation would be
	   appreciated but is not required.
	2. Altered source versions must be plainly marked as such, and must not be
	   misrepresented as being the original software.
	3. This notice may not be removed or altered from any source distribution.
*/
package luajit

import "base:intrinsics"

import "core:c"

foreign import lib "system:luajit-5.1"

VERSION     :: "Lua 5.1"
RELEASE     :: "Lua 5.1.4"
VERSION_NUM :: 501
COPYRIGHT   :: "Copyright (C) 1994-2008 Lua.org, PUC-Rio"
AUTHORS     :: "R. Ierusalimschy, L. H. de Figueiredo & W. Celes"

/* mark for precompiled code ('<esc>Lua') */
SIGNATURE :: "\x1bLua"

/* option for multiple returns in 'lua_pcall' and 'lua_call' */
MULTRET :: -1

REGISTRYINDEX :: -10000
ENVIRONINDEX  :: -10001
GLOBALSINDEX  :: -10002

upvalueindex :: #force_inline proc "c" (i: c.int) -> c.int {
	return GLOBALSINDEX - i
}

MAXSTACK :: 65500
IDSIZE   :: 60

// LuaJIT sizes this from BUFSIZ, so it is part of the ABI. 8192 is glibc's
// BUFSIZ; musl's is 1024, and a musl build would need that instead.
L_BUFFERSIZE :: 8192


Status :: enum c.int {
	OK        = 0,
	YIELD     = 1,
	ERRRUN    = 2,
	ERRSYNTAX = 3,
	ERRMEM    = 4,
	ERRERR    = 5,
	ERRFILE   = 6,
}

OK        :: Status.OK
YIELD     :: Status.YIELD
ERRRUN    :: Status.ERRRUN
ERRSYNTAX :: Status.ERRSYNTAX
ERRMEM    :: Status.ERRMEM
ERRERR    :: Status.ERRERR
ERRFILE   :: Status.ERRFILE


Type :: enum c.int {
	NONE          = -1,

	NIL           = 0,
	BOOLEAN       = 1,
	LIGHTUSERDATA = 2,
	NUMBER        = 3,
	STRING        = 4,
	TABLE         = 5,
	FUNCTION      = 6,
	USERDATA      = 7,
	THREAD        = 8,
}

TNONE          :: Type.NONE
TNIL           :: Type.NIL
TBOOLEAN       :: Type.BOOLEAN
TLIGHTUSERDATA :: Type.LIGHTUSERDATA
TNUMBER        :: Type.NUMBER
TSTRING        :: Type.STRING
TTABLE         :: Type.TABLE
TFUNCTION      :: Type.FUNCTION
TUSERDATA      :: Type.USERDATA
TTHREAD        :: Type.THREAD


/* minimum Lua stack available to a C function */
MINSTACK :: 20


Number  :: distinct f64
Integer :: distinct c.ptrdiff_t


CFunction :: #type proc "c" (L: ^State) -> c.int

Reader :: #type proc "c" (L: ^State, ud: rawptr, sz: ^c.size_t) -> cstring
Writer :: #type proc "c" (L: ^State, p: rawptr, sz: c.size_t, ud: rawptr) -> c.int

Alloc :: #type proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: c.size_t) -> rawptr


GCWhat :: enum c.int {
	STOP       = 0,
	RESTART    = 1,
	COLLECT    = 2,
	COUNT      = 3,
	COUNTB     = 4,
	STEP       = 5,
	SETPAUSE   = 6,
	SETSTEPMUL = 7,
	ISRUNNING  = 9,
}
GCSTOP       :: GCWhat.STOP
GCRESTART    :: GCWhat.RESTART
GCCOLLECT    :: GCWhat.COLLECT
GCCOUNT      :: GCWhat.COUNT
GCCOUNTB     :: GCWhat.COUNTB
GCSTEP       :: GCWhat.STEP
GCSETPAUSE   :: GCWhat.SETPAUSE
GCSETSTEPMUL :: GCWhat.SETSTEPMUL
GCISRUNNING  :: GCWhat.ISRUNNING


HookEvent :: enum c.int {
	CALL    = 0,
	RET     = 1,
	LINE    = 2,
	COUNT   = 3,
	TAILRET = 4,
}
HOOKCALL    :: HookEvent.CALL
HOOKRET     :: HookEvent.RET
HOOKLINE    :: HookEvent.LINE
HOOKCOUNT   :: HookEvent.COUNT
HOOKTAILRET :: HookEvent.TAILRET

HookMask :: distinct bit_set[HookEvent; c.int]
MASKCALL  :: HookMask{.CALL}
MASKRET   :: HookMask{.RET}
MASKLINE  :: HookMask{.LINE}
MASKCOUNT :: HookMask{.COUNT}

/* activation record */
Debug :: struct {
	event:           HookEvent,
	name:            cstring,              /* (n) */
	namewhat:        cstring,              /* (n) 'global', 'local', 'field', 'method' */
	what:            cstring,              /* (S) 'Lua', 'C', 'main', 'tail' */
	source:          cstring,              /* (S) */
	currentline:     c.int,                /* (l) */
	nups:            c.int,                /* (u) number of upvalues */
	linedefined:     c.int,                /* (S) */
	lastlinedefined: c.int,                /* (S) */
	short_src:       [IDSIZE]u8 `fmt:"s"`, /* (S) */
	/* private part */
	i_ci:            c.int,                /* active function */
}

Hook :: #type proc "c" (L: ^State, ar: ^Debug)


State :: struct {} // opaque data type


@(link_prefix="lua_")
@(default_calling_convention="c")
foreign lib {
	/*
	** state manipulation
	*/

	newstate  :: proc(f: Alloc, ud: rawptr) -> ^State ---
	close     :: proc(L: ^State) ---
	newthread :: proc(L: ^State) -> ^State ---

	atpanic :: proc(L: ^State, panicf: CFunction) -> CFunction ---


	/*
	** basic stack manipulation
	*/

	gettop     :: proc(L: ^State) -> c.int ---
	settop     :: proc(L: ^State, idx: c.int) ---
	pushvalue  :: proc(L: ^State, idx: c.int) ---
	remove     :: proc(L: ^State, idx: c.int) ---
	insert     :: proc(L: ^State, idx: c.int) ---
	replace    :: proc(L: ^State, idx: c.int) ---
	copy       :: proc(L: ^State, fromidx, toidx: c.int) ---
	checkstack :: proc(L: ^State, sz: c.int) -> b32 ---

	xmove :: proc(from, to: ^State, n: c.int) ---


	/*
	** access functions (stack -> C)
	*/

	isnumber    :: proc(L: ^State, idx: c.int) -> b32 ---
	isstring    :: proc(L: ^State, idx: c.int) -> b32 ---
	iscfunction :: proc(L: ^State, idx: c.int) -> b32 ---
	isuserdata  :: proc(L: ^State, idx: c.int) -> b32 ---
	type        :: proc(L: ^State, idx: c.int) -> Type ---
	typename    :: proc(L: ^State, tp: Type) -> cstring ---

	equal    :: proc(L: ^State, idx1, idx2: c.int) -> b32 ---
	rawequal :: proc(L: ^State, idx1, idx2: c.int) -> b32 ---
	lessthan :: proc(L: ^State, idx1, idx2: c.int) -> b32 ---

	tonumber    :: proc(L: ^State, idx: c.int) -> Number ---
	tointeger   :: proc(L: ^State, idx: c.int) -> Integer ---
	tonumberx   :: proc(L: ^State, idx: c.int, isnum: ^b32) -> Number ---
	tointegerx  :: proc(L: ^State, idx: c.int, isnum: ^b32) -> Integer ---
	toboolean   :: proc(L: ^State, idx: c.int) -> b32 ---
	tolstring   :: proc(L: ^State, idx: c.int, len: ^c.size_t) -> cstring ---
	objlen      :: proc(L: ^State, idx: c.int) -> c.size_t ---
	tocfunction :: proc(L: ^State, idx: c.int) -> CFunction ---
	touserdata  :: proc(L: ^State, idx: c.int) -> rawptr ---
	tothread    :: proc(L: ^State, idx: c.int) -> ^State ---
	topointer   :: proc(L: ^State, idx: c.int) -> rawptr ---


	/*
	** push functions (C -> stack)
	*/

	pushnil           :: proc(L: ^State) ---
	pushnumber        :: proc(L: ^State, n: Number) ---
	pushinteger       :: proc(L: ^State, n: Integer) ---
	pushlstring       :: proc(L: ^State, s: cstring, l: c.size_t) ---
	pushstring        :: proc(L: ^State, s: cstring) ---
	pushfstring       :: proc(L: ^State, fmt: cstring, #c_vararg args: ..any) -> cstring ---
	pushcclosure      :: proc(L: ^State, fn: CFunction, n: c.int) ---
	pushboolean       :: proc(L: ^State, b: b32) ---
	pushlightuserdata :: proc(L: ^State, p: rawptr) ---
	// True when L is the main thread of its state.
	pushthread        :: proc(L: ^State) -> b32 ---


	/*
	** get functions (Lua -> stack)
	*/

	gettable     :: proc(L: ^State, idx: c.int) ---
	getfield     :: proc(L: ^State, idx: c.int, k: cstring) ---
	rawget       :: proc(L: ^State, idx: c.int) ---
	rawgeti      :: proc(L: ^State, idx: c.int, n: c.int) ---
	createtable  :: proc(L: ^State, narr, nrec: c.int) ---
	newuserdata  :: proc(L: ^State, sz: c.size_t) -> rawptr ---
	getmetatable :: proc(L: ^State, objindex: c.int) -> b32 ---
	getfenv      :: proc(L: ^State, idx: c.int) ---


	/*
	** set functions (stack -> Lua)
	*/

	settable     :: proc(L: ^State, idx: c.int) ---
	setfield     :: proc(L: ^State, idx: c.int, k: cstring) ---
	rawset       :: proc(L: ^State, idx: c.int) ---
	rawseti      :: proc(L: ^State, idx: c.int, n: c.int) ---
	setmetatable :: proc(L: ^State, objindex: c.int) -> c.int ---
	setfenv      :: proc(L: ^State, idx: c.int) -> b32 ---


	/*
	** 'load' and 'call' functions (load and run Lua code)
	*/

	call   :: proc(L: ^State, nargs, nresults: c.int) ---
	pcall  :: proc(L: ^State, nargs, nresults: c.int, errfunc: c.int) -> Status ---
	cpcall :: proc(L: ^State, func: CFunction, ud: rawptr) -> Status ---
	load   :: proc(L: ^State, reader: Reader, dt: rawptr, chunkname: cstring) -> Status ---
	// mode is "b", "t" or "bt": whether binary chunks, text chunks, or both may load.
	loadx  :: proc(L: ^State, reader: Reader, dt: rawptr, chunkname: cstring, mode: cstring) -> Status ---
	dump   :: proc(L: ^State, writer: Writer, data: rawptr) -> c.int ---


	/*
	** coroutine functions
	*/

	// Only valid as the return expression of a CFunction: `return yield(L, n)`.
	yield       :: proc(L: ^State, nresults: c.int) -> c.int ---
	resume      :: proc(L: ^State, narg: c.int) -> Status ---
	status      :: proc(L: ^State) -> Status ---
	isyieldable :: proc(L: ^State) -> b32 ---


	/*
	** garbage-collection function and options
	*/

	gc :: proc(L: ^State, what: GCWhat, data: c.int) -> c.int ---


	/*
	** miscellaneous functions
	*/

	error :: proc(L: ^State) -> c.int ---

	next :: proc(L: ^State, idx: c.int) -> b32 ---

	concat :: proc(L: ^State, n: c.int) ---

	getallocf :: proc(L: ^State, ud: ^rawptr) -> Alloc ---
	setallocf :: proc(L: ^State, f: Alloc, ud: rawptr) ---

	version :: proc(L: ^State) -> ^Number ---


	/*
	** {======================================================================
	** Debug API
	** =======================================================================
	*/

	getstack   :: proc(L: ^State, level: c.int, ar: ^Debug) -> b32 ---
	getinfo    :: proc(L: ^State, what: cstring, ar: ^Debug) -> b32 ---
	getlocal   :: proc(L: ^State, ar: ^Debug, n: c.int) -> cstring ---
	setlocal   :: proc(L: ^State, ar: ^Debug, n: c.int) -> cstring ---
	getupvalue :: proc(L: ^State, funcindex: c.int, n: c.int) -> cstring ---
	setupvalue :: proc(L: ^State, funcindex: c.int, n: c.int) -> cstring ---

	sethook      :: proc(L: ^State, func: Hook, mask: HookMask, count: c.int) -> c.int ---
	gethook      :: proc(L: ^State) -> Hook ---
	gethookmask  :: proc(L: ^State) -> HookMask ---
	gethookcount :: proc(L: ^State) -> c.int ---

	upvalueid   :: proc(L: ^State, idx, n: c.int) -> rawptr ---
	upvaluejoin :: proc(L: ^State, idx1, n1, idx2, n2: c.int) ---

	/* }============================================================== */
}



FILEHANDLE  :: "FILE*"
COLIBNAME   :: "coroutine"
MATHLIBNAME :: "math"
STRLIBNAME  :: "string"
TABLIBNAME  :: "table"
IOLIBNAME   :: "io"
OSLIBNAME   :: "os"
LOADLIBNAME :: "package"
DBLIBNAME   :: "debug"
BITLIBNAME  :: "bit"
JITLIBNAME  :: "jit"
FFILIBNAME  :: "ffi"

// The open_* functions read their own Lua call frame, so they must run as
// Lua calls (pushcfunction, pushstring of the name, call), never be called
// directly from Odin.
@(link_prefix="lua")
@(default_calling_convention="c")
foreign lib {
	open_base          :: proc(L: ^State) -> c.int ---
	open_math          :: proc(L: ^State) -> c.int ---
	open_string        :: proc(L: ^State) -> c.int ---
	open_table         :: proc(L: ^State) -> c.int ---
	open_io            :: proc(L: ^State) -> c.int ---
	open_os            :: proc(L: ^State) -> c.int ---
	open_package       :: proc(L: ^State) -> c.int ---
	open_debug         :: proc(L: ^State) -> c.int ---
	open_bit           :: proc(L: ^State) -> c.int ---
	open_jit           :: proc(L: ^State) -> c.int ---
	open_ffi           :: proc(L: ^State) -> c.int ---
	open_string_buffer :: proc(L: ^State) -> c.int ---

	/* open all previous libraries */
	L_openlibs :: proc(L: ^State) ---
}



GNAME :: "_G"

L_Reg :: struct {
	name: cstring,
	func: CFunction,
}

/* predefined references */
NOREF  :: -2
REFNIL :: -1

@(link_prefix="lua")
@(default_calling_convention="c")
foreign lib {
	// l is terminated by an entry whose name is nil.
	L_openlib      :: proc(L: ^State, libname: cstring, l: [^]L_Reg, nup: c.int) ---
	L_register     :: proc(L: ^State, libname: cstring, l: [^]L_Reg) ---
	L_setfuncs     :: proc(L: ^State, l: [^]L_Reg, nup: c.int) ---
	L_getmetafield :: proc(L: ^State, obj: c.int, e: cstring) -> b32 ---
	L_callmeta     :: proc(L: ^State, obj: c.int, e: cstring) -> b32 ---
	L_typerror     :: proc(L: ^State, narg: c.int, tname: cstring) -> c.int ---
	L_argerror     :: proc(L: ^State, numarg: c.int, extramsg: cstring) -> c.int ---
	L_checklstring :: proc(L: ^State, numArg: c.int, l: ^c.size_t) -> cstring ---
	L_optlstring   :: proc(L: ^State, numArg: c.int, def: cstring, l: ^c.size_t) -> cstring ---
	@(link_name="luaL_checklstring")
	L_checkstring  :: proc(L: ^State, numArg: c.int, l: ^c.size_t = nil) -> cstring ---
	@(link_name="luaL_optlstring")
	L_optstring    :: proc(L: ^State, numArg: c.int, def: cstring, l: ^c.size_t = nil) -> cstring ---
	L_checknumber  :: proc(L: ^State, numArg: c.int) -> Number ---
	L_optnumber    :: proc(L: ^State, nArg: c.int, def: Number) -> Number ---
	L_checkinteger :: proc(L: ^State, numArg: c.int) -> Integer ---
	L_optinteger   :: proc(L: ^State, nArg: c.int, def: Integer) -> Integer ---

	L_checkstack :: proc(L: ^State, sz: c.int, msg: cstring) ---
	L_checktype  :: proc(L: ^State, narg: c.int, t: Type) ---
	L_checkany   :: proc(L: ^State, narg: c.int) ---

	L_newmetatable :: proc(L: ^State, tname: cstring) -> b32 ---
	L_setmetatable :: proc(L: ^State, tname: cstring) ---
	L_checkudata   :: proc(L: ^State, ud: c.int, tname: cstring) -> rawptr ---
	L_testudata    :: proc(L: ^State, ud: c.int, tname: cstring) -> rawptr ---

	L_where :: proc(L: ^State, lvl: c.int) ---
	L_error :: proc(L: ^State, fmt: cstring, #c_vararg args: ..any) -> c.int ---

	L_checkoption :: proc(L: ^State, narg: c.int, def: cstring, lst: [^]cstring) -> c.int ---

	L_fileresult :: proc(L: ^State, stat: c.int, fname: cstring) -> c.int ---
	L_execresult :: proc(L: ^State, stat: c.int) -> c.int ---

	L_ref   :: proc(L: ^State, t: c.int) -> c.int ---
	L_unref :: proc(L: ^State, t: c.int, ref: c.int) ---

	L_loadfile    :: proc(L: ^State, filename: cstring) -> Status ---
	L_loadfilex   :: proc(L: ^State, filename: cstring, mode: cstring) -> Status ---
	L_loadbuffer  :: proc(L: ^State, buff: [^]byte, sz: c.size_t, name: cstring) -> Status ---
	L_loadbufferx :: proc(L: ^State, buff: [^]byte, sz: c.size_t, name: cstring, mode: cstring) -> Status ---
	L_loadstring  :: proc(L: ^State, s: cstring) -> Status ---

	L_newstate :: proc() -> ^State ---

	L_gsub :: proc(L: ^State, s, p, r: cstring) -> cstring ---

	L_findtable :: proc(L: ^State, idx: c.int, fname: cstring, szhint: c.int) -> cstring ---

	L_traceback  :: proc(L: ^State, L1: ^State, msg: cstring, level: c.int) ---
	L_pushmodule :: proc(L: ^State, modname: cstring, sizehint: c.int) ---
}


/*
** {======================================================
** Generic Buffer manipulation
** =======================================================
*/

L_Buffer :: struct {
	p:      [^]byte, /* current position in buffer */
	lvl:    c.int,   /* number of strings in the stack (level) */
	L:      ^State,
	buffer: [L_BUFFERSIZE]byte,
}

L_addchar :: #force_inline proc "c" (B: ^L_Buffer, ch: byte) {
	if uintptr(B.p) >= uintptr(&B.buffer[0]) + L_BUFFERSIZE {
		L_prepbuffer(B)
	}
	B.p[0] = ch
	B.p = B.p[1:]
}
L_putchar :: L_addchar

L_addsize :: #force_inline proc "c" (B: ^L_Buffer, n: c.size_t) {
	B.p = B.p[n:]
}

@(link_prefix="lua")
@(default_calling_convention="c")
foreign lib {
	L_buffinit   :: proc(L: ^State, B: ^L_Buffer) ---
	L_prepbuffer :: proc(B: ^L_Buffer) -> [^]byte ---
	L_addlstring :: proc(B: ^L_Buffer, s: cstring, l: c.size_t) ---
	L_addstring  :: proc(B: ^L_Buffer, s: cstring) ---
	L_addvalue   :: proc(B: ^L_Buffer) ---
	L_pushresult :: proc(B: ^L_Buffer) ---
}

/* }====================================================== */


/*
** {======================================================
** LuaJIT
** =======================================================
*/

JIT_MODE_MASK :: 0x00ff

JIT_Mode :: enum c.int {
	ENGINE      = 0,    /* Set mode for whole JIT engine. */
	DEBUG       = 1,    /* Set debug mode (idx = level). */
	FUNC        = 2,    /* Change mode for a function. */
	ALLFUNC     = 3,    /* Recurse into subroutine protos. */
	ALLSUBFUNC  = 4,    /* Change only the subroutines. */
	TRACE       = 5,    /* Flush a compiled trace. */
	WRAPCFUNC   = 0x10, /* Set wrapper mode for C function calls. */
}

JIT_MODE_OFF   :: 0x0000 /* Turn feature off. */
JIT_MODE_ON    :: 0x0100 /* Turn feature on. */
JIT_MODE_FLUSH :: 0x0200 /* Flush JIT-compiled code. */

JIT_ProfileCallback :: #type proc "c" (data: rawptr, L: ^State, samples: c.int, vmstate: c.int)

@(link_prefix="luaJIT_")
@(default_calling_convention="c")
foreign lib {
	// mode is a JIT_Mode combined with JIT_MODE_OFF, JIT_MODE_ON or JIT_MODE_FLUSH.
	setmode :: proc(L: ^State, idx: c.int, mode: c.int) -> b32 ---

	profile_start     :: proc(L: ^State, mode: cstring, cb: JIT_ProfileCallback, data: rawptr) ---
	profile_stop      :: proc(L: ^State) ---
	profile_dumpstack :: proc(L: ^State, fmt: cstring, depth: c.int, len: ^c.size_t) -> cstring ---
}

/* }====================================================== */


// Pinned to the LP64 layouts of the C headers. A mismatch in any of these is
// silent memory corruption inside LuaJIT, not a link error.
when size_of(rawptr) == 8 {
	#assert(size_of(L_Buffer) == 8216 && offset_of(L_Buffer, buffer) == 24)
	#assert(size_of(Debug) == 120 && offset_of(Debug, short_src) == 56 && offset_of(Debug, i_ci) == 116)
	#assert(size_of(L_Reg) == 16)
	#assert(size_of(Integer) == 8)
}


/*
** {==============================================================
** some useful macros
** ===============================================================
*/

pop :: #force_inline proc "c" (L: ^State, n: c.int) {
	settop(L, -n-1)
}
newtable :: #force_inline proc "c" (L: ^State) {
	createtable(L, 0, 0)
}
register :: #force_inline proc "c" (L: ^State, n: cstring, f: CFunction) {
	pushcfunction(L, f)
	setglobal(L, n)
}

pushcfunction :: #force_inline proc "c" (L: ^State, f: CFunction) {
	pushcclosure(L, f, 0)
}

strlen :: #force_inline proc "c" (L: ^State, i: c.int) -> c.size_t {
	return objlen(L, i)
}


isfunction      :: #force_inline proc "c" (L: ^State, n: c.int) -> bool { return type(L, n) == .FUNCTION      }
istable         :: #force_inline proc "c" (L: ^State, n: c.int) -> bool { return type(L, n) == .TABLE         }
islightuserdata :: #force_inline proc "c" (L: ^State, n: c.int) -> bool { return type(L, n) == .LIGHTUSERDATA }
isnil           :: #force_inline proc "c" (L: ^State, n: c.int) -> bool { return type(L, n) == .NIL           }
isboolean       :: #force_inline proc "c" (L: ^State, n: c.int) -> bool { return type(L, n) == .BOOLEAN       }
isthread        :: #force_inline proc "c" (L: ^State, n: c.int) -> bool { return type(L, n) == .THREAD        }
isnone          :: #force_inline proc "c" (L: ^State, n: c.int) -> bool { return type(L, n) == .NONE          }
isnoneornil     :: #force_inline proc "c" (L: ^State, n: c.int) -> bool { return type(L, n) <= .NIL           }


pushliteral :: pushstring
setglobal :: #force_inline proc "c" (L: ^State, s: cstring) {
	setfield(L, GLOBALSINDEX, s)
}
getglobal :: #force_inline proc "c" (L: ^State, s: cstring) {
	getfield(L, GLOBALSINDEX, s)
}
tostring :: #force_inline proc "c" (L: ^State, i: c.int) -> cstring {
	return tolstring(L, i, nil)
}

open :: L_newstate
getregistry :: #force_inline proc "c" (L: ^State) {
	pushvalue(L, REGISTRYINDEX)
}

getgccount :: #force_inline proc "c" (L: ^State) -> c.int {
	return gc(L, .COUNT, 0)
}

Chunkreader :: Reader
Chunkwriter :: Writer


L_argcheck :: #force_inline proc "c" (L: ^State, cond: bool, numarg: c.int, extramsg: cstring) {
	if !cond {
		L_argerror(L, numarg, extramsg)
	}
}

L_checkint :: #force_inline proc "c" (L: ^State, n: c.int) -> c.int {
	return c.int(L_checkinteger(L, n))
}
L_optint :: #force_inline proc "c" (L: ^State, n: c.int, d: c.int) -> c.int {
	return c.int(L_optinteger(L, n, Integer(d)))
}

L_typename :: #force_inline proc "c" (L: ^State, i: c.int) -> cstring {
	return typename(L, type(L, i))
}
L_dofile :: #force_inline proc "c" (L: ^State, s: cstring) -> Status {
	err := L_loadfile(L, s)
	return pcall(L, 0, MULTRET, 0) if err == .OK else err
}
L_dostring :: #force_inline proc "c" (L: ^State, s: cstring) -> Status {
	err := L_loadstring(L, s)
	return pcall(L, 0, MULTRET, 0) if err == .OK else err
}
L_getmetatable :: #force_inline proc "c" (L: ^State, n: cstring) {
	getfield(L, REGISTRYINDEX, n)
}
L_opt :: #force_inline proc "c" (L: ^State, f: $F, n: c.int, d: $T) -> T where intrinsics.type_is_proc(F) {
	return d if isnoneornil(L, n) else f(L, n)
}

// l must end with an entry whose name is nil, which is not counted.
L_newlibtable :: #force_inline proc "c" (L: ^State, l: []L_Reg) {
	createtable(L, 0, c.int(len(l) - 1))
}
L_newlib :: #force_inline proc "c" (L: ^State, l: []L_Reg) {
	L_newlibtable(L, l)
	L_setfuncs(L, raw_data(l), 0)
}

/* }============================================================== */
