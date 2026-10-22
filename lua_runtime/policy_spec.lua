package.path = 'lua/?.lua;lua/?/init.lua;' .. package.path
local dispatch
local set = core.set_event_handler
core.set_event_handler = function(fn) dispatch=fn;set(fn) end
core.output.list = function() return {{name='B'},{name='A'}} end
local focus, grants, closed, killed = nil, {}, {}, {}
core.client.focus = function(h) focus=h;if h then grants[#grants+1]=h end end
core.client._focus_target = function() return focus end
core.client.close = function(h) closed[#closed+1]=h end
core.client.kill = function(h) killed[#killed+1]=h end
local k = require('kiln')
local object = require('kiln.object')
local errors = 0
k.on('error',function() errors=errors+1 end)
local a,b=unpack(screen.all())
for _,s in ipairs(screen.all()) do tag.new{name='1',screen=s};tag.new{name='2',screen=s} end
local function key(name, down, mods)
    dispatch{class='input',name='key',key=name,pressed=down,mods=mods or {}}
end
local got={}
k.modkey='alt'
k.key{mods={'mod'},key='1-9',desc='range',group='tag',press=function(v) got[#got+1]=v end}
k.key{mods={'mod'},key='a-e',release=function(v) got[#got+1]=v end}
k.key{mods={'mod'},key='F1',desc='first',press=function() got[#got+1]='first' end}
k.key{mods={'mod'},key='F1',desc='second',press=function() got[#got+1]='second' end}
assert(#k.key.all()==3 and k.key.all()[3].desc=='second')
assert(not pcall(k.key,{key='1-10'}) and not pcall(k.key,{key='NoSuchKey'}))
assert(#k.key.all()==3)
k.modkey='super'
assert(k.key.all()[1].label=='alt+1-9')
local copy=k.key.all();copy[1].mods[1]='super';assert(k.key.all()[1].mods[1]=='mod')
key('5',true,{alt=true});key('5',true,{alt=true,shift=true});key('5',true,{super=true})
key('c',true,{alt=true});assert(#got==1)
key('c',false,{alt=true});key('F1',true,{alt=true})
assert(got[1]==5 and got[2]=='c' and got[3]=='second')
k.key{mods={'alt'},key='3',press=function() end};assert(errors==1)
k.key{key='F2',press=function() k.key.clear();error('key failure') end}
key('F2',true);assert(errors==2 and #k.key.all()==0)
key('5',true,{alt=true});assert(#got==3)
local sink=require('kiln.bus');local old=sink.on_error
sink.on_error=function() error('sink failure') end
k.key{key='F3',press=function() error('bad handler') end};key('F3',true);sink.on_error=old
local function fact(name,h,app)
    dispatch{class='client',name=name,handle=h,app_id=app or 'app',title='initial title'}
end
local sequence={}
k.rule{props={bad=true},on=function() error('no selector ran') end}
k.rule{match={app={'^never$','^quiet$'},title='^initial'},props={screen='B',tag='2',focus=false,custom=1},on=function(c)
    assert(c.title=='initial title' and c.app_id=='quiet' and c.tag==b.tags[2] and c.no_focus)
    c:focus();sequence[#sequence+1]=1
end}
k.rule{match_any={app='quiet',title='absent'},except={title='initial'},props={bad=true}}
k.rule{match={app='quiet'},except_any={title={'absent','initial'}},props={bad=true}}
k.rule{match={fn=function(c) return c.app_id=='quiet' end},props={custom=2},on=function() sequence[#sequence+1]=2 end}
k.rule{match={fn=function() error('rule predicate') end}}
k.rule{match={app='quiet'},on=function(c) assert(c.custom==2);error('rule callback') end}
k.rule{match={app='quiet'},props={after_error=true,floating=true,fullscreen=true}}
b.tags[2]:view()
fact('map',1,'quiet');local q=object.lookup(1)
assert(q.custom==2 and q.after_error and not q.bad and q.tag==b.tags[2])
assert(#grants==0 and client.focus==nil and table.concat(sequence,',')=='1,2')
b.tags[1]:view()
k.rule.clear();fact('map',2);fact('map',3)
local c,d=object.lookup(2),object.lookup(3)
assert(client.focus==d and client.history()[1]==d and client.history.previous()==c)
local h=client.history();h[1]=nil;assert(client.history()[1]==d)
c:focus();assert(a.tags[1].clients[1]==c and client.history()[1]==c)
d.tags={a.tags[1],a.tags[2]};c.tags={a.tags[1],a.tags[2]}
c:raise();assert(a.tags[1].clients[2]==c and a.tags[2].clients[2]==c)
c:lower();assert(a.tags[1].clients[1]==c and a.tags[2].clients[1]==c)
c:swap(d);assert(a.tags[1].clients[1]==d and a.tags[2].clients[1]==d)
a.tags[2]:view();c:focus();fact('unmap',2)
assert(client.focus==d and client.history()[1]==d and #client.history()==1)
fact('map',2);k.defaults.successor=function(gone) assert(gone==c);return d end
fact('destroy',2);assert(client.focus==d)
k.defaults.successor=function() return nil end
c:raise();c:lower();c:swap(d);c:move_to(b);c:close();c:kill();assert(#c.tags==0 and #closed==0 and #killed==0)
d:move_to(b);assert(d.tag==b.selected_tag and client.focus==d and screen.focused==b)
k.focused(function(w,v) assert(w==d and v==17) end)(17)
d:emit('request::activate',{valid=false});assert(d.urgent)
d:emit('request::close');assert(closed[1]==3)
client.off('request::activate',k.defaults.activate)
local activation=false
client.on('request::activate',function() activation=true end)
d:emit('request::activate',{valid=true});assert(activation)
local function button(h, down, mods)
    dispatch{class='input',name='button',button=1,client=h,screen='B',pressed=down,mods=mods or {}}
end
local presses,releases,roots=0,0,0
k.button{button=1,mods={'mod'},press=function(w) assert(w==d);presses=presses+1;error('button error') end,
    release=function(w) assert(w==d);releases=releases+1;k.button.clear() end}
button(3,true,{super=true});button(3,false,{super=true});assert(presses==1 and releases==1)
k.button{button=1,on='root',press=function(w) assert(w==nil);roots=roots+1;k.button.clear() end}
button(nil,true);assert(roots==1)
b.tags[2]:view();q:focus();button(3,true);assert(client.focus==q)
b.tags[1]:view();button(3,true);assert(client.focus==d)
k.button{button=1,release=function() error('must not fire on press') end}
local n=errors;button(3,true);assert(errors==n)
button(999,true);button(nil,false);assert(errors==n)
-- An older native focus notification must retain the current pending target.
dispatch{class='input',name='focus',handle=1};assert(client.focus==d)
-- A focus listener can choose a newer client on a different screen.
d:move_to(a);b.tags[2]:view()
q:on('focus',function() d:focus() end)
core.client.focus(q.handle)
dispatch{class='input',name='focus',handle=q.handle}
assert(client.focus==d and screen.focused==a and client.history()[1]==d)
return 'policy ok'
