"""Private backend removal/recreation with native desktop objects still alive."""
import c_baseline
import json,subprocess,time
from pathlib import Path
from declaration_checks import check,wait,settle
from protocol_client import Client
from data_checks import CONFIG
from output_fixture import harness,LUA
from policy_checks import private_x11


def run(h):
    fh=harness(h);fh.count=h.count
    try:
        headless(fh)
        nested(fh)
    finally:h.count=fh.count

def headless(h):
    with h.boot(CONFIG+LUA,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        c=Client(env,fractional=True);observer=Client(env);samples=[]
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        def yes(s):wait(h,env,'return '+s,b'true\n',server)
        def pump():c.pump(.15);observer.pump(.15)
        try:
            a=c.toplevel('hotplug-root');p=c.popup(a,anchor=(1100,600,5,5));observer.bind('zwlr_foreign_toplevel_manager_v1',3);pump()
            ev("C=client.all()[1];C:move_to(screen.all()[1]);NAME=C.screen.name")
            for cycle in range(6):
                ev("OLD=C.screen;K.animation.start(OLD.name,'remove',1,10,0)")
                name=h.ev(env,'return NAME').decode().strip()
                layer=c.layer('explicit-'+str(cycle),output=name);pump()
                oldglobals=set(n for n,v in observer.globals['wl_output'])
                ev("assert(output_fixture(1,NAME))");pump();yes('#screen.all()==1 and C.screen~=OLD and OLD._data.dead and #LS.all==0');assert layer.get('closed')
                ev("assert(output_fixture(2,NAME,900,660));OLD.scale=8");pump();yes('#screen.all()==2')
                ev("for _,s in ipairs(screen.all())do if s.name==NAME then NEW=s end end;assert(NEW~=OLD and NEW.scale==1);C:move_to(NEW);NEW.scale=1.5")
                pump();settle(log);assert a['scale120']==180 and len(observer.globals['wl_output'])==2
                newglobals=set(n for n,v in observer.globals['wl_output']);assert len(newglobals-oldglobals)==1
                # Lose the last output with mapped clients and a popup still alive.
                ev("OLD2=NEW;for _,s in ipairs(screen.all())do assert(output_fixture(1,s.name))end");pump();yes('#screen.all()==0 and #core.output.list()==0')
                cpu=lambda:sum(map(int,Path(f'/proc/{server.pid}/stat').read_text().split()[13:15]))
                before=cpu();time.sleep(.2);assert cpu()-before<=2
                h.healthy(env)
                ev("assert(output_fixture(2,NAME,1280,720));assert(output_fixture(2,'RETURNED',1280,720))");pump();yes('#screen.all()==2 and #client.all()==1 and client.all()[1]==C')
                # Broken and repaired config preserve native handles across the new output lifetime.
                (work/'rc.lua').write_text("error('output repair fixture')\n")
                ev('K.reload()');pump()
                handles=[m for _,(k,m) in observer.objects.items() if k=='foreign' and not m.get('closed')];assert len(handles)==1
                (work/'rc.lua').write_text(CONFIG+LUA);ev('K.reload()');pump();yes('#client.all()==1')
                ev("C=client.all()[1];for _,s in ipairs(screen.all())do if s.name==NAME then C:move_to(s)end end;collectgarbage('collect')");pump();settle(log)
                refs=int(h.ev(env,"local n=0;for k,v in pairs(debug.getregistry())do if type(k)=='number' and type(v)=='function'then n=n+1 end end;return n"))
                samples.append({'cycle':cycle,'fds':len(list(Path(f'/proc/{server.pid}/fd').iterdir())),'refs':refs})
                assert len(observer.globals['wl_output'])==2
            assert len({s['fds'] for s in samples[1:]})==1,samples
            assert len({s['refs'] for s in samples})==1,samples
            subprocess.run(['grim',str(work/'returned-desktop.png')],env=env,check=True,timeout=5)
            (work/'hotplug-lifetime.json').write_text(json.dumps({'samples':samples,'client':c.records,'observer':observer.records},indent=2)+'\n')
            h.quit(server,env,log)
            assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
        finally:c.close();observer.close()
    print('PASS: six headless removal/name-reuse/last-output-return cycles, live client/popup/layer/observer, animations, reload repair, distinct globals, stable FDs/refs and idle settling')

def nested(h):
    with private_x11(h.out) as display:
        with h.boot(CONFIG+LUA,overrides={'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            c=Client(env)
            def ev(s):check(h,env,'do '+s+' end',b'\n')
            def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);c.pump(.1)
            try:
                a=c.toplevel('grab-hotplug');ev("C=client.all()[1];for _,s in ipairs(screen.all())do if s.name=='X11-2' then C:move_to(s)end end;K.button{mods={'alt'},button=1,press=function(v)v:grab_move()end}");c.pump(.2)
                win=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1];xdo('windowfocus',win)
                x,y=map(float,h.ev(env,"core.hits(C.screen.name,C.screen.x,C.screen.y);local b=core.box({'core.surface',C.handle});return b.x+100,b.y+100").split())
                xdo('mousemove','--window',win,int(x),int(y));lock=c.constrain(a);assert c.objects[lock][1]['active']
                xdo('keydown','alt');xdo('mousedown',1);assert not c.objects[lock][1]['active']
                ev("assert(output_fixture(1,'X11-2'))");c.pump(.2)
                xdo('mouseup',1);xdo('keyup','alt')
                wait(h,env,"return #screen.all()==1 and C.screen.name=='X11-1'",b'true\n',server)
                ev("assert(output_fixture(3,'X11-2'))");c.pump(.3)
                wait(h,env,'return #screen.all()==2',b'true\n',server)
                ev("for _,s in ipairs(screen.all())do if s.name~='X11-1' then C:move_to(s);NAME=s.name end end;MOTIONS=0;K.on('input::motion',function() MOTIONS=MOTIONS+1 end)")
                c.pump(.2)
                win=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1];xdo('windowfocus',win)
                x,y=map(float,h.ev(env,"core.hits(C.screen.name,C.screen.x,C.screen.y);local b=core.box({'core.surface',C.handle});return b.x+100,b.y+100").split())
                xdo('mousemove','--window',win,int(x),int(y));c.send(lock,0);c.roundtrip()
                xdo('mousedown',1)
                serial=[r for r in c.records if r.get('input')=='pointer' and r['op']==3][-1]['words'][0]
                source=c.data_source({'text/plain':b'output removal drag'},actions=1)
                icon=c.start_drag(source,a,serial);c.pump(.1)
                wait(h,env,'return STARTS==1 and ENDS==0',b'true\n',server)
                subprocess.run(['grim','-c',str(work/'drag-before-removal.png')],env=env,check=True,timeout=5)
                ev("BEFORE=MOTIONS;assert(output_fixture(4,NAME))");c.pump(.2)
                wait(h,env,"return #screen.all()==1 and MOTIONS==BEFORE and C.screen.name=='X11-1'",b'true\n',server)
                win=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1];xdo('windowfocus',win)
                xdo('mousemove','--window',win,200,200);xdo('mouseup',1)
                wait(h,env,'return ENDS==1',b'true\n',server)
                c.send(source,1);c.send(icon['surface'],0);c.roundtrip()
                # With no native session, the VT chord cannot seize the host VT, even with broken Lua.
                ev("core.set_event_handler(function() error('broken input policy') end)")
                xdo('key','ctrl+alt+F2');h.healthy(env)
                (work/'grab-removal-wire.json').write_text(json.dumps(c.records,indent=2)+'\n')
                h.quit(server,env,log)
                assert 'pointers 0' in log.read_text()
            finally:c.close()
    print('PASS: X11 output/device removal during a real modifier grab with persistent constraint, recreation, drag-icon removal with queued raw input discarded, teardown and broken-Lua no-session VT path')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-hotplug-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
