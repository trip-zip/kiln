package lua_runtime

import "core:testing"
import layout "../layout"
import lua "../luajit"

reload_requested :: proc(data: rawptr) {}

@(test)
reload_defers_coalesces_and_rejects_active_candidates :: proc(t: ^testing.T) {
	r := Runtime{request_reload=reload_requested}
	testing.expect(t, init(&r))
	defer destroy(&r)
	l: layout.Layout
	testing.expect(t, layout.init(&l))
	defer layout.destroy(&l)
	reply := evaluate(&r, `count=0
function replace()
 count=count+1;assert(not core._reload(replace));core._frame_reset()
 core.set_frame_handler(function() core.open{id='new'};core.close() end)
end
core.set_frame_handler(function()
 core.open{id='old'};assert(core._reload(replace));assert(not core._reload(replace))
 assert(count==0);core.close();finished=true
end)`)
	testing.expect_value(t, reply, "\n");delete(reply)
	_, valid := declare(&r, &l, "TEST", 100, 100)
	testing.expect(t, !valid && r.reload_pending)
	apply_reload(&r)
	testing.expect(t, !r.reload_pending && !r.reloading && r.reload_ref==lua.NOREF)
	testing.expect_value(t,len(r.frame.nodes),0)
	reply = evaluate(&r, "return count,finished")
	testing.expect_value(t, reply, "1\ttrue\n");delete(reply)
	_, valid = declare(&r, &l, "TEST", 100, 100)
	testing.expect(t, valid)
	r.loading_config=true
	reply=evaluate(&r,"return core._reload(replace)")
	testing.expect_value(t,reply,"false\n");delete(reply)
	r.loading_config=false
	reply=evaluate(&r,"core._reload(function() error('reload callback') end)")
	delete(reply)
	apply_reload(&r)
	testing.expect(t,!r.reload_pending && r.reload_ref==lua.NOREF)
}

@(test)
bus_snapshots_defaults_and_retired_registry_objects :: proc(t: ^testing.T) {
	r: Runtime
	testing.expect(t, init(&r))
	defer destroy(&r)
	reply := evaluate(&r, `package.path='lua/?.lua;lua/?/init.lua;'..package.path
local Bus=require('kiln.bus');local b=Bus.new();local n=0
local default=function() n=n+1 end
b:on('probe',default);b:mark();b:off('probe',default);b:mark();b:reset();b:emit('probe');assert(n==1)
b:off('probe',default);b:reset();b:emit('probe');assert(n==2)
local plain=Bus.new();plain:on('x',function() plain:reset() end)
plain:on('x',function() error('retired snapshot') end)
local errors=0;Bus.on_error=function() errors=errors+1 end
plain:emit('x');assert(errors==0)
local object=require('kiln.object');local cls=object.class('probe');local a=cls.new{handle=1,tags={}};local hidden=cls.new{handle=2,tags={}}
object.attach(1,a);object.attach(2,hidden);object.retire()
assert(not object.lookup(1) and not object.lookup(2) and a.dead and hidden.dead)
local fresh=cls.new{handle=1};object.attach(1,fresh)
cls.on('property::foo',function() error('retired object') end)
a.foo=1;a:emit('property::foo');assert(errors==0 and object.lookup(1)==fresh)
return 'retired'`)
	defer delete(reply)
	testing.expect_value(t,reply,"retired\n")
}
