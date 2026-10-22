package lua_runtime

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import lua "../luajit"
import layout "../layout"
import paint "../paint"
import images "../images"
import clay "deps:clay"

set_lock_handler :: proc "c" (L: ^lua.State) -> c.int {
    context=runtime.default_context()
    return set_handler(L,&self(L).lock_ref)
}
set_frame_handler :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return set_handler(L, &self(L).frame_ref)
}
set_event_handler :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return set_handler(L, &self(L).event_ref)
}
set_handler :: proc(L: ^lua.State, ref: ^c.int) -> c.int {
	lua.L_checktype(L, 1, .FUNCTION)
	lua.pushvalue(L, 1)
	next := lua.L_ref(L, lua.REGISTRYINDEX)
	lua.L_unref(L, lua.REGISTRYINDEX, ref^)
	ref^ = next
	return 0
}

frame_call :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := (^Runtime)(lua.touserdata(L, 1))
	if !r.lock_declaring && r.ui_begin_ref!=lua.NOREF {
		lua.rawgeti(L,lua.REGISTRYINDEX,r.ui_begin_ref)
		push_string(L,r.screen)
		lua.call(L,1,0)
	}
	ref:=r.lock_ref if r.lock_declaring else r.frame_ref
    if ref==lua.NOREF { return 0 }
	lua.rawgeti(L, lua.REGISTRYINDEX, ref)
	push_string(L, r.screen)
	lua.pushinteger(L, lua.Integer(r.width))
	lua.pushinteger(L, lua.Integer(r.height))
	lua.call(L, 3, 0)
	return 0
}

declare :: proc(r: ^Runtime, ui: ^layout.Layout, screen: string, width, height: i32, lock_frame:=false) -> ([]layout.Node, bool) {
	ref:=r.lock_ref if lock_frame else r.frame_ref
    if r.declaring || r.reload_pending || ref == lua.NOREF { return nil, false }
	r.lock_declaring=lock_frame
    defer r.lock_declaring=false
    ui.fonts = &r.fonts
	ui.images = &r.images
	layout.clear_frame(&r.frame)
	clear(&r.ids)
	clear(&r.surfaces)
	clear(&r.layer_answers)
	r.current_layout, r.frame_layout = ui, ui
	defer r.current_layout = ui
	r.screen, r.width, r.height = screen, width, height
	r.declaring = true
	defer r.declaring = false
	L := r.state
	base := lua.gettop(L)
	defer lua.settop(L, base)
	if lua.cpcall(L, frame_call, r) != .OK {
		fmt.eprintln("Lua frame:", lua.tostring(L, -1))
		return nil, false
	}
	if r.reload_pending { return nil, false }
	if len(r.frame.stack) != 0 {
		fmt.eprintln("Lua frame: missing core.close")
		return nil, false
	}
	return r.frame.nodes[:], true
}

frame_guard :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	if !self(L).declaring { return lua.L_error(L, "declare primitives are only callable inside the frame handler") }
	return 0
}
flat_number :: proc(L: ^lua.State, index: c.int) -> f32 {
	lua.rawgeti(L, 1, index)
	n := f32(lua.tonumber(L, -1))
	lua.pop(L, 1)
	return n
}
axis :: proc(L: ^lua.State, index: c.int) -> clay.SizingAxis {
	ty := int(flat_number(L, index))
	a, b := flat_number(L, index+1), flat_number(L, index+2)
	switch ty {
	case 1: return clay.SizingGrow({a,b})
	case 2: return clay.SizingPercent(a)
	case 3: return clay.SizingFixed(a)
	case: return clay.SizingFit({a,b})
	}
}
frame_open :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	frame_guard(L)
	r := self(L)
	context.allocator = r.allocator
	if len(r.frame.nodes) >= 4094 || len(r.frame.stack) >= 256 { return lua.L_error(L, "frame declaration capacity exceeded") }
	node: layout.Node
	node.client.id = u32(lua.tonumber(L, 2))
	if node.client.id != 0 {
        if r.lock_declaring { return lua.L_error(L,"client surfaces cannot be declared in the lock context") }
		if r.valid_client == nil || !r.valid_client(r.data, node.client.id, r.screen) { return lua.L_error(L, "core.surface: invalid or unmapped handle") }
		if r.surfaces[node.client.id] { return lua.L_error(L, "core.surface: handle declared twice in one frame") }
	}
	lua.rawgeti(L, 1, 1)
	node.named = lua.type(L, -1) == .STRING
	name := lua_string(L, -1)
	lua.rawgeti(L, 1, 2)
	node.index = u32(lua.tonumber(L, -1))
	lua.pop(L, 1)
	if node.named {
		id := layout.element_id(name, node.index).id
		if r.ids[id] { return lua.L_error(L, "duplicate element id") }
		r.ids[id] = true
	}
	d := &node.declaration
	d.layout.sizing = {axis(L, 3), axis(L, 6)}
	d.layout.padding = {u16(flat_number(L, 9)), u16(flat_number(L, 10)), u16(flat_number(L, 11)), u16(flat_number(L, 12))}
	d.layout.childGap = u16(flat_number(L, 13))
	d.layout.childAlignment = {clay.LayoutAlignmentX(flat_number(L, 14)), clay.LayoutAlignmentY(flat_number(L, 15))}
	d.layout.layoutDirection = clay.LayoutDirection(flat_number(L, 16))
	d.backgroundColor = {flat_number(L, 17), flat_number(L, 18), flat_number(L, 19), flat_number(L, 20)}
	d.cornerRadius = {flat_number(L,21),flat_number(L,22),flat_number(L,23),flat_number(L,24)}
	d.border.color = {flat_number(L,25),flat_number(L,26),flat_number(L,27),flat_number(L,28)}
	d.border.width = {u16(flat_number(L,29)),u16(flat_number(L,30)),u16(flat_number(L,31)),u16(flat_number(L,32)),u16(flat_number(L,33))}
	d.aspectRatio.aspectRatio = flat_number(L,34)
	d.clip = {flat_number(L,36)!=0,flat_number(L,37)!=0,{flat_number(L,38),flat_number(L,39)}}
	d.floating = {
		offset={flat_number(L,40),flat_number(L,41)},expand={flat_number(L,42),flat_number(L,43)},
		zIndex=i16(flat_number(L,44)),attachment={clay.FloatingAttachPointType(flat_number(L,45)),clay.FloatingAttachPointType(flat_number(L,46))},
		pointerCaptureMode=clay.PointerCaptureMode(flat_number(L,47)),attachTo=clay.FloatingAttachToElement(flat_number(L,48)),
		clipTo=clay.FloatingClipToElement(flat_number(L,49)),
	}
	lua.rawgeti(L,1,50)
	if lua.type(L,-1)==.STRING {
		lua.rawgeti(L,1,51)
		parent_index:=u32(lua.tonumber(L,-1))
		lua.pop(L,1)
		d.floating.parentId=layout.element_id(lua_string(L,-1),parent_index).id
	}
	lua.pop(L,1)
	lua.rawgeti(L,1,35)
	node.is_image = lua.type(L,-1)==.STRING
	path := lua_string(L,-1)
	// All Lua reads finish before acquiring memory; the protected caller owns this frame.
	node.image_path = strings.clone(path)
	node.name = strings.clone(name)
	node.end = len(r.frame.nodes)+1
	append(&r.frame.nodes, node)
	if node.client.id == 0 { append(&r.frame.stack, len(r.frame.nodes)-1) }
	else { r.surfaces[node.client.id] = true }
	return 0
}
frame_close :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	frame_guard(L)
	r := self(L)
	context.allocator = r.allocator
	if len(r.frame.stack) == 0 { return lua.L_error(L, "core.close without matching core.open") }
	i := pop(&r.frame.stack)
	r.frame.nodes[i].end = len(r.frame.nodes)
	return 0
}
read_box :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	context.allocator = r.allocator
	ui := r.current_layout
	if r.declaring { ui = r.frame_layout }
	if ui == nil { lua.pushnil(L); return 1 }
	b, found := layout.box(ui, lua_string(L, 1), u32(lua.tonumber(L, 2)))
	if !found { lua.pushnil(L); return 1 }
	lua.newtable(L)
	number(L, "x", f64(math.floor(b.x+0.5)))
	number(L, "y", f64(math.floor(b.y+0.5)))
	number(L, "width", f64(math.floor(b.width+0.5)))
	number(L, "height", f64(math.floor(b.height+0.5)))
	return 1
}
read_hits :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	context.allocator = r.allocator
	lua.newtable(L)
	if r.find_layout == nil { return 1 }
	ui, x, y := r.find_layout(r.data, lua_string(L, 1))
	if ui == nil { return 1 }
	r.current_layout = ui
	// Store the result on the runtime so a Lua allocation failure cannot leak it.
	delete(r.hit_result)
	r.hit_result = layout.hits(ui, f32(lua.tonumber(L, 2)-lua.Number(x)), f32(lua.tonumber(L, 3)-lua.Number(y)))
	for hit, i in r.hit_result {
		lua.newtable(L)
		push_string(L, hit.name); lua.setfield(L, -2, "name")
		number(L, "index", f64(hit.index))
		lua.rawseti(L, -2, c.int(i+1))
	}
	return 1
}
mark_dirty :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	context.allocator = r.allocator
	if r.dirty != nil { r.dirty(r.data, lua_string(L, 1), lua.isnoneornil(L, 1)) }
	return 0
}
lua_string :: proc(L: ^lua.State, index: c.int) -> string {
	n: c.size_t
	p := lua.tolstring(L, index, &n)
	if p == nil { return "" }
	return string(([^]u8)(p)[:int(n)])
}
push_string :: proc(L: ^lua.State, value: string) {
	lua.pushlstring(L, cast(cstring)raw_data(value), c.size_t(len(value)))
}

font :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	context.allocator = r.allocator
	id := paint.intern_font(&r.fonts, lua_string(L,1))
	lua.pushinteger(L,lua.Integer(id))
	return 1
}
frame_text :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	frame_guard(L)
	r := self(L)
	context.allocator = r.allocator
	if len(r.frame.nodes) >= 4094 { return lua.L_error(L,"frame declaration capacity exceeded") }
	cfg := clay.TextElementConfig{
		textColor={flat_number(L,1),flat_number(L,2),flat_number(L,3),flat_number(L,4)},
		fontId=u16(flat_number(L,5)),fontSize=u16(flat_number(L,6)),
		letterSpacing=u16(flat_number(L,7)),lineHeight=u16(flat_number(L,8)),
		wrapMode=clay.TextWrapMode(flat_number(L,9)),textAlignment=clay.TextAlignment(flat_number(L,10)),
	}
	cfg.userData = rawptr(uintptr(flat_number(L,11)))
	value := lua_string(L,2)
	append(&r.frame.nodes,layout.Node{is_text=true,text=strings.clone(value),text_config=cfg,end=len(r.frame.nodes)+1})
	return 0
}

image_reload :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	context.allocator = r.allocator
	images.reload(&r.images,lua_string(L,1))
	return 0
}

ui_hooks :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	lua.L_checktype(L, 1, .FUNCTION)
	lua.L_checktype(L, 2, .FUNCTION)
	lua.pushvalue(L, 1)
	begin := lua.L_ref(L, lua.REGISTRYINDEX)
	lua.pushvalue(L, 2)
	publish := lua.L_ref(L, lua.REGISTRYINDEX)
	lua.L_unref(L, lua.REGISTRYINDEX, r.ui_begin_ref)
	lua.L_unref(L, lua.REGISTRYINDEX, r.ui_publish_ref)
	r.ui_begin_ref, r.ui_publish_ref = begin, publish
	if r.declaring {
		lua.rawgeti(L, lua.REGISTRYINDEX, begin)
		push_string(L, r.screen)
		lua.call(L, 1, 0)
	}
	return 0
}
ui_publish_call :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := (^Runtime)(lua.touserdata(L, 1))
	lua.rawgeti(L, lua.REGISTRYINDEX, r.ui_publish_ref)
	push_string(L, r.screen)
	lua.call(L, 1, 0)
	return 0
}
publish_ui :: proc(r: ^Runtime) {
	if r.ui_publish_ref == lua.NOREF {return}
	base := lua.gettop(r.state)
	defer lua.settop(r.state, base)
	if lua.cpcall(r.state, ui_publish_call, r) != .OK {
		fmt.eprintln("Lua UI publish:", lua.tostring(r.state, -1))
	}
}

reset_frame_handler :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	if r.declaring { return lua.L_error(L, "frame reset requires a safe boundary") }
	context.allocator = r.allocator
	lua.L_unref(L, lua.REGISTRYINDEX, r.frame_ref)
	r.frame_ref = lua.NOREF
	layout.clear_frame(&r.frame)
	clear(&r.ids)
	clear(&r.surfaces)
	r.config_generation += 1
	return 0
}

frame_contains :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    frame_guard(L)
    r := self(L)
    id := layout.element_id(lua_string(L, 1), u32(lua.tonumber(L, 2))).id
    lua.pushboolean(L, b32(r.ids[id]))
    return 1
}
