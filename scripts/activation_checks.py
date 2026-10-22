"""Activation wire traffic, focus policy and token-bearing launcher children."""
import c_baseline
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from protocol_client import Client,u

CONFIG = '''
K=require('kiln'); LS=require('kiln.layers'); ui=K.ui
screen.on('added',function(s) tag.new{name='one',screen=s};ui.bar(s,{h=32},function()ui.text('stock bar')end) end)
K.rule{match_any={app={'^activation%-target$','^activation%-child$'}},props={focus=false}}
ACT={}
client.on('request::activate',function(c,e) ACT[#ACT+1]={handle=c.handle,valid=e.valid,app_id=e.app_id} end)
'''


def child():
    c=Client(os.environ)
    try:
        a=c.toplevel('activation-child');token=os.environ.get('XDG_ACTIVATION_TOKEN')
        assert token,'missing child token'
        c.activate(token,a)
        Path(os.environ['KILN_ACTIVATION_EVIDENCE']).write_text(json.dumps({'pid':os.getpid(),'token':token,'records':c.records}))
        while True:c.pump(.2)
    finally:c.close()


def run(h):
    from declaration_checks import check,wait,capture
    from policy_checks import private_x11
    from stock_checks import private_data,entry
    data,system,cache=private_data(h.out/'activation-data')
    command=sys.executable+' '+str(Path(__file__).resolve())+' --child'
    entry(data/'applications/activation.desktop','Activation Child',command)
    with private_x11(h.out) as display:
        with h.boot(CONFIG,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None,
                'XDG_DATA_HOME':data,'XDG_DATA_DIRS':system,'XDG_CACHE_HOME':cache,'XDG_ACTIVATION_TOKEN':None}) as (server,env,work,log):
            a=Client(env);b=Client(env);children=[]
            def ev(s):check(h,env,'do '+s+' end',b'\n')
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            def pump():a.pump(.1);b.pump(.1)
            def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);pump()
            def number():return int(h.ev(env,'return #ACT'))
            def holder():ev('H:focus();T.urgent=false');pump();yes('core.client.focused()==H.handle')
            def point(c):
                x,y=map(float,h.ev(env,"core.hits("+c+".screen.name,0,0);local b=core.box({'core.surface',"+c+".handle});return b.x+30,b.y+40").split())
                xdo('mousemove','--window',win,int(x),int(y))
            try:
                ah=a.toplevel('activation-holder');bt=b.toplevel('activation-target');pump()
                ev("for _,c in ipairs(client.all()) do if c.app_id=='activation-holder' then H=c else T=c end end")
                yes('T.no_focus and core.client.focused()==H.handle')
                win=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1]
                xdo('windowfocus',win);point('H');xdo('click',1)
                serial=[r for r in a.records if r.get('input')=='pointer' and r['op']==3][-1]['words'][0]
                token=a.token(serial,ah,'hint-not-identity');b.activate(token,bt);pump()
                yes("#ACT==1 and ACT[1].valid and ACT[1].app_id=='hint-not-identity' and core.client.focused()==T.handle")
                assert any(r.get('input')=='keyboard' and r['op']==1 and r['words'][1]==bt['surface'] for r in b.records)
                holder();before=number();b.activate(token,bt);pump();yes(f'#ACT=={before} and not T.urgent')
                b.activate(b.token(app_id='unbacked'),bt);pump();yes('T.urgent and not ACT[#ACT].valid and core.client.focused()==H.handle')
                holder()
                for token in [b.token(0,bt),b.token(serial,bt),'unknown-token']:
                    before=number();b.activate(token,bt);pump();yes(f'#ACT=={before} and not T.urgent and core.client.focused()==H.handle')
                # A serial belonging to the holder cannot authorize its unfocused source.
                point('T');ev('T:focus()');pump();before=number()
                b.activate(a.token(serial,ah),bt);pump();yes(f'#ACT=={before}')
                holder();ev('DEFAULT_ACTIVATE=K.defaults.activate;K.defaults.activate=function(c,e)c.urgent=true end')
                point('H');xdo('click',1);serial=[r for r in a.records if r.get('input')=='pointer' and r['op']==3][-1]['words'][0]
                b.activate(a.token(serial,ah),bt);pump();yes('ACT[#ACT].valid and T.urgent and core.client.focused()==H.handle')
                ev('K.defaults.activate=DEFAULT_ACTIVATE');holder()
                layer=a.layer('activation-exclusive',keyboard=1)
                b.activate(a.token(serial),bt);pump();yes('core.client.focused()==LS.all[1].handle')
                a.destroy(layer);pump();holder()
                ev('T.minimized=true');b.activate(a.token(serial),bt);pump();yes('T.minimized and core.client.focused()==H.handle');ev('T.minimized=false')
                # Destroy after request, before queued policy dispatch. A live handle lookup is required.
                dead=b.toplevel('activation-dead');before=number();token=b.token()
                b.batch=[]
                b.send(b.activation,2,__import__('protocol_client').string(token)+u(dead['surface']))
                if 'decoration' in dead:b.send(dead['decoration'],0)
                b.send(dead['role'],0);b.send(dead['xdg'],0);b.send(dead['surface'],0);b.flush_batch();b.roundtrip();pump()
                yes('core.client.focused()~=nil')
                # Expiry uses the real default timeout, not a shortened testing setting.
                expiring=b.token();start=time.monotonic();holder()
                print('Activation: waiting for the real 30-second token expiry',flush=True)
                while time.monotonic()-start<30.5:pump()
                before=number();b.activate(expiring,bt);pump();yes(f'#ACT=={before} and not T.urgent')
                evidence=work/'child.json'
                # Configure only the launched command's evidence path, preserving the parent environment.
                cmd='env KILN_ACTIVATION_EVIDENCE='+str(evidence)+' '+command
                for form in [json.dumps(cmd),'{"env",'+json.dumps('KILN_ACTIVATION_EVIDENCE='+str(evidence))+','+json.dumps(sys.executable)+','+json.dumps(str(Path(__file__).resolve()))+',"--child"}']:
                    holder();ev('K.spawn_with_token('+form+')')
                    end=time.monotonic()+5
                    while not evidence.exists() and time.monotonic()<end:pump()
                    payload=json.loads(evidence.read_text());children.append(payload['pid']);evidence.unlink()
                    yes("client.focus.app_id=='activation-child' and ACT[#ACT].valid")
                    os.kill(children.pop(),15);pump()
                # Exercise the stock prompt's launch action with a real Return key.
                evidence=work/'launcher-child.json'
                entry(data/'applications/activation.desktop','Activation Child','env KILN_ACTIVATION_EVIDENCE='+str(evidence)+' '+command)
                ev('K.launcher.reset();K.launcher.open()');xdo('key','Return')
                end=time.monotonic()+5
                while not evidence.exists() and time.monotonic()<end:pump()
                payload=json.loads(evidence.read_text());children.append(payload['pid'])
                yes("client.focus.app_id=='activation-child' and ACT[#ACT].valid")
                ev("assert(os.getenv('XDG_ACTIVATION_TOKEN')==nil);K.launcher.spawn=function()error('retired launcher')end;K.reload()")
                pump();yes('K.launcher.spawn==core.spawn_with_token and #client.all()==3')
                evidence.unlink();ev('K.launcher.open()');xdo('key','Return')
                end=time.monotonic()+5
                while not evidence.exists() and time.monotonic()<end:pump()
                payload=json.loads(evidence.read_text());children.append(payload['pid']);yes('ACT[#ACT].valid')
                ev("core.spawn_with_token({'/nonexistent/kiln-command'});core.spawn_with_token({});core.spawn_with_token({'true',{}});assert(select('#',core.spawn_with_token('true'))==0)")
                yes("os.getenv('XDG_ACTIVATION_TOKEN')==nil")
                receipt=work/'ordinary-env.txt'
                ordinary="printf '%s' \"${XDG_ACTIVATION_TOKEN-unset}\" > "+str(receipt)
                ev('core.spawn('+json.dumps(ordinary)+')')
                end=time.monotonic()+3
                while not receipt.exists() and time.monotonic()<end:pump()
                assert receipt.read_text()=='unset'
                pending=b.token(app_id='survives-reload');ev('K.reload()');pump()
                ev("for _,v in ipairs(client.all()) do if v.app_id=='activation-target' then T=v end end;T.urgent=false")
                b.activate(pending,bt);pump();yes("T.urgent and not ACT[#ACT].valid and ACT[#ACT].app_id=='survives-reload'")
                capture(env,work/'activation-focus.png')
                (work/'activation-wire.json').write_text(json.dumps({'holder':a.records,'target':b.records},indent=2)+'\n')
                h.quit(server,env,log)
                assert 'child setup or exec failed' in log.read_text()
            finally:
                for pid in children:
                    try:os.kill(pid,15)
                    except ProcessLookupError:pass
                a.close();b.close()
    print('PASS: activation serial validation, urgency/focus, one use, expiry, policy, launcher token consumption and reload')

if __name__=='__main__':
    import sys
    if '--child' in sys.argv:child()
    else:
        import importlib.util,tempfile
        spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
        mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
        out=Path(tempfile.mkdtemp(prefix='kiln-activation-',dir='/tmp'));print(out,flush=True)
        run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
