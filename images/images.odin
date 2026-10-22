package images

import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:os"
import g "../gdk_pixbuf"
import c "../cairo"
import p "../pango"
import paint "../paint"

Entry :: struct {
    refs: int,
	path: string,
	surface: paint.Surface,
	generation, touch: u64,
	decoded, supplied, evictable: bool,
}
Cache :: struct {
	entries: [dynamic]^Entry,
	bytes, budget, clock, decodes: u64,
}
init :: proc(cache: ^Cache) {
	cache.budget = 64*1024*1024
	value, found := os.lookup_env("KILN_IMAGE_BUDGET_MB",context.allocator)
	if found {
		defer delete(value)
		mb, ok := strconv.parse_uint(value)
		if ok && mb>0 && u64(mb)<=max(u64)/(1024*1024) { cache.budget = u64(mb)*1024*1024 }
	}
}
decode :: proc(path: string) -> paint.Surface {
	z := strings.clone_to_cstring(path)
	defer delete(z)
	err: ^g.GError
	pb := g.gdk_pixbuf_new_from_file(z,&err)
	defer { if err != nil { g.g_error_free(err) } }
	if pb == nil { fmt.eprintf("Image decode failed: %s\n",path); return {} }
	defer p.g_object_unref(pb)
	w,h := g.gdk_pixbuf_get_width(pb),g.gdk_pixbuf_get_height(pb)
	channels,stride := g.gdk_pixbuf_get_n_channels(pb),g.gdk_pixbuf_get_rowstride(pb)
	alpha := g.gdk_pixbuf_get_has_alpha(pb)!=0
	if g.gdk_pixbuf_get_bits_per_sample(pb)!=8 || g.gdk_pixbuf_get_colorspace(pb)!=0 ||
		channels!=(alpha ? 4 : 3) || i64(stride)<i64(w)*i64(channels) { return {} }
	s,ok := paint.create(w,h)
	if !ok { return {} }
	pixels := g.gdk_pixbuf_get_pixels(pb)
	if pixels == nil { paint.destroy(s); return {} }
	dst := paint.data(s)
	for y in 0..<int(h) {
		row := cast([^]u32)&dst[y*int(s.stride)]
		for x in 0..<int(w) {
			i := y*int(stride)+x*int(channels)
			a := alpha ? u32(pixels[i+3]) : 255
			row[x] = a<<24 | (u32(pixels[i])*a/255)<<16 | (u32(pixels[i+1])*a/255)<<8 | u32(pixels[i+2])*a/255
		}
	}
	c.cairo_surface_mark_dirty(s.handle)
	return s
}
canonical :: proc(path: string) -> string {
	for ch,i in transmute([]u8)path { if ch==0 { return path[:i] } }
	return path
}
find :: proc(cache: ^Cache, path: string) -> ^Entry {
	for e in cache.entries { if e.path==canonical(path) { return e } }
	return nil
}
get :: proc(cache: ^Cache, path: string) -> ^Entry {
	e := find(cache,path)
	if e==nil { e = new(Entry); e.refs=1; e.path = strings.clone(canonical(path)); append(&cache.entries,e) }
	e.touch = cache.clock
	if !e.decoded && !e.supplied {
		e.surface = decode(e.path)
		e.decoded = true
		e.generation += 1
		cache.decodes += 1
		cache.bytes += u64(e.surface.stride)*u64(e.surface.height)
	}
	return e
}
drop :: proc(cache: ^Cache, e: ^Entry) {
	cache.bytes -= u64(e.surface.stride)*u64(e.surface.height)
	paint.destroy(e.surface)
	e.surface = {}
	e.decoded = false
}
reload :: proc(cache: ^Cache, path: string) { if e := find(cache,path); e!=nil { if e.evictable { forget(cache,path) } else if !e.supplied { drop(cache,e) } } }
// Only the current solve borrows decoded pixels. Published scenes own independent rasters.
trim :: proc(cache: ^Cache) {
	for cache.bytes>cache.budget {
		oldest: ^Entry
		for e in cache.entries {
			if (e.supplied && !e.evictable) || e.surface.handle==nil || e.touch>=cache.clock { continue }
			if oldest==nil || e.touch<oldest.touch { oldest=e }
		}
		if oldest==nil { break }
		drop(cache,oldest)
	}
}
destroy :: proc(cache: ^Cache) {
	for e in cache.entries { drop(cache,e); release(e) }
	delete(cache.entries)
	cache^ = {}
}

// Protocol pixels have no file to decode again; their owner retains them until retirement.
put_argb :: proc(cache: ^Cache, path: string, width,height: i32, pixels: []u32) -> bool {
    if width<=0 || height<=0 || i64(width)*i64(height)!=i64(len(pixels)) { return false }
    surface,ok:=paint.create(width,height)
    if !ok { return false }
    dst:=paint.data(surface)
    for y in 0..<int(height) {
        row:=([^]u32)(&dst[y*int(surface.stride)])
        for x in 0..<int(width) {
            value:=pixels[y*int(width)+x];a:=value>>24
            row[x]=a<<24 | (((value>>16)&255)*a/255)<<16 | (((value>>8)&255)*a/255)<<8 | (value&255)*a/255
        }
    }
    c.cairo_surface_mark_dirty(surface.handle)
    e:=find(cache,path)
    if e==nil { e=new(Entry);e.refs=1;e.path=strings.clone(path);append(&cache.entries,e) }
    drop(cache,e)
    e.surface,e.decoded,e.supplied=surface,true,true
    e.generation+=1
    cache.bytes+=u64(surface.stride)*u64(surface.height)
    return true
}
retire :: proc(cache: ^Cache, path: string) {
    if e:=find(cache,path);e!=nil {
        drop(cache,e);e.decoded=true;e.supplied=false;e.generation+=1
    }
}

// Commands may retain an entry after its protocol owner has retired its key.
retain :: proc(e:^Entry) { e.refs+=1 }
release :: proc(e:^Entry) {
    e.refs-=1
    if e.refs==0 { paint.destroy(e.surface);delete(e.path);free(e) }
}
forget :: proc(cache:^Cache,path:string) {
    for e,i in cache.entries {
        if e.path!=path { continue }
        drop(cache,e);e.generation+=1
        ordered_remove(&cache.entries,i)
        release(e)
        return
    }
}

// Captures transfer their surface into the existing budget and retention model.
put_capture :: proc(cache:^Cache,path:string,surface:paint.Surface)->^Entry {
    cache.clock+=1
    e:=find(cache,path)
    if e==nil {
        e=new(Entry);e.refs=1;e.path=strings.clone(path)
        append(&cache.entries,e)
    } else { drop(cache,e) }
    e.surface=surface
    e.decoded=true;e.supplied=true;e.evictable=true;e.generation+=1;e.touch=cache.clock
    cache.bytes+=u64(surface.stride)*u64(surface.height)
    trim(cache)
    return e
}
