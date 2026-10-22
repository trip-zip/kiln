package.path = 'lua/?.lua;lua/?/init.lua;' .. package.path
local dispatch
local original_handler = core.set_event_handler
core.set_event_handler = function(fn) dispatch=fn; original_handler(fn) end
local outputs = {{name='B',width=800,height=600}, {name='A',width=800,height=600}}
core.output.list = function() return outputs end
local dirties = {}
core.dirty = function(name) dirties[name or '*'] = (dirties[name or '*'] or 0) + 1 end
local focus_handle
core.client.focus = function(handle) focus_handle=handle end
local kiln = require('kiln')
local object = require('kiln.object')
local a,b = unpack(screen.all())
assert(a.name=='A' and b.name=='B')
local added = 0
screen.on('added', function(s)
    added=added+1
    tag.new {name='one',screen=s}
    tag.new {name='two',screen=s}
end)
local function output(name, which) dispatch {class='output',name=name,output=which} end
output('add','A');output('add','B');output('add','A')
assert(added==2 and #screen.all()==2 and #a.tags==2)
local function fact(name, handle, extra)
    local ev=extra or {};ev.class='client';ev.name=name;ev.handle=handle;dispatch(ev)
end
local maps,unmaps,destroys=0,0,0
client.on('map',function(c) maps=maps+1;assert(c.width==30 and c.app_id=='test') end)
client.on('unmap',function() unmaps=unmaps+1 end)
client.on('destroy',function(c) destroys=destroys+1;assert(object.lookup(c.handle)==c) end)
fact('map',1,{width=30,height=40,app_id='test',title='first'})
local c=object.lookup(1)
assert(c.tag==a.tags[1] and c.screen==a and #client.all()==1)
fact('map',1,{width=30,height=40,app_id='test'})
assert(maps==1 and #a.tags[1].clients==1)

local seen={}
local instance=function(_,v) seen[#seen+1]='i'..v end
local class=function(_,v) seen[#seen+1]='c'..v end
c:on('property::custom',instance);client.on('property::custom',class)
c.custom=7;c.custom=7;c.custom=8
assert(table.concat(seen,',')=='i7,c7,i8,c8')
c:off('property::custom',instance);client.off('property::custom',class)
c.custom=9;assert(#seen==4 and c.custom==9)
local errors,after=0,0
kiln.on('error',function() errors=errors+1;error('error sink failure') end)
kiln.on('error',function() after=after+1 end)
local one,two,three
seen={}
one=function(self) seen[#seen+1]='one';self:off('probe',two);self:on('probe',three) end
two=function() seen[#seen+1]='two';error('listener failure') end
three=function() seen[#seen+1]='three' end
c:on('probe',one);c:on('probe',two)
c:emit('probe');c:emit('probe')
assert(table.concat(seen,',')=='one,two,one,three' and errors==1 and after==1)
local Bus=require('kiln.bus');local previous=Bus.on_error
Bus.on_error=function() error('broken replacement sink') end
local isolated=Bus.new();local survived=false
isolated:on('bad',function() error('listener') end)
isolated:on('bad',function() survived=true end)
isolated:emit('bad');assert(survived);Bus.on_error=previous
local klass=object.class('computed')
klass.getters.double=function(o) return o.value*2 end
klass.setters.double=function(o,v) o.value=v/2 end
local o=klass.new {value=3};assert(o.double==6);o.double=10;assert(o.value==5)

local before=dirties.A
c.width=100;c.height=100;c.custom=10
assert(dirties.A==before)
fact('commit_size',1,{width=111,height=222})
assert(c.width==111 and c.height==222 and dirties.A==before)
fact('metadata',1,{title='changed'})
assert(c.title=='changed' and c.app_id==nil and dirties.A>before)
local requests={}
for _,name in ipairs({'fullscreen','maximize','minimize'}) do
    client.on('request::'..name,function(_,on) requests[name]=on end)
    fact('request::'..name,1,{on=false})
    assert(requests[name]==false)
end
local tagged,untagged,changed=0,0,0
c:on('tagged',function() tagged=tagged+1 end)
c:on('untagged',function() untagged=untagged+1 end)
c:on('property::tags',function() changed=changed+1 end)
c.tags={a.tags[1],a.tags[2],a.tags[2]}
assert(#c.tags==2 and #a.tags[2].clients==1 and tagged==1 and changed==1)
c.tags={a.tags[1],a.tags[2]};assert(changed==1)
a.tags[2]:toggle()
assert(#a.selected_tags==2 and #kiln.visible_clients(a)==1)
a.tags[1]:toggle();a.tags[2]:toggle()
assert(a.selected_tag==a.tags[2])
a.selected_tags={};assert(a.selected_tag==a.tags[2])
assert(not pcall(function() a.selected_tags={b.tags[1]} end))
a.tags[1]:view();tag.history.restore(a);assert(a.selected_tag==a.tags[2])
tag.history.restore(a);assert(a.selected_tag==a.tags[1])
c.tag=a.tags[2]
assert(c.tag==a.tags[2] and untagged==1 and #a.tags[1].clients==0 and client.focus==nil and focus_handle==nil)
c:focus();assert(client.focus==nil)
a.tags[2]:view();assert(client.focus==c and focus_handle==1)
local deleted=a.tags[2];deleted:delete()
assert(#a.tags==1 and c.tag==a.tags[1] and a.selected_tag==a.tags[1])
deleted:view();assert(a.selected_tag==a.tags[1])
assert(not pcall(function() c.tag=deleted end))
a.tags[1]:delete();assert(#a.tags==1)

c.tags={a.tags[1],b.tags[1]}
assert(c.screen==a and #kiln.visible_clients(a)==1 and #kiln.visible_clients(b)==0)
c.tags={b.tags[1],a.tags[1]}
assert(c.screen==b and #kiln.visible_clients(a)==0 and #kiln.visible_clients(b)==1)
outputs={{name='A',width=800,height=600}}
local removed=false
screen.on('removed',function(s) removed=s==b and c.tag==a.tags[1] end)
output('remove','B')
assert(removed and #screen.all()==1 and client.focus==c and screen.focused==a)
local changed_output,width_changes=0,0
a:on('property::width',function(_,v) width_changes=width_changes+1;assert(v==900) end)
screen.on('changed',function(s) changed_output=changed_output+1;assert(s.width==900) end)
outputs[1].width=900;output('change','A');assert(changed_output==1 and a.width==900 and width_changes==1)

fact('unmap',1);assert(not c.mapped and object.lookup(1)==c and #client.all()==1 and #c.tags==1)
assert(client.focus==nil and focus_handle==nil)
fact('map',1,{width=30,height=40,app_id='test',title='remapped'})
assert(maps==2 and object.lookup(1)==c and #a.tags[1].clients==1 and c.title=='remapped')
fact('destroy',1)
assert(destroys==1 and unmaps==1 and object.lookup(1)==nil and #client.all()==0 and #c.tags==0)
c.tag=a.tags[1];c:focus();assert(#c.tags==0 and client.focus==nil)
fact('metadata',1,{title='stale'});assert(c.title=='remapped')
collectgarbage('collect')
-- A mapped object can survive the last output and acquire a new home later.
fact('map',2,{width=30,app_id='test'})
local orphan=object.lookup(2)
outputs={};output('remove','A');assert(#screen.all()==0 and #orphan.tags==0 and client.focus==nil)
outputs={{name='C',width=640,height=480}};output('add','C')
assert(orphan.tag==screen.all()[1].selected_tag and #client.all()==1)
return 'model ok'
