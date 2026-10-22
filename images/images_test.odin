package images
import "core:testing"
import "core:fmt"
import paint "../paint"

@(test)
cache_identity_failures_reload_and_live_budget :: proc(t: ^testing.T) {
	c: Cache
	init(&c)
	defer destroy(&c)
	c.budget=1
	c.clock=1
	e:=get(&c,"images/test.ppm")
	testing.expect(t,e.surface.handle!=nil)
	testing.expect_value(t,c.bytes,8)
	testing.expect(t,get(&c,"images/test.ppm")==e)
	testing.expect_value(t,c.decodes,1)
	trim(&c)
	testing.expect_value(t,c.bytes,8)
	raster,ok:=paint.create(40,20)
	testing.expect(t,ok)
	defer paint.destroy(raster)
	testing.expect(t,paint.image(raster,e.surface,{},{0,0,0,0}))
	before:=paint.alpha(raster,10,10)
	generation:=e.generation
	reload(&c,e.path)
	testing.expect_value(t,c.bytes,0)
	testing.expect_value(t,paint.alpha(raster,10,10),before)
	testing.expect(t,get(&c,e.path)==e && e.generation>generation)
	c.clock+=1
	trim(&c)
	testing.expect_value(t,c.bytes,0)
	testing.expect(t,get(&c,e.path)==e && e.surface.handle!=nil)
	for i in 0..<50 {
		c.clock+=1
		path:=fmt.aprintf("/nonexistent/kiln-fixture-%d",i)
		missing:=get(&c,path)
		delete(path)
		testing.expect(t,missing.surface.handle==nil)
		count:=c.decodes
		testing.expect(t,get(&c,missing.path)==missing)
		testing.expect_value(t,c.decodes,count)
		trim(&c)
		testing.expect_value(t,c.bytes,0)
	}
	testing.expect_value(t,len(c.entries),51)
}

@(test)
protocol_pixels_preserve_identity_and_retire_storage :: proc(t: ^testing.T) {
    c:Cache
    init(&c);defer destroy(&c)
    c.budget=1
    testing.expect(t,put_argb(&c,"xwl-icon:7",1,1,[]u32{0x80402010}))
    e:=get(&c,"xwl-icon:7")
    pixels:=([^]u32)(paint.data(e.surface))
    testing.expect_value(t,pixels[0],u32(0x80201008))
    generation:=e.generation
    c.clock+=1;trim(&c)
    testing.expect(t,e.surface.handle!=nil && c.decodes==0)
    reload(&c,e.path)
    testing.expect(t,e.surface.handle!=nil)
    testing.expect(t,put_argb(&c,e.path,1,1,[]u32{0xffabcdef}))
    testing.expect(t,e==get(&c,e.path) && e.generation>generation && c.bytes==4)
    retire(&c,e.path)
    testing.expect(t,c.bytes==0 && get(&c,e.path).surface.handle==nil && c.decodes==0)
}

@(test)
protocol_identity_retirement_preserves_borrowed_commands :: proc(t: ^testing.T) {
    cache: Cache
    init(&cache)
    defer destroy(&cache)
    for _ in 0..<100 {
        testing.expect(t,put_argb(&cache,"notify:temporary",1,1,[]u32{0xff102030}))
        e:=find(&cache,"notify:temporary")
        retain(e)
        forget(&cache,"notify:temporary")
        testing.expect_value(t,len(cache.entries),0)
        testing.expect_value(t,cache.bytes,u64(0))
        testing.expect(t,e.surface.handle==nil)
        testing.expect_value(t,e.path,"notify:temporary")
        release(e)
    }
}

@(test)
capture_budget_and_retirement :: proc(t:^testing.T) {
    cache:Cache
    init(&cache)
    defer destroy(&cache)
    cache.budget=64
    placeholder:=get(&cache,"screenshot:1")
    first,ok:=paint.create(4,4)
    testing.expect(t,ok)
    e:=put_capture(&cache,"screenshot:1",first)
    testing.expect(t,e==placeholder)
    retain(e)
    second,valid:=paint.create(4,4)
    testing.expect(t,valid)
    next:=put_capture(&cache,"screenshot:2",second)
    testing.expect_value(t,cache.bytes,u64(64))
    testing.expect(t,e.surface.handle==nil && next.surface.handle!=nil)
    // Evicted protocol pixels never trigger a file decode for the cache key.
    testing.expect(t,get(&cache,"screenshot:1").surface.handle==nil)
    testing.expect_value(t,cache.decodes,u64(1))
    reload(&cache,"screenshot:1")
    testing.expect_value(t,e.refs,1)
    release(e)
    reload(&cache,"screenshot:2")
    testing.expect_value(t,cache.bytes,u64(0))
    testing.expect_value(t,len(cache.entries),0)
}
