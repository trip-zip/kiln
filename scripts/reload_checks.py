"""Reload subset: real clients/input, config recovery and asynchronous retirement.

Stock bar/tasklist, launcher, popup, notification and XWayland legs are excluded.
"""
import c_baseline
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time

from PIL import Image
from declaration_checks import check, wait, capture
from async_checks import settles, solves, processes
from policy_checks import private_x11
from window_state_checks import launch, stop

ROOT=Path(__file__).resolve().parents[1]
DEFAULT=(ROOT/'scripts/fixtures/strip.lua').read_text()
TRACK='''
K=require('kiln');LOADS=(LOADS or 0)+1;MAPS=0;ADDS=0;RULES=0;assert(not K.reload())
K.on('probe',function() GLOBAL=(GLOBAL or 0)+1 end)
screen.on('added',function(s) ADDS=ADDS+1;s:on('probe',function() INSTANCE=(INSTANCE or 0)+1 end) end)
client.on('map',function() MAPS=MAPS+1 end)
K.rule{match={fn=function() RULES=RULES+1;return false end}}
function handles()
 local ids={};for _,c in ipairs(client.all()) do ids[#ids+1]=c.handle end
 table.sort(ids);return table.concat(ids,',')
end
function registry_count()
 local _,r=debug.getupvalue(require('kiln.object').lookup,1)
 local n=0;for _ in pairs(r) do n=n+1 end;return n
end
'''


def call(h,env,src):check(h,env,'do '+src+' end',b'\n')

def reload(h,env,server,number):
    call(h,env,"assert(K.reload());assert(not K.reload())")
    wait(h,env,'return LOADS',str(number).encode()+b'\n',server)


def clients(h):
    config=DEFAULT+TRACK+"\nclient.off('request::fullscreen',K.defaults.fullscreen)\n"
    with h.boot(config,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        children=[];files=[]
        def ev(s):call(h,env,s)
        def yes(s):wait(h,env,'return '+s,b'true\n',server)
        try:
            ev("S1,S2=unpack(screen.all());INPUT=K.input;MODULE=K;PATH=package.path;screen.focused=S1;K.input.repeat_rate=33")
            for label in ('A','B','C'):
                p,f=launch(env,work,label);children.append(p);files.append(f)
            yes('#client.all()==3 and MAPS==3 and RULES==3')
            ev("OLD={};for _,c in ipairs(client.all()) do OLD[c.app_id]=c end;IDS=handles();assert(registry_count()==3)")
            settles(log);capture(env,work/'before.png')
            ev("OLD.A:emit('request::fullscreen',true);assert(not OLD.A.fullscreen);OLD.B.minimized=true;OLD.C.tags={};assert(#client.all()==2 and registry_count()==3);OLD.A:on('property::dead',function() error('teardown property') end)")
            changed=DEFAULT.replace('h=36','h=56').replace("color='#378397'","color='#963b63'")+TRACK+'''
K.theme.accent='#ff2222'
K.rule{match={app='B'},props={floating=true,float={x=70,y=100,width=400,height=300},screen=screen.all()[2].name,focus=false}}
'''
            (work/'rc.lua').write_text(changed)
            reload(h,env,server,2)
            yes('#client.all()==3 and MAPS==3 and RULES==3 and ADDS==2')
            ev("assert(K==MODULE and K.input==INPUT and K.input.repeat_rate==33 and package.path==PATH);assert(screen.all()[1]==S1 and screen.all()[2]==S2);assert(handles()==IDS and registry_count()==3);local seen={};local count=0;for _,s in ipairs(screen.all()) do for _,t in ipairs(s.tags) do for _,c in ipairs(t.clients) do assert(not seen[c]);seen[c]=true;count=count+1 end end end;assert(count==3);local _,cb=debug.getupvalue(client.on,1);local defaults=0;for _,fn in ipairs(cb.listeners['request::fullscreen']) do if fn==K.defaults.fullscreen then defaults=defaults+1 end end;assert(defaults==1);for _,s in ipairs(screen.all()) do assert(#s.tags==2) end;for _,c in ipairs(client.all()) do assert(#c.tags==1 and c~=OLD[c.app_id] and c.mapped) end;for _,c in pairs(OLD) do assert(c.dead and not c.mapped and #c.tags==0);c:close();c:kill();c:focus();c.fullscreen=true;c:emit('request::close') end")
            ev("A,B,C=nil,nil,nil;for _,c in ipairs(client.all()) do _G[c.app_id]=c end;assert(B.floating and B.screen==S2 and not B.minimized);assert(client.focus~=B);assert(K.theme.accent=='#ff2222');A:emit('request::fullscreen',true);assert(A.fullscreen);A.fullscreen=false;B.maximized=true")
            # Wait for a real protocol acknowledgement before replaying current state.
            time.sleep(.35)
            ev('A.fullscreen=true');time.sleep(.25)
            reload(h,env,server,3)
            yes('MAPS==3 and RULES==3')
            ev("for _,c in ipairs(client.all()) do _G[c.app_id]=c end;assert(A.fullscreen and B.maximized);A.fullscreen=false;B.maximized=false")
            settles(log);capture(env,work/'changed.png')
            # Geometry, live hit and membership evidence paired with the capture.
            evidence=h.ev(env,"local n=0;for _,v in ipairs(core.hits(S1.name,S1.x+5,S1.y+45)) do if v.name=='strip' then n=n+1 end end;return handles(),registry_count(),#S1.tags,#S2.tags,core.box('strip').height,n,MAPS,RULES,ADDS,client.focus.handle")
            assert b'\t56\t1\t3\t3\t2\t' in evidence,evidence
            (work/'changed.txt').write_bytes(evidence)
            ev("GLOBAL=0;INSTANCE=0;local _,b=debug.getupvalue(K.on,1);b:emit('probe');S1:emit('probe');assert(GLOBAL==1 and INSTANCE==1)")
            assert all(p.poll() is None for p in children)
            baseline=len(list(Path(f'/proc/{server.pid}/fd').iterdir()))
            paint_before=re.findall(r'live buffers (\d+), live bytes (\d+)',log.read_text())[-1]
            ev("OLD=nil;jit.off();jit.flush();collectgarbage('collect');function refs() local n=0;for k in pairs(debug.getregistry()) do if type(k)=='number' then n=n+1 end end;return n end;REFS=refs();MEM=collectgarbage('count')")
            # Alternate failed and successful cycles, then compare settled resources.
            for n in range(4,12):
                (work/'rc.lua').write_text('this is not lua')
                ev('K.reload()');yes('registry_count()==3')
                time.sleep(.04)
                (work/'rc.lua').write_text(changed)
                reload(h,env,server,n)
                yes('MAPS==3 and RULES==3 and #client.all()==3')
                settles(log)
                ev("collectgarbage('collect')")
            assert re.findall(r'live buffers (\d+), live bytes (\d+)',log.read_text())[-1]==paint_before
            ev('assert(refs()==REFS,refs().." refs vs "..REFS);assert(collectgarbage("count")<MEM+80,collectgarbage("count").." KB vs "..MEM);assert(handles()==IDS)')
            assert len(list(Path(f'/proc/{server.pid}/fd').iterdir()))==baseline
            # Closure races real replay: queued maps cannot resurrect the exiting client.
            ev("for _,c in ipairs(client.all()) do if c.app_id=='C' then C=c end end;K.reload();C:close()")
            yes('#client.all()==2 and registry_count()==2')
            settles(log);before=solves(log);time.sleep(.4);assert solves(log)==before
            ev("core.dirty()");settles(log)
            for name in ('HEADLESS-1','HEADLESS-2'):
                lines=[x for x in log.read_text().splitlines() if x.startswith('Paint '+name+':')]
                assert 'mutations 0, rasters 0' in lines[-1],lines[-1]
            ev("collectgarbage('collect')")
            (work/'resources.json').write_text(json.dumps(dict(fd_baseline=baseline,pids=[p.pid for p in children],compositor=server.pid,memory=h.ev(env,'return MEM,collectgarbage("count"),REFS,refs()').decode().strip(),solves=solves(log))))
            h.quit(server,env,log)
        finally:
            for p in children:stop(p)
            for f in files:f.close()
    print('PASS: reload three real clients/two outputs, rules/default restoration, identities, stale objects, current state, GC and idle',flush=True)


def recovery(h):
    with h.boot(DEFAULT+TRACK) as (server,env,work,log):
        def ev(s):call(h,env,s)
        def yes(s):wait(h,env,'return '+s,b'true\n',server)
        p,f=launch(env,work,'A')
        try:
            yes('#client.all()==1');settles(log)
            # Last successful pixels and hits survive, but retired handlers are inert.
            ev("UI=0;HOVER=0;local input=require('kiln.ui_input');core.set_frame_handler(function() K.ui.box{id='action',w=300,h=90,color='#22aa66',on_press=function() UI=UI+1 end,on_hover=function() HOVER=HOVER+1 end} end);core.dirty()")
            settles(log);before=capture(env,work/'action.png')
            ev("require('kiln.ui_input')({name='motion',screen=screen.all()[1].name,x=10,y=10});assert(HOVER==1)")
            broken=DEFAULT+TRACK+"\ncore.set_frame_handler(function() K.ui.box{id='partial',w=500,h=300,color='#ff0000',on_press=function() UI=UI+100 end};error('declaration failed') end)\n"
            (work/'rc.lua').write_text(broken);reload(h,env,server,2);time.sleep(.2)
            assert capture(env,work/'failed-declaration.png')==before
            ev("local hits=core.hits(screen.all()[1].name,10,10);assert(hits[1].name=='action');local i=require('kiln.ui_input');local sn=screen.all()[1].name;i({name='button',pressed=true,screen=sn,x=10,y=10});i({name='motion',screen=sn,x=600,y=200});assert(UI==0 and HOVER==1);assert(next(require('kiln.state').screen_presses)==nil and next(require('kiln.state').offsets)==nil and next(require('kiln.state').workareas)==nil and next(require('kiln.state').client_boxes)==nil)")
            for text in ('syntax !',None,"K=require('kiln');PARTIAL=0;PARTIAL_RUNS=0;PW=K.spawn.watch('true',.01,{done=function() PARTIAL_RUNS=PARTIAL_RUNS+1 end});K.key{key='F9',press=function() end};K.on('error',function() error('sink failure') end);core.timer(10,function() PARTIAL=PARTIAL+1 end);error('runtime partial')"):
                if text is None:(work/'rc.lua').unlink()
                else:(work/'rc.lua').write_text(text)
                ev('K.reload()');time.sleep(.15);h.healthy(env)
                if text and 'runtime partial' in text:
                    check(h,env,'return PARTIAL',b'1\n');yes('PARTIAL_RUNS>=5');ev('assert(#K.key.all()==1)')
                old=solves(log);time.sleep(.1);assert solves(log)==old
            (work/'rc.lua').write_text(DEFAULT+TRACK)
            reload(h,env,server,3);ev('assert(PW.dead);SAVED_RUNS=PARTIAL_RUNS');time.sleep(.1);ev('assert(PARTIAL_RUNS==SAVED_RUNS)');yes('#client.all()==1 and core.client.focused()==client.all()[1].handle')
            settles(log);capture(env,work/'repaired.png')
            ev("core.set_frame_handler(function() K.ui.box{id='new-action',w=300,h=90,on_press=function() UI=UI+1 end} end);require('kiln.ui_input')({name='button',pressed=true,screen=screen.all()[1].name,x=10,y=10});assert(UI==0);core.dirty()")
            settles(log)
            ev("require('kiln.ui_input')({name='button',pressed=true,screen=screen.all()[1].name,x=10,y=10});assert(UI==1)")
            # Config-time requests are ignored, including errors after arming work.
            (work/'rc.lua').write_text(DEFAULT+TRACK+"\nassert(not K.reload());PARTIAL_TIMER=core.timer(60000,function() error('obsolete') end)\n")
            reload(h,env,server,4);time.sleep(.2);check(h,env,'return LOADS',b'4\n')
            # Replaced event/UI plumbing is restored from cached library closures.
            ev("core.set_event_handler(function() error('retired event') end);core._ui_hooks(function() error('retired begin') end,function() error('retired publish') end);require('kiln.bus').on_error=function() error('retired error sink') end")
            (work/'rc.lua').write_text(DEFAULT+TRACK);reload(h,env,server,5);yes('MAPS==1')
            settles(log);ev('assert(next(require("kiln.state").screen_presses)~=nil)')
            assert 'runtime partial' in log.read_text() and 'sink failure' in log.read_text()
            h.quit(server,env,log)
        finally:stop(p);f.close()
    # Initial failure happens before kiln is required, and recovery may come from a helper.
    for initial in ('return (',"error('before require')"):
        with h.boot(initial) as (server,env,work,log):
            p,f=launch(env,work,'INITIAL')
            try:
                deadline=time.monotonic()+5
                while 'Mapped toplevel: INITIAL' not in log.read_text():
                    assert time.monotonic()<deadline;time.sleep(.02)
                (work/'helper.lua').write_text("return function() return require('kiln').reload() end")
                path=h.ev(env,'return package.path')
                (work/'rc.lua').write_text(DEFAULT+TRACK)
                call(h,env,"assert(require('helper')())")
                wait(h,env,'return LOADS',b'1\n',server)
                wait(h,env,'return #screen.all()[1].tags',b'2\n',server)
                wait(h,env,'return #client.all()',b'1\n',server)
                assert p.poll() is None
                check(h,env,'return package.path',path)
                h.quit(server,env,log)
            finally:stop(p);f.close()
    print('PASS: failed declarations/pixels/retired UI, syntax/runtime/missing recovery, partial work, initial failure and plumbing',flush=True)


def asynchronous(h):
    with h.boot(DEFAULT+TRACK,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        def ev(s):call(h,env,s)
        def yes(s):wait(h,env,'return '+s,b'true\n',server)
        receipt=work/'child-survived'
        pollfile=work/'pollfile';pollfile.write_text('ignored\n')
        ev('POLL=K.poll{'+json.dumps('cat '+str(pollfile))+',every=.02}')
        check_value='return POLL.value'
        wait(h,env,check_value,b'ignored\n',server)
        ev("OLD_CALLBACKS=0;T=core.timer(60000,function() OLD_CALLBACKS=OLD_CALLBACKS+1 end);K.animation.start(screen.all()[1].name,'old',100,20,0);core.tick(screen.all()[2].name,true);W=K.spawn.watch('sleep .3;echo old',.01,function() OLD_CALLBACKS=OLD_CALLBACKS+1 end);WAIT=K.spawn.watch('true',60,function() OLD_CALLBACKS=OLD_CALLBACKS+1 end)")
        time.sleep(.06)
        ev("P=K.spawn.pipe("+json.dumps('printf partial;sleep .3;printf " chunk\\n";touch '+str(receipt))+",{on_line=function() OLD_CALLBACKS=OLD_CALLBACKS+1 end});K.keygrabber{stopped=function() core.timer(5,function() OLD_CALLBACKS=OLD_CALLBACKS+1 end);K.spawn.watch('sleep .1;echo stopped',.01,function() OLD_CALLBACKS=OLD_CALLBACKS+1 end);assert(not K.reload());error('stopped failed') end};BEFORE=OLD_CALLBACKS")
        reload(h,env,server,2)
        pollfile.write_text('after-reload\n')
        time.sleep(.45);assert receipt.exists()
        check(h,env,check_value,b'ignored\n')
        ev('assert(OLD_CALLBACKS==BEFORE and W.dead and WAIT.dead);assert(K.animation.get("old",-1)==-1);N=core.timer(60000,function() end);assert(N>T);core.timer_cancel(N);Q=K.spawn.pipe("true",{});assert(Q>P)')
        time.sleep(.1);assert not processes(server.pid),processes(server.pid)
        settles(log);baseline=len(list(Path(f'/proc/{server.pid}/fd').iterdir()))
        ev("RUNS=0;NEW=K.spawn.watch('true',.01,{done=function() RUNS=RUNS+1 end})")
        time.sleep(2);early=int(h.ev(env,'return RUNS'));time.sleep(2);late=int(h.ev(env,'return RUNS'))
        assert early>60 and late>early+60,(early,late)
        ev('NEW:stop()');time.sleep(.1)
        assert len(list(Path(f'/proc/{server.pid}/fd').iterdir()))==baseline
        # Requests from timer, line, poll parse, listener and declaration all unwind.
        triggers=["core.timer(1,function() assert(K.reload());AFTER=LOADS end)",
                  "K.spawn.pipe(\"printf 'a\\nb\\n'\",{on_line=function() K.reload();AFTER=LOADS end})",
                  "K.poll{'echo poll',every=60,parse=function() K.reload();AFTER=LOADS;return 'x' end}",
                  "K.on('request-reload',function() K.reload();AFTER=LOADS end);local _,b=debug.getupvalue(K.on,1);b:emit('request-reload')",
                  "core.set_frame_handler(function() K.ui.box{id='obsolete',w=800,h=500,color='#ff0000'};K.reload();AFTER=LOADS end);core.dirty()"]
        for n,src in enumerate(triggers,3):
            ev(src);yes('LOADS=='+str(n));ev('assert(AFTER==LOADS-1)');settles(log)
        # A raw clock on the otherwise idle second output must have been disarmed.
        ev("TICKS=0;K.on('frame::tick',function() TICKS=TICKS+1 end)");time.sleep(.15);check(h,env,'return TICKS',b'0\n')
        (work/'endurance.json').write_text(json.dumps(dict(early=early,late=late,fd_baseline=baseline)))
        ev("K.spawn.pipe('sleep .4',{});K.reload();core.quit()")
        assert server.wait(timeout=2)==0
        assert not Path(env['KILN_SOCK']).exists()
        assert 'Async cleanup: timers 0, pipes 0' in log.read_text()
    print('PASS: reload timers/animation/raw clocks/pipes/watch/poll, callback boundaries, cleanup rearming, child survival and quit',flush=True)


def native(h):
    with private_x11(h.out) as display:
        with h.boot(DEFAULT+TRACK,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            def ev(src):call(h,env,src)
            def yes(src):wait(h,env,'return '+src,b'true\n',server)
            with (work/'wev.log').open('w') as output:
                observer=subprocess.Popen(['stdbuf','-oL','wev'],env=env,stdout=output,stderr=output)
                try:
                    yes('#client.all()==1');settles(log)
                    window=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1]
                    def xdo(*args):
                        subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);time.sleep(.06)
                    def seen():return (work/'wev.log').read_text()
                    def edges(text,code):return re.findall(r'wl_keyboard\] key:.*?key: '+str(code)+r'; state: (\d)',text)
                    def point(x,y):xdo('mousemove','--window',window,x,y)
                    xdo('windowfocus',window);point(300,300)
                    ev('HANDLE=client.all()[1].handle')
                    xdo('key','super+ctrl+r');yes('LOADS==2 and MAPS==1');settles(log)
                    ev('assert(client.all()[1].handle==HANDLE and core.client.focused()==HANDLE)')
                    # Reload requested inside native key routing finishes the old stack.
                    ev("G=K.keygrabber{key=function(e) if e.pressed then K.reload();FINISHED=LOADS end end}")
                    start=len(seen());xdo('keydown','a');yes('LOADS==3');xdo('keyup','a');settles(log)
                    assert not edges(seen()[start:],38),seen()[start:]
                    ev('assert(not G.active and FINISHED==2)')
                    start=len(seen());xdo('key','b');assert edges(seen()[start:],56)==['1','0'],seen()[start:]
                    # Release of a pointer press held by a retired claim stays consumed.
                    ev("G=K.mousegrabber{};core.input.set_cursor('grabbing')")
                    start=len(seen());xdo('mousedown',1);reload(h,env,server,4);xdo('mouseup',1);settles(log)
                    assert 'wl_pointer] button:' not in seen()[start:],seen()[start:]
                    ev('assert(not G.active)')
                    point(300,300);start=len(seen());xdo('click',1)
                    text=seen()[start:];assert 'state: 1' in text and 'state: 0' in text,text
                    # Real modifier move and resize, each reloaded with its button held.
                    for number,button in ((5,1),(6,3)):
                        point(350,300);xdo('keydown','super');xdo('mousedown',button);point(430,360)
                        yes('client.all()[1].floating==true')
                        start=len(seen());reload(h,env,server,number);xdo('mouseup',button);xdo('keyup','super');settles(log)
                        assert 'wl_pointer] button:' not in seen()[start:],seen()[start:]
                        point(300,300);start=len(seen());xdo('click',1);xdo('key','b')
                        text=seen()[start:];assert edges(text,56)==['1','0'] and 'wl_pointer] button:' in text,text
                    # Runtime-failed config loses its binding; private IPC repairs it.
                    (work/'rc.lua').write_text("error('native repair')")
                    ev('K.reload()');time.sleep(.15);h.healthy(env)
                    (work/'rc.lua').write_text(DEFAULT+TRACK)
                    reload(h,env,server,7);settles(log);point(300,300)
                    start=len(seen());xdo('key','b');xdo('click',1)
                    assert edges(seen()[start:],56)==['1','0'] and 'wl_pointer] button:' in seen()[start:]
                    capture(env,work/'native-repaired.png')
                    h.quit(server,env,log)
                finally:stop(observer)
    print('PASS: private Xvfb reload binding, key/pointer grabs, held move/resize release consumption and real client recovery',flush=True)


def paths(h):
    base=h.out/'reload-paths';base.mkdir()
    (base/'lua').symlink_to(ROOT/'lua',target_is_directory=True)
    (base/'helper.lua').write_text('return {value=91}')
    rc=base/'relative.lua'
    config="K=require('kiln');M=require('helper');LOADS=(LOADS or 0)+1"
    rc.write_text(config)
    with h.boot(None,overrides={'KILN_RC':'relative.lua'},cwd=base) as (server,env,work,log):
        path=h.ev(env,'return package.path')
        call(h,env,'OLD=M')
        (base/'helper.lua').write_text('return {value=92}')
        for n in range(2,6):reload(h,env,server,n)
        check(h,env,'return package.path',path)
        call(h,env,'assert(M==OLD and M.value==91)')
        check(h,env,'return core._config_path()',str(rc.resolve()).encode()+b'\n')
        h.quit(server,env,log)
    rc.unlink()
    with h.boot(None,overrides={'KILN_RC':rc},cwd=base) as (server,env,work,log):
        assert 'cannot load' in log.read_text()
        rc.write_text(config)
        call(h,env,"require('kiln').reload()")
        wait(h,env,'return LOADS',b'1\n',server)
        h.quit(server,env,log)
    print('PASS: relative and initially missing explicit paths, stable module lookup and cached module identity',flush=True)


def run(h):
    clients(h);recovery(h);asynchronous(h);native(h);paths(h)

if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    out=Path(tempfile.mkdtemp(prefix='reload-',dir=ROOT/'build/verification'))
    print(out,flush=True)
    run(module.Harness(ROOT/'build/kiln',c_baseline.source(),out))
