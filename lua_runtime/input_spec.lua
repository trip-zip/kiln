package.path='lua/?.lua;lua/?/init.lua;'..package.path
local dispatch
local set=core.set_event_handler
core.set_event_handler=function(fn) dispatch=fn;set(fn) end
core.output.list=function() return {{name='B',x=800,y=50,width=800,height=600},{name='A',x=0,y=0,width=800,height=600}} end
local K=require('kiln')
local state=require('kiln.state')
local grab=require('kiln.grab')
local object=require('kiln.object')
for _,s in ipairs(screen.all()) do tag.new{name='1',screen=s};tag.new{name='2',screen=s} end
local s1,s2=unpack(screen.all())
assert(K.input.repeat_rate==25 and K.input.repeat_delay==600)
local calls={}
local repeat_real=core.input.set_repeat
core.input.set_repeat=function(r,d) calls[#calls+1]={r,d} end
K.input.repeat_rate=30; K.input.repeat_delay=700
assert(calls[1][1]==30 and calls[1][2]==600 and calls[2][1]==30 and calls[2][2]==700)
core.input.set_repeat=repeat_real
local pointer_real=core.input.set_pointer
core.input.set_pointer=function(p) calls[#calls+1]=p end
K.input.tap_to_click=true;K.input.left_handed=false;K.input.accel_speed=.3;K.input.scroll_method=nil
assert(calls[3].tap_to_click==true and calls[3].left_handed==nil)
assert(calls[4].left_handed==false and calls[4].tap_to_click==nil and next(calls[6])==nil)
core.input.set_pointer=pointer_real
local km_real=core.input.set_keymap
local requested={layout='de'}
core.input.set_keymap=function(km) assert(km==requested or next(km)==nil) end
K.input.keymap=requested;assert(K.input.keymap==requested);K.input.keymap=nil
core.input.set_keymap=km_real
for _,fn in ipairs{core.input.grab_keyboard,core.input.grab_pointer,core.input.set_numlock} do
 assert(not pcall(fn,1));assert(not pcall(fn,nil));fn(false)
end
for _,args in ipairs{{'a',1},{25,false},{-1,600},{0/0,600},{1/0,600},{.5,600}} do assert(not pcall(core.input.set_repeat,unpack(args))) end
assert(not pcall(core.input.set_keymap,{layout={}}))
assert(not pcall(core.input.set_keymap,setmetatable({}, {__index=function() error('getter') end})))
assert(not pcall(core.input.set_pointer,{tap_to_click=1}))
assert(not pcall(core.input.set_pointer,{accel_speed=0/0}))
assert(not pcall(core.input.set_pointer,{click_method={}}))
assert(not pcall(core.input.set_cursor,{}))
for _,args in ipairs{{{},24},{'default',0},{'default',1/0},{'default',false}} do assert(not pcall(core.input.set_cursor_theme,unpack(args))) end
core.input.set_keymap{layout='us'};core.input.set_repeat(25,600);core.input.set_pointer{};core.input.set_cursor_theme(nil,24)
local native={key=false,mouse=false}
core.input.grab_keyboard=function(on) native.key=on end
core.input.grab_pointer=function(on) native.mouse=on end
local errors=0;K.on('error',function() errors=errors+1 end)
local function key(name) dispatch{class='input',name='key',key=name,utf8='',pressed=true,mods={}} end
local bound=0;K.key{key='F1',press=function() bound=bound+1 end}
local stopped=0
local a=K.keygrabber{function(e) assert(e.key=='F1') end,stopped=function() stopped=stopped+1 end}
key('F1');assert(bound==0)
local b=K.keygrabber{};assert(not a.active and b.active and stopped==1)
a:stop();assert(native.key);b:stop();b:stop();assert(not native.key)
key('F1');assert(bound==1)
dispatch{class='input',name='key',key='F1',pressed=true,mods={},_claimed=true};assert(bound==1)
local nested
local c=K.keygrabber{stopped=function() nested=K.keygrabber{} end}
local d=K.keygrabber{}
assert(nested.active and not c.active and not d.active and native.key)
d:stop();assert(native.key);nested:stop()
c=K.keygrabber{stopped=function() nested=K.keygrabber{} end};c:stop();c:stop();assert(nested.active and native.key);nested:stop()
c=K.keygrabber{key=function() error('key') end};key('F1');assert(not c.active and not native.key and errors==1 and bound==1)
c=K.mousegrabber{motion=function() error('motion') end};dispatch{class='input',name='motion',x=3,y=4,screen='A'}
assert(not c.active and not native.mouse and errors==2 and state.pointer.x==3)
c=K.mousegrabber{stopped=function() nested=K.mousegrabber{};error('stopped') end};c:stop();assert(nested.active and native.mouse and errors==3)
grab.reset();assert(not nested.active and not native.mouse)
c=K.mousegrabber{stopped=function() nested=K.mousegrabber{} end};grab.reset();assert(not nested.active and not native.mouse)
assert(not pcall(K.keygrabber,{key=true}) and not native.key)
-- Placement before any solve uses fallback dimensions and respects untouched axes.
dispatch{class='client',name='map',handle=1,width=0,height=0}
local w=object.lookup(1);w.tag=s2.selected_tag
state.pointer=nil
assert(K.placement.under_mouse(w)==w and w.float.x==200 and w.float.y==150)
state.workareas.B={x=10,y=30,width=700,height=500}
for name,at in pairs{centered={.5,.5},center_horizontal={.5},center_vertical={[2]=.5},left={0,.5},right={1,.5},top={.5,0},bottom={.5,1},top_left={0,0},top_right={1,0},bottom_left={0,1},bottom_right={1,1}} do
 w.float={x=99,y=88,width=200,height=100};local old=w.float
 assert(K.placement[name](w)==w and w.float~=old)
 assert(w.float.x==(at[1] and 10+math.floor(at[1]*500) or 99),name)
 assert(w.float.y==(at[2] and 30+math.floor(at[2]*400) or 88),name)
end
w.float={x=900,y=-50,width=900,height=800};K.placement.no_offscreen(w);assert(w.float.x==10 and w.float.y==30)
w.float={width=200,height=100};state.pointer={x=1200,y=300};K.placement.under_mouse(w)
assert(w.float.x==300 and w.float.y==200)
-- The same output origin is removed for nearest-corner resize.
w.floating=true;w.float={x=100,y=100,width=300,height=200}
local before=w.float;w:grab_move();w:grab_resize('nw');assert(w.float==before and not native.mouse)
K.button{button=1,press=function(c) c:grab_resize_nearest();error('press') end}
dispatch{class='input',name='button',button=1,pressed=true,client=1,screen='B',x=920,y=170,mods={}}
assert(native.mouse and state.current_press==nil)
dispatch{class='input',name='motion',x=930,y=190,screen='B'}
assert(w.float.x==110 and w.float.y==120 and w.float.width==290 and w.float.height==180)
dispatch{class='input',name='button',button=2,pressed=false,screen='B',x=930,y=190};assert(native.mouse)
dispatch{class='input',name='axis',screen='B',x=930,y=190,dy=10};assert(native.mouse)
dispatch{class='input',name='button',button=1,pressed=false,screen='B',x=930,y=190};assert(not native.mouse)
-- Output loss and unmap share ordinary claim cleanup.
dispatch{class='input',name='button',button=1,pressed=true,client=1,screen='B',x=920,y=170,mods={}}
dispatch{class='output',name='remove',output='B'};assert(not native.mouse)
return 'input policy ok'
