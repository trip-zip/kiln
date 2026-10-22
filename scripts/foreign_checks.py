"""Independent foreign-toplevel observer/controller and mapped native clients."""
import c_baseline
import json
from pathlib import Path
from declaration_checks import check,wait,capture,settle
from protocol_client import Client,u,string
from layer_checks import CONFIG


def run(h):
    with h.boot(CONFIG,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        a=Client(env);b=Client(env);observer=Client(env);late=None
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        def yes(s):wait(h,env,'return '+s,b'true\n',server)
        def pump():a.pump(.1);b.pump(.1);observer.pump(.15)
        def handles(c=observer):return {o:m for o,(k,m) in c.objects.items() if k=='foreign' and not m.get('closed')}
        def request(op,payload=b''):observer.send(fa,op,payload);observer.roundtrip();pump()
        try:
            manager=observer.bind('zwlr_foreign_toplevel_manager_v1',3)
            aa=a.toplevel('foreign-a');bb=b.toplevel('foreign-b');pump()
            assert len(handles())==2
            fa=next(o for o,m in handles().items() if m['app_id']=='foreign-a');ma=handles()[fa]
            fb=next(o for o,m in handles().items() if m['app_id']=='foreign-b')
            ev("for _,c in ipairs(client.all()) do if c.app_id=='foreign-a' then A=c else B=c end end;s1,s2=unpack(screen.all());A:move_to(s1);B:move_to(s2)")
            pump();assert len(ma['outputs'])==1
            first=next(iter(ma['outputs']))
            ev('A:move_to(s2)');pump();assert len(ma['outputs'])==1 and first not in ma['outputs']
            a.send(aa['role'],2,string('changed title'));a.send(aa['role'],3,string('changed.app'));pump()
            yes("A.title=='changed title' and A.app_id=='changed.app'");assert ma['title']=='changed title' and ma['app_id']=='changed.app'
            before=ma['done'];a.send(aa['role'],2,string('changed title'));a.send(aa['role'],3,string('changed.app'));pump();assert ma['done']==before
            ev("B:focus();FT_ACT=nil;client.on('request::activate',function(c,e)FT_ACT={handle=c.handle,valid=e.valid}end)")
            yes('core.client.focused()==B.handle')
            request(4,u(observer.seat));yes('FT_ACT.handle==A.handle and FT_ACT.valid and core.client.focused()==A.handle and client.focus==A');assert 2 in ma['states']
            for op,prop,state,value in [(0,'maximized',0,True),(1,'maximized',0,False),(2,'minimized',1,True),(3,'minimized',1,False),(8,'fullscreen',3,True),(9,'fullscreen',3,False)]:
                request(op,u(observer.outputs[0]) if op==8 else b'')
                yes(f'A.{prop}=='+str(value).lower());assert (state in ma['states'])==value,(op,ma)
            ev('SAVE=K.defaults.maximize;K.defaults.maximize=function()end');request(0);yes('not A.maximized');assert 0 not in ma['states']
            ev('K.defaults.maximize=SAVE');request(0);yes('A.maximized');assert 0 in ma['states'];request(1)
            # Rectangle/output are hints, not a second placement policy.
            rect=observer.new('surface');observer.send(observer.compositor,0,u(rect))
            old=h.ev(env,'return A.screen.name');request(6,u(rect,10,20,100,60));assert h.ev(env,'return A.screen.name')==old
            late=Client(env);late.bind('zwlr_foreign_toplevel_manager_v1',3);late.pump(.2)
            assert len(handles(late))==2
            late_a=next(m for m in handles(late).values() if m['app_id']=='changed.app');assert late_a['states']==ma['states'] and late_a['title']==ma['title']
            ev('AH=A.handle;BH=B.handle;K.reload()');pump();yes('#client.all()==2')
            assert set(handles())=={fa,fb}
            ev("A=require('kiln.object').lookup(AH);B=require('kiln.object').lookup(BH)")
            for _ in range(4):
                a.unmap(aa);pump();assert fa not in handles()
                aa['suspended']=False;a.send(aa['role'],2,string('changed title'));a.send(aa['role'],3,string('changed.app'));a.send(aa['surface'],6);a.pump(.3);pump();yes('#client.all()==2 and A.mapped')
                fa=next(o for o,m in handles().items() if m['app_id']=='changed.app');ma=handles()[fa];assert ma['outputs']
                ev('K.reload()');pump();ev("A=require('kiln.object').lookup(AH);B=require('kiln.object').lookup(BH)");assert len(handles())==2
            request(5);assert aa.get('closed'),a.records[-20:]
            a.destroy_xdg(aa);pump();assert len(handles())==1
            observer.send(fa,0);observer.roundtrip();pump();yes('#client.all()==1')
            capture(env,work/'foreign-survivor.png')
            (work/'foreign-wire.json').write_text(json.dumps(observer.records,indent=2)+'\n')
            h.quit(server,env,log)
        finally:
            if late:late.close()
            a.close();b.close();observer.close()
    print('PASS: foreign identity/state, requests and rejection, output membership, late binding, reload, remap and close delivery')
    removal(h)

def removal(h):
    import subprocess
    from policy_checks import private_x11
    from layer_native_checks import close_output,window_manager_atoms
    with private_x11(h.out) as display,window_manager_atoms(display):
        with h.boot(CONFIG,overrides={'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            owner=Client(env);observer=Client(env)
            try:
                check(h,env,"for _,s in ipairs(screen.all()) do if s.name=='X11-1' then screen.focused=s end end",b'\n')
                owner.toplevel('removed-output');observer.bind('zwlr_foreign_toplevel_manager_v1',3);observer.pump(.3)
                handle,meta=next((o,m) for o,(k,m) in observer.objects.items() if k=='foreign')
                before=set(meta['outputs']);assert len(before)==1
                windows=subprocess.check_output(['xdotool','search','--name',''],env=env).splitlines();assert len(windows)==3
                close_output(display,int(windows[-2]));owner.pump(.3);observer.pump(.3)
                wait(h,env,"return #screen.all()==1 and client.all()[1].screen.name=='X11-2'",b'true\n',server)
                owner.pump(.2);observer.pump(.2)
                assert not meta.get('closed') and len(meta['outputs'])==1 and not before.intersection(meta['outputs'])
                (work/'foreign-removal-wire.json').write_text(json.dumps(observer.records,indent=2)+'\n')
                h.quit(server,env,log)
            finally:owner.close();observer.close()
    print('PASS: foreign output leave/enter after synthetic X11 backend removal; native handle preserved')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-foreign-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
