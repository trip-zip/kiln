"""Stock reset ownership, callback races and bounded resource residency."""
import c_baseline
import json
from pathlib import Path
import re
import time
from declaration_checks import check, wait, settle, capture
from window_state_checks import launch, stop, counts
from stock_checks import STOCK, HELPERS, private_data

TRACK='''
LOADS=(LOADS or 0)+1
local fn=ui.widget{watch={'client::property::title'},every=10,fn=function()end}
local same=ui.widget{watch={'client::property::title'},fn=function()end}
K.on_declare(function(s)fn();same()end)
PP=ui.popup{id='lifetime',w=120,h=60,color='#445588',keys={Escape='close'},on_close=function()
 CLOSES=(CLOSES or 0)+1
 core.timer(10000,function()STALE=(STALE or 0)+1 end)
 K.prompt.run{}
 error('close fixture')
end}
function up(fn,name)
 for i=1,30 do local n,v=debug.getupvalue(fn,i);if n==name then return v end end
end
function size(t)local n=0;for _ in pairs(t)do n=n+1 end;return n end
function refs()local n=0;for k,v in pairs(debug.getregistry())do if type(k)=='number' and type(v)=='function' then n=n+1 end end;return n end
function dismiss_errors()
 local all={};for _,n in ipairs(notification.all())do all[#all+1]=n end
 for _,n in ipairs(all)do
  assert(n.id==nil and n.urgency=='critical' and n.title=='Oops, an error happened!')
  n:dismiss()
 end
end
function snapshot()
 collectgarbage('collect')
 return refs(),#up(require('kiln.hook').add,'hooks'),size(up(ui.widget,'watched')),size(up(ui.widget,'timers'))
end
'''

def run(h):
    data,system,cache=private_data(h.out/'lifetime-data')
    config=STOCK+HELPERS+TRACK
    with h.boot(config,overrides={'XDG_DATA_HOME':data,'XDG_DATA_DIRS':system,'XDG_CACHE_HOME':cache}) as (server,env,work,log):
        def ev(src):check(h,env,'do '+src+' end',b'\n')
        def yes(src):wait(h,env,'return '+src,b'true\n',server)
        p,f=launch(env,work,'STOCK-LIFETIME',flags=('--title='+'Long terminal title '*20,))
        try:
            yes('#client.all()==1');ev('jit.off();jit.flush();HANDLE=client.all()[1].handle')
            settle(log);capture(env,work/'stock-foot.png')
            assert 'Image decode failed:' not in log.read_text()
            # Replacement table is used for both tiled and floating composites.
            ev("ORIG=W.titlebar;W.titlebar=function(c)ui.box{id={'replacement',c.handle},w='grow',h=19,color='#00cc55'}end;core.dirty()")
            settle(log);ev("assert(live({'replacement',HANDLE}));client.all()[1].floating=true")
            settle(log);ev("assert(live({'replacement',HANDLE}));client.all()[1].floating=false;W.titlebar=ORIG;core.dirty()")
            settle(log)
            # Two selected tags must still contribute one task/action per client.
            ev("s=screen.all()[1];c=client.all()[1];c.tags={s.tags[1],s.tags[2]};s.selected_tags={s.tags[1],s.tags[2]};core.dirty()")
            settle(log);ev("local n=0;for k in pairs(S.screen_presses[s.name])do if k=='on_press:task:'..c.handle..'#0' then n=n+1 end end;assert(n==1);c.tags={s.tags[1]};s.selected_tags={s.tags[1]}")
            # Snapshot iteration runs removed hooks once, new hooks next time.
            ev("ORDER='';local once=true;HA=K.on_declare(function()ORDER=ORDER..'a';if once then once=false;K.off_declare(HB);HC=K.on_declare(function()ORDER=ORDER..'c'end)end end);HB=K.on_declare(function()ORDER=ORDER..'b'end);core.dirty()")
            settle(log);ev("assert(ORDER:sub(1,2)=='ab');K.off_declare(HA);K.off_declare(HC)")
            # Reentrant replacement retains the newest keyboard owner.
            ev("R=ui.popup{id='reentrant',keys={Escape='close'},on_close=function()K.prompt.run{text='newest'}end};R:show();K.menu.show{items={{'old',function()end}}};assert(K.prompt.active.text=='newest' and not K.menu.open);R:destroy();K.prompt.active:stop()")
            # An action may request reload, but only after the old callback returns.
            ev("K.menu.show{items={{'reload',function()K.reload();AFTER=LOADS end}}};K.menu.nav('down');K.menu.nav('enter')")
            yes('LOADS==2');ev('assert(AFTER==1 and not K.menu.open)')
            # All transient types retire; config IDs and one copy of hooks return.
            openings=["PP:show()", "K.prompt.run{}", "K.menu.show{items={{'a',function()end}}}",
                      "K.hotkeys.show()", "K.launcher.open()", "K.tooltip.attach('tip')(true,{screen=screen.all()[1].name,name='clock',index=0})"]
            for i,opening in enumerate(openings,3):
                ev(opening+';K.reload()');yes('LOADS=='+str(i));settle(log)
                ev("assert(not K.prompt.active and not K.menu.open and not K.hotkeys.open and not K.tooltip.open and not PP.open);assert(#screen.all()[1].bars==1 and #screen.all()[1].tags==5 and client.all()[1].handle==HANDLE)")
            # Public watches re-subscribe exactly once; duplicate widgets share one listener.
            ev("local bus=up(client.on,'class_bus');assert(#bus.listeners['property::title']==#bus.marked['property::title']+1)")
            # Error popups are intentional live content; retire them before comparing closed scenes.
            ev('assert(#notification.all()>0);dismiss_errors()');settle(log)
            # Warm all transient raster paths, then measure equal closed scenes.
            ev('K.hotkeys.show()');settle(log);ev('K.hotkeys.close()');settle(log)
            before=h.ev(env,'return snapshot()').decode().strip()
            fds=len(list(Path(f'/proc/{server.pid}/fd').iterdir()))
            paint=re.findall(r'live buffers (\d+), live bytes (\d+)',log.read_text())[-1]
            ev("collectgarbage('collect');MEM=collectgarbage('count')")
            for i in range(8):
                ev("OLD=PP;PP:show();K.reload()")
                yes('LOADS=='+str(9+i));settle(log)
                ev("assert(#notification.all()==1 and notification.all()[1].message:find('close fixture',1,true));dismiss_errors()");settle(log)
                ev("OLD:destroy();OLD:show();assert(not OLD.open and not K.prompt.active and not STALE)")
                ev('K.hotkeys.show()');settle(log);ev('K.hotkeys.close()');settle(log)
                assert h.ev(env,'return snapshot()').decode().strip()==before
            assert len(list(Path(f'/proc/{server.pid}/fd').iterdir()))==fds
            assert re.findall(r'live buffers (\d+), live bytes (\d+)',log.read_text())[-1]==paint
            ev("collectgarbage('collect');assert(collectgarbage('count')<MEM+80)")
            (work/'resources.json').write_text(json.dumps({'fds':fds,'refs_hooks_watches_timers':before,'raster_buffers_bytes':paint,'heap_KiB':h.ev(env,"return MEM,collectgarbage('count')").decode().strip()},indent=2)+'\n')
            # Broken config can be repaired with the client still mapped.
            (work/'rc.lua').write_text("error('stock repair fixture')")
            ev('K.reload()');time.sleep(.15);h.healthy(env)
            ev("assert(W.titlebar==up(W.reset,'default_titlebar'))")
            (work/'rc.lua').write_text(config);ev('K.reload()');yes('LOADS==17');settle(log)
            ev('assert(client.all()[1].handle==HANDLE and #screen.all()[1].bars==1)')
            capture(env,work/'stock-repaired.png')
            # Synthetic output cleanup blocks callbacks reopening on the departing screen.
            ev("local s=screen.all()[1];PP:show();require('kiln.desktop_services').remove(s);assert(not PP.open and not K.prompt.active)")
            ev('K.reload()');yes('LOADS==18');settle(log)
            ev('K.hotkeys.show()');h.quit(server,env,log)
            assert 'Async cleanup: timers 0, pipes 0' in log.read_text()
            assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
        finally:stop(p);f.close()
    print('PASS: stock callbacks/reentrancy/hook snapshots/replacement/dedup, all transient reloads, watches, GC/FD/ref/raster soak, broken config repair and synthetic output loss:',work.resolve(),flush=True)

if __name__=='__main__':
    import importlib.util
    import tempfile
    from stock_checks import ROOT
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    out=Path(tempfile.mkdtemp(prefix='stock-lifetime-',dir=ROOT/'build/verification'));print(out,flush=True)
    with tempfile.TemporaryDirectory(prefix='ko-life-') as t:
        alias=Path(t)/'e';alias.symlink_to(out,target_is_directory=True)
        run(m.Harness(ROOT/'build/kiln',c_baseline.source(),alias))
