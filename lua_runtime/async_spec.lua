package.path='lua/?.lua;lua/?/init.lua;'..package.path
local timers, next_id, callbacks, ticks, dirties = {},0,{}, {},{}
core.timer=function(ms,fn) next_id=next_id+1;timers[next_id]=fn;return next_id end
core.timer_cancel=function(id) timers[id]=nil end
core.spawn_pipe=function(cmd) next_id=next_id+1;return next_id end
core.tick=function(s,on) ticks[s]=on end
core.dirty=function(s) dirties[#dirties+1]=s or '*' end
local spawn=require('kiln.spawn')
local poll=require('kiln.poll')
local animation=require('kiln.animation')
local errors=0
require('kiln.bus').on_error=function() errors=errors+1;error('bad sink') end
local lines,err,exit={},'',0
local id=spawn.pipe('x',{on_line=function(l) lines[#lines+1]=l;error('line') end,
 on_err=function(s) err=err..s;error('stderr') end,on_exit=function() exit=exit+1;error('exit') end})
local function out(id,data,fd) spawn.on_event{id=id,name='out',fd=fd or 1,data=data} end
local function done(id) spawn.on_event{id=id,name='exit',code=0} end
out(id,'\nA\0B\n\195');out(id,'\169\ntail');out(id,'err\0',2);done(id);done(id)
assert(#lines==4 and lines[1]=='' and lines[2]=='A\0B' and lines[3]=='é' and lines[4]=='tail')
assert(err=='err\0' and exit==1 and errors==6)
local h=spawn.watch('x',.1,{line=function() error('watch line') end,done=function() error('watch done') end})
id=next_id;out(id,'line\n');done(id)
assert(timers[next_id]);local timer=next_id
h:stop();h:stop();assert(not timers[timer])
local l,d=0,0
h=spawn.watch('x',1,{line=function() l=l+1 end,done=function() d=d+1 end})
id=next_id;h:stop();out(id,'x\n');done(id);assert(l==1 and d==0)
h=spawn.watch('x',1,{done=function() d=d+1 end});id=next_id;spawn.reset();done(id);assert(d==0)
h=spawn.watch('x',1,function() end);done(next_id);timer=next_id;spawn.reset();assert(not timers[timer])
local p=poll{'x',every=.1,screen='A',parse=function(ls) assert(#ls==2);return ls[1] end}
id=next_id;out(id,'one\n');assert(#p.lines==0);out(id,'two\n');done(id)
assert(p.value=='one' and table.concat(p.lines,'|')=='one|two' and dirties[#dirties]=='A')
local dirty_count=#dirties;timers[next_id]();id=next_id;out(id,'one\ntwo\n');done(id)
assert(#dirties==dirty_count)
timers[next_id]();id=next_id;out(id,'bad\n');done(id)
assert(p.value=='one' and #p.lines==2 and timers[next_id])
timers[next_id]();id=next_id;p:stop();out(id,'late\nlate\n');done(id);assert(p.value=='one')
spawn.reset()
assert(animation.get('x',4)==4)
animation.start('A','x',10,1)
assert(animation.get('x',0)==4 and ticks.A)
animation.on_tick{screen='A',dt=1}
local v=animation.get('x',0)
assert(math.abs(v-(4+6*(1-.95^3)))<1e-9)
animation.start('A','x',20,1)
assert(animation.get('x',0)==v)
animation.start('B','x',30,1)
assert(not ticks.A and ticks.B and animation.get('x',0)==v)
animation.start('B','y',1,.1,0)
animation.on_tick{screen='B',dt=.05};animation.on_tick{screen='B',dt=.05}
assert(ticks.B and animation.get('y',1)==1)
animation.remove('B');assert(not ticks.B)
animation.start('A','z',2,0,0);animation.on_tick{screen='A',dt=.01};assert(not ticks.A)
assert(animation.get('z',7)==7);animation.start('A','z',8);assert(animation.get('z',0)==7)
animation.reset();assert(not ticks.A)
return 'async policy ok'
