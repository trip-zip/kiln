package layout

import "base:runtime"
import "core:fmt"
import "core:strings"
import paint "../paint"
import images "../images"
import clay "deps:clay"

Box :: struct { x, y, width, height: f32 }
Client :: struct { id: u32 }
Rectangle :: struct { color: [4]f32, radii: paint.Radii }
Border :: struct { color: [4]f32, radii: paint.Radii, widths: paint.Widths }
Text :: struct { value: string, color: [4]f32, font, size, spacing, line_height: u16, ellipsis: i32 }
Image :: struct { entry: ^images.Entry, generation: u64, usable: bool, color: [4]f32, radii: paint.Radii }
Content :: union { Rectangle, Client, Border, Text, Image }
Command :: struct { id: u32, box: Box, content: Content, clip: Clip }
Node :: struct {
	name: string,
	index: u32,
	named: bool,
	declaration: clay.ElementDeclaration,
	client: Client,
	text: string,
	image_path: string,
	is_image: bool,
	text_config: clay.TextElementConfig,
	is_text: bool,
	end: int,
}
Frame :: struct {
	nodes: [dynamic]Node,
	stack: [dynamic]int,
}
Hit :: struct { name: string, index: u32 }
Layout :: struct {
	ctx: [2]^clay.Context,
	roots: [2]map[u32]u32,
	memory: [2][]u8,
	active, candidate: int,
    persistent: bool,
    inspect_events: [dynamic]Inspector_Pointer,
    inspect_point, inspect_scroll: clay.Vector2,
    inspect_down, inspect_capture, inspect_have: bool,
    saved: Frame,
    width, height, pending_width, pending_height: i32,
    accepted_debug: bool,
	commands: [dynamic]Command,
	pending: [dynamic]Command,
	text_storage: [2][dynamic]string,
	fonts: ^paint.Fonts,
	images: ^images.Cache,
	fallback_fonts: paint.Fonts,
	measurer: paint.Measurer,
	scale: f32,
	cache_scale: [2]f32,
	boxes: map[u32]Box,
	names: map[string]string,
	hidden: map[u32]bool,
	failed: bool,
	solves: u64,
}

clear_frame :: proc(f: ^Frame) {
	for node in f.nodes { delete(node.name); delete(node.text); delete(node.image_path) }
	clear(&f.nodes)
	clear(&f.stack)
}
destroy_frame :: proc(f: ^Frame) {
	clear_frame(f)
	delete(f.nodes)
	delete(f.stack)
}

on_error :: proc "c" (error: clay.ErrorData) {
	context = runtime.default_context()
	l := (^Layout)(error.userData)
	l.failed = true
	fmt.eprintf("Clay: %s\n", string(error.errorText.chars[:error.errorText.length]))
}

init :: proc(l: ^Layout) -> bool {
	paint.intern_font(&l.fallback_fonts,"Sans")
	if !paint.init_measurer(&l.measurer) { return false }
	l.boxes = make(map[u32]Box)
	l.names = make(map[string]string)
	l.hidden = make(map[u32]bool)
	for i in 0..<2 {
		l.roots[i]=make(map[u32]u32)
		l.memory[i] = make([]u8, int(clay.MinMemorySize()))
		arena := clay.CreateArenaWithCapacityAndMemory(uint(len(l.memory[i])), raw_data(l.memory[i]))
		l.ctx[i] = clay.Initialize(arena, {1, 1}, {handler = on_error, userData = l})
		if l.ctx[i] == nil || l.failed { return false }
	}
	return true
}

clear_commands :: proc(commands: ^[dynamic]Command) {
    for command in commands^ { if v,ok:=command.content.(Image);ok { images.release(v.entry) }; if v,ok:=command.content.(Text);ok { delete(v.value) } }
    clear(commands)
}
destroy :: proc(l: ^Layout) {
    clear_commands(&l.commands);clear_commands(&l.pending)
    destroy_frame(&l.saved)
    delete(l.inspect_events)
	for ctx, i in l.ctx {
		if ctx != nil && clay.GetCurrentContext() == ctx { clay.SetCurrentContext(nil) }
		delete(l.memory[i])
		delete(l.roots[i])
	}
	for _, name in l.names { delete(name) }
	delete(l.names)
	delete(l.boxes)
	delete(l.hidden)
	delete(l.commands)
	delete(l.pending)
	for &storage in l.text_storage { for value in storage { delete(value) }; delete(storage) }
	paint.destroy_measurer(&l.measurer)
	paint.destroy_fonts(&l.fallback_fonts)
	l^ = {}
}

// Offset hashing preserves both indexed readback and the offset returned by hits.
element_id :: proc(name: string, index: u32 = 0) -> clay.ElementId {
	return clay.GetElementIdWithIndex(clay.MakeString(name), index)
}

intern :: proc(l: ^Layout, name: string) -> string {
	if value, ok := l.names[name]; ok { return value }
	value := strings.clone(name)
	l.names[value] = value
	return value
}

declare_nodes :: proc(l: ^Layout, nodes: []Node, start, end: int, root: u32 = 0, geometry_pass := false) {
	for i := start; i < end; {
		node := &nodes[i]
		if node.is_text {
			value := strings.clone(node.text)
			append(&l.text_storage[l.candidate], value)
			clay.Text(value, node.text_config)
			i = node.end
			continue
		}
		d := node.declaration
		if geometry_pass { d.floating.zIndex = 0 }
		if node.is_image && l.images!=nil { d.image.imageData = images.get(l.images,node.image_path) }
		if node.client.id != 0 { d.custom.customData = rawptr(uintptr(node.client.id)) }
		if node.named {
			if clay.UI(element_id(intern(l, node.name), node.index))(d) {
				id:=clay.GetOpenElementId()
				child_root:=root
				if d.floating.attachTo!=.None { child_root=id }
				l.roots[l.candidate][id]=child_root
				declare_nodes(l, nodes, i+1, node.end,child_root,geometry_pass)
			}
		} else {
			if clay.UI()(d) {
				id:=clay.GetOpenElementId()
				child_root:=root
				if d.floating.attachTo!=.None { child_root=id }
				l.roots[l.candidate][id]=child_root
				declare_nodes(l, nodes, i+1, node.end,child_root,geometry_pass)
			}
		}
		i = node.end
	}
}

measure_text :: proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, data: rawptr) -> clay.Dimensions {
	context = runtime.default_context()
	l := (^Layout)(data)
	fonts := l.fonts
	if fonts == nil { fonts = &l.fallback_fonts }
	w,h := paint.measure(&l.measurer, fonts, string(text.chars[:text.length]), config.fontId, config.fontSize, density(l))
	return {f32(w), f32(h)}
}

// Preparation cannot publish boxes or pointer state until all rasters are ready.
prepare :: proc(l: ^Layout, width, height: i32, nodes: []Node) -> ([]Command, bool) {
	if l.images!=nil { l.images.clock += 1 }
	defer { if l.images!=nil { images.trim(l.images) } }
	candidate := l.active if l.persistent else 1-l.active
    l.candidate=candidate
    l.pending_width,l.pending_height=width,height
    accepted:=false
    defer { if !accepted { rollback(l) } }
	clay.SetCurrentContext(l.ctx[candidate])
	defer clay.SetCurrentContext(l.ctx[l.active])
	clay.SetMeasureTextFunction(measure_text, l)
	if l.cache_scale[candidate]!=density(l) {
		clay.ResetMeasureTextCache()
		l.cache_scale[candidate]=density(l)
	}
	for value in l.text_storage[candidate] { delete(value) }
	clear(&l.text_storage[candidate])
	clay.SetLayoutDimensions({f32(width), f32(height)})
	// Keep scissor scopes balanced and retain pixels when a viewport moves.
	clay.SetCullingEnabled(false)
	l.failed = false
	clear(&l.roots[candidate])
	// Negative roots are positioned before their in-flow parents by Clay.
	// Warm current boxes through its public layout API before applying paint order.
	for node in nodes {
		if node.declaration.floating.attachTo!=.None && node.declaration.floating.zIndex<0 {
			clay.BeginLayout()
			declare_nodes(l,nodes,0,len(nodes),geometry_pass=true)
			clay.EndLayout(0)
			if l.failed { return nil,false }
			for value in l.text_storage[candidate] { delete(value) }
			clear(&l.text_storage[candidate])
			clear(&l.roots[candidate])
			break
		}
	}
	inspector_feed(l)
	clay.BeginLayout()
	l.roots[candidate][clay.GetOpenElementId()]=0
	declare_nodes(l, nodes, 0, len(nodes))
	result := clay.EndLayout(0)
    inspector_retire_edge(l)
	if l.failed { return nil, false }
	clear_commands(&l.pending)
	image_ids := make(map[u32]bool)
	defer delete(image_ids)
	for command in result.internalArray[:result.length] {
		if command.commandType==.Image { image_ids[command.id]=true }
	}
	clips: [dynamic]Clip
	defer delete(clips)
	current: Clip
	for command in result.internalArray[:result.length] {
		box := Box(command.boundingBox)
		content: Content
		#partial switch command.commandType {
		case .ScissorStart:
			append(&clips,current)
			d := command.renderData.clip
            // Inherited float scissors omit axes; their box clips both.
            if !d.horizontal && !d.vertical { d.horizontal,d.vertical=true,true }
			current = intersect_clip(current,Clip{box,d.horizontal,d.vertical})
			continue
		case .ScissorEnd:
			if len(clips)==0 { return nil,false }
			current = pop(&clips)
			continue
		case .Rectangle:
			// Image color is stencil ink, not a second flat fill.
			if image_ids[command.id] { continue }
			d := command.renderData.rectangle
			content = Rectangle{d.backgroundColor/255, transmute(paint.Radii)d.cornerRadius}
		case .Border:
			d := command.renderData.border
			content = Border{d.color/255, transmute(paint.Radii)d.cornerRadius,
				{f32(d.width.left),f32(d.width.right),f32(d.width.top),f32(d.width.bottom)}}
		case .Text:
			d := command.renderData.text
			content = Text{strings.clone(string(d.stringContents.chars[:d.stringContents.length])),d.textColor/255,d.fontId,d.fontSize,d.letterSpacing,d.lineHeight,0}
			if command.userData!=nil && current.horizontal {
				available := i32(current.box.x+current.box.width-box.x)
				if available>0 && f32(available)<box.width { t:=content.(Text); t.ellipsis=available; content=t }
			}
		case .Image:
			d := command.renderData.image
			e := (^images.Entry)(d.imageData)
            images.retain(e)
			content = Image{e,e.generation,e.surface.handle!=nil,d.backgroundColor/255,transmute(paint.Radii)d.cornerRadius}
		case .Custom:
			content = Client{id=u32(uintptr(command.renderData.custom.customData))}
		case:
			fmt.eprintln("Unsupported Clay render command:", command.commandType)
			return nil, false
		}
		append(&l.pending, Command{command.id,box,content,current})
	}
	if len(clips)!=0 { return nil,false }
	accepted=true
    return l.pending[:], true
}

publish :: proc(l: ^Layout, nodes: []Node) {
	l.active = l.candidate
    l.width,l.height=l.pending_width,l.pending_height
	clay.SetCurrentContext(l.ctx[l.active])
	l.commands, l.pending = l.pending, l.commands
    clear_commands(&l.pending)
	clear(&l.hidden)
	for node in nodes {
		if node.named {
			id := element_id(node.name, node.index)
			data := clay.GetElementData(id)
			if data.found { l.boxes[id.id] = Box(data.boundingBox) }
		}
	}
	l.accepted_debug=clay.IsDebugModeEnabled()
    save_frame(&l.saved,nodes)
	l.solves += 1
}
solve :: proc(l: ^Layout, width, height: i32, nodes: []Node) -> ([]Command, bool) {
	_, ok := prepare(l,width,height,nodes)
	if !ok { return nil,false }
	publish(l,nodes)
	return l.commands[:],true
}

box :: proc(l: ^Layout, name: string, index: u32) -> (Box, bool) {
	clay.SetCurrentContext(l.ctx[l.active])
    if strings.has_prefix(name,"Clay__") {
        id:=element_id(name,index)
        if index==0 { id=clay.GetElementId(clay.MakeString(name)) }
        d:=clay.GetElementData(id)
        if d.found { return Box(d.boundingBox),true }
    }
    value, found := l.boxes[element_id(name, index).id]
	return value, found
}

// Clay orders floating roots front to back, then visits each root parent first.
// Reverse descendants within each root without reversing the roots themselves.
ordered_hits :: proc(l: ^Layout, x, y: f32) -> []clay.ElementId {
	clay.SetCurrentContext(l.ctx[l.active])
	previous:=clay.GetPointerState()
    defer clay.SetPointerState(previous.position,false)
	clay.SetPointerState({x, y}, false)
	ids := clay.GetPointerOverIds()
	result := make([dynamic]clay.ElementId, 0, int(ids.length))
	start := 0
	root: u32
	for i in 0 ..< int(ids.length) {
		id := ids.internalArray[i]
		next, known := l.roots[l.active][id.id]
		if known && next != root {
			for j := i - 1; j >= start; j -= 1 {append(&result, ids.internalArray[j])}
			start = i; root = next
		}
	}
	for j := int(ids.length) - 1; j >= start; j -= 1 {append(&result, ids.internalArray[j])}
	return result[:]
}
hits :: proc(l: ^Layout, x, y: f32) -> []Hit {
	ids := ordered_hits(l, x, y)
	defer delete(ids)
	result := make([dynamic]Hit, 0, min(32, len(ids)))
	for id in ids {
		if l.hidden[id.id] {continue}
		if len(result) == 32 {break}
		append(&result, Hit{string(id.stringId.chars[:id.stringId.length]), id.offset})
	}
	return result[:]
}

// Invalidate live leaves immediately, even when the next declaration fails.
forget_client :: proc(l: ^Layout, handle: u32) {
	l.hidden[element_id("core.surface", handle).id] = true
	for &command in l.commands {
		if client, ok := command.content.(Client); ok && client.id == handle { command.content = Client{} }
	}
}

// Return Clay cell selection independently of native popup/alpha arbitration.
hit :: proc(l: ^Layout, x, y: f32) -> Client {
	ids:=ordered_hits(l,x,y)
	defer delete(ids)
	for id in ids {
		if l.hidden[id.id] { continue }
		for command in l.commands {
			if command.id == id.id {
				if client, ok := command.content.(Client); ok { return client }
			}
		}
	}
	return {}
}

density :: proc(l: ^Layout) -> f32 { return l.scale>0 ? l.scale : 1 }

// Accepted declarations outlive the Lua frame scratch space and rebuild public
// geometry if a stable inspector context's candidate cannot be published.
save_frame :: proc(dst:^Frame,nodes:[]Node) {
    clear_frame(dst)
    for value in nodes {
        n:=value
        n.name,n.text,n.image_path=strings.clone(n.name),strings.clone(n.text),strings.clone(n.image_path)
        append(&dst.nodes,n)
    }
}
rollback :: proc(l:^Layout) {
    clear_commands(&l.pending)
    if !l.persistent { return }
    clay.SetCurrentContext(l.ctx[l.active])
    clay.SetDebugModeEnabled(l.accepted_debug)
    clay.SetLayoutDimensions({f32(l.width),f32(l.height)})
    for value in l.text_storage[l.active] { delete(value) }
    clear(&l.text_storage[l.active]);clear(&l.roots[l.active])
    l.candidate=l.active
    for node in l.saved.nodes {
        if node.declaration.floating.attachTo!=.None && node.declaration.floating.zIndex<0 {
            clay.BeginLayout()
            declare_nodes(l,l.saved.nodes[:],0,len(l.saved.nodes),geometry_pass=true)
            clay.EndLayout(0)
            for value in l.text_storage[l.active] { delete(value) }
            clear(&l.text_storage[l.active]);clear(&l.roots[l.active])
            break
        }
    }
    clay.BeginLayout()
    declare_nodes(l,l.saved.nodes[:],0,len(l.saved.nodes))
    clay.EndLayout(0)
}
