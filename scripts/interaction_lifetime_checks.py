"""Reload/repair with observers, tokens, selections, a drag and a constraint alive."""
import c_baseline
import json
from pathlib import Path
import subprocess
from declaration_checks import check,wait,settle
from policy_checks import private_x11
from protocol_client import Client,u,string
from data_checks import CONFIG


def run(h):
    with private_x11(h.out) as display:
        with h.boot(CONFIG,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            a=Client(env);b=Client(env);observer=None;stats=[]
            def ev(s):check(h,env,'do '+s+' end',b'\n')
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            def pump():a.pump(.08);b.pump(.08)
            def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);pump()
            def objects():ev("for _,c in ipairs(client.all()) do if c.app_id=='lifetime-source' then A=c else B=c end end")
            def point(name):
                x,y=map(float,h.ev(env,"core.hits("+name+".screen.name,0,0);local b=core.box({'core.surface',"+name+".handle});return b.x+100,b.y+100").split())
                xdo('mousemove','--window',win,int(x),int(y))
            def serial():return [r for r in a.records if r.get('input')=='pointer' and r['op']==3][-1]['words'][0]
            try:
                aa=a.toplevel('lifetime-source');bb=b.toplevel('lifetime-target');pump();objects()
                a.data_device();a.data_device(True);b.data_device();b.data_device(True)
                win=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1];xdo('windowfocus',win)
                for cycle in range(8):
                    observer=Client(env);observer.bind('zwlr_foreign_toplevel_manager_v1',3);observer.pump(.1)
                    handles={o for o,(k,m) in observer.objects.items() if k=='foreign'};assert len(handles)==2
                    token=a.token(app_id='lifetime-token')
                    point('A');xdo('click',1)
                    sources=[]
                    for primary in [False,True]:
                        source=a.data_source({'text/plain':b'surviving bytes'},primary);sources.append((source,primary));a.selection(source,serial(),primary)
                    lock=a.constrain(aa);assert a.objects[lock][1]['active']
                    xdo('mousedown',1)
                    source=a.data_source({'text/plain':b'in-flight bytes'},actions=1)
                    icon=a.start_drag(source,aa,serial());pump();yes(f'STARTS=={cycle+1} and ENDS=={cycle}')
                    assert not a.objects[lock][1]['active']
                    # Retire config subscriptions while native resources remain live.
                    (work/'rc.lua').write_text("error('interaction repair fixture')\n")
                    ev('K.reload()');pump();yes('#screen.all()[1].tags==0 and #client.all()==0')
                    observer.pump(.1);assert {o for o,(k,m) in observer.objects.items() if k=='foreign' and not m.get('closed')}==handles
                    (work/'rc.lua').write_text(CONFIG);ev('K.reload()');pump();objects()
                    observer.pump(.1);assert {o for o,(k,m) in observer.objects.items() if k=='foreign' and not m.get('closed')}==handles
                    yes(f'STARTS=={cycle+1} and ENDS=={cycle}')
                    point('B');xdo('mouseup',1);yes(f'STARTS=={cycle+1} and ENDS=={cycle+1}')
                    b.activate(token,bb);pump();yes('B.urgent')
                    ev('B:focus()');pump()
                    for selection,primary in sources:
                        _,target=b.data_device(primary);offer=target['selection'];assert offer
                        assert b.receive(offer,'text/plain',a)==b'surviving bytes'
                        a.send(selection,1)
                    a.send(lock,0);a.send(source,1);a.send(icon['surface'],0);a.roundtrip();pump()
                    observer.close();observer=None
                    ev("collectgarbage('collect')");pump();settle(log)
                    refs=int(h.ev(env,"local n=0;for k,v in pairs(debug.getregistry()) do if type(k)=='number' and type(v)=='function' then n=n+1 end end;return n"))
                    stats.append({'cycle':cycle,'fds':len(list(Path(f'/proc/{server.pid}/fd').iterdir())),'callback_refs':refs})
                assert len({s['fds'] for s in stats[1:]})==1,stats
                assert len({s['callback_refs'] for s in stats})==1,stats
                # A buffer-only commit repaints without another desktop solve.
                before=log.read_text().count('Layout ');a.paint(aa,*aa['size']);a.roundtrip();pump();settle(log)
                assert log.read_text().count('Layout ')==before
                # Shut down with a live observer, selections, token, constraint and
                # drag icon. Native teardown must retire these without Lua replay.
                observer=Client(env);observer.bind('zwlr_foreign_toplevel_manager_v1',3);observer.pump(.1)
                a.token(app_id='shutdown-token')
                point('A');xdo('click',1)
                for primary in [False,True]:
                    source=a.data_source({'text/plain':b'shutdown bytes'},primary)
                    a.selection(source,serial(),primary)
                a.constrain(aa)
                xdo('mousedown',1)
                source=a.data_source({'text/plain':b'shutdown drag'},actions=1)
                a.start_drag(source,aa,serial());pump();yes('STARTS==9 and ENDS==8')
                (work/'interaction-lifetime.json').write_text(json.dumps({'samples':stats,'source':a.records,'target':b.records},indent=2)+'\n')
                h.quit(server,env,log)
                assert 'Interaction cleanup: trusted tokens 0, constraints 0, drag false' in log.read_text()
            finally:
                if observer:observer.close()
                a.close();b.close()
    print('PASS: eight reload/repair cycles with observers, tokens, selections, drags and constraints alive; stable FDs/refs and buffer-only repaint')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-interactions-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
