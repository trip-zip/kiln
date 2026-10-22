"""Strict cross-protocol INCR checks with distinct owners and slow readers."""
import c_baseline
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import tempfile
import time
from declaration_checks import check,wait
from policy_checks import private_x11
from protocol_client import Client
from xwayland_bridge_checks import CONFIG,SelectionClient,verified_dependency
from xwayland_checks import xcommand,server_pids,until


def run(h,known_bug=False):
    with private_x11(h.out) as outer:
        with h.boot(CONFIG,overrides={'DISPLAY':outer,'WAYLAND_DISPLAY':None,'WLR_BACKENDS':'x11'}) as (server,env,work,log):
            inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip()
            x=SelectionClient(inner);xp=SelectionClient(inner);n=Client(env);np=Client(env)
            clients=[x,xp,n,np];receipts=[]
            def pump():
                for c in clients:c.pump(.002)
            def ev(s):check(h,env,'do '+s+' end',b'\n')
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            def xdo(*args):xcommand(env,'xdotool',*args);pump()
            def point(name):
                xy=map(float,h.ev(env,"core.hits("+name+".screen.name,0,0);local b=core.box({'core.surface',"+name+".handle});return b.x+50,b.y+60").split())
                xdo('mousemove','--window',win,*map(int,xy));xdo('click',1)
            def focus(name):ev(name+':focus()');pump()
            def serial(c):return [r for r in c.records if r.get('input')=='pointer' and r['op']==3][-1]['words'][0]
            def receipt(direction,selection,data,**extra):
                receipts.append(dict(direction=direction,selection=selection,bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),**extra))
            def bounded(fn,label):
                end=time.monotonic()+5
                while time.monotonic()<end:
                    pump()
                    if fn():return
                raise AssertionError(label)
            def save():
                (work/'transfers.json').write_text(json.dumps(dict(receipts=receipts,x_incr=x.incr,primary_incr=xp.incr),indent=2)+'\n')
            try:
                w=x.create(instance='bridge');wp=xp.create(map_now=False);a=n.toplevel('transfer-native');ap=np.toplevel('transfer-primary')
                yes('#client.all()==3');ev("for _,c in ipairs(client.all())do if c.instance=='bridge' then X=c elseif c.app_id=='transfer-native' then N=c else P=c end end")
                dependency=verified_dependency(server,inner) if known_bug else None
                win=xcommand(env,'xdotool','search','--name','').decode().splitlines()[-1];xdo('windowfocus',win)
                n.data_device();n.data_device(True);np.data_device(True)
                payloads=[bytes(range(256))*2048,b'primary distinct\0\xff'*32768]
                for primary,source,name,data in [(False,n,'N',payloads[0]),(True,np,'P',payloads[1])]:
                    point(name);s=source.data_source({'application/x-kiln-bytes':data},primary);source.selection(s,serial(source),primary)
                focus('X')
                for primary,data in zip((False,True),payloads):
                    selection='PRIMARY' if primary else 'CLIPBOARD';before=len(x.incr)
                    actual=x.receive(w,selection,'application/x-kiln-bytes',pump,slow=True)
                    assert actual==data and len(x.incr)==before+1 and x.incr[-1]['chunks'][-1]==0
                    receipt('Wayland->X11',selection,actual,slow=True,incr=True,owner='distinct native connections')
                focus('X')
                for owner,window,selection,data in [(x,w,'CLIPBOARD',payloads[0]),(xp,wp,'PRIMARY',payloads[1])]:
                    owner.own(window,selection,{'application/x-kiln-bytes':data})
                bounded(lambda:all(any(r['event']==30 and r['target']==owner.atom('TARGETS') for r in owner.records) for owner in (x,xp)),'distinct X TARGETS')
                focus('N');pump()
                failures=[]
                for primary,data,owner in [(False,payloads[0],x),(True,payloads[1],xp)]:
                    _,target=n.data_device(primary);offer=target.get('selection');assert offer
                    log_start=len(log.read_text());fds_before=len(list(Path(f'/proc/{server.pid}/fd').iterdir()))
                    actual=n.receive(offer,'application/x-kiln-bytes',owner,slow=True)
                    new_errors=[line for line in log.read_text()[log_start:].splitlines() if '[ERROR]' in line]
                    complete=actual==data and owner.incr[-1]['chunks'][-1]==0
                    receipt('X11->Wayland','PRIMARY' if primary else 'CLIPBOARD',actual,slow=True,incr=True,
                            expected_bytes=len(data),expected_sha256=hashlib.sha256(data).hexdigest(),complete=complete,
                            owner='distinct X connections',exact_prefix=actual==data[:len(actual)],errors=new_errors,
                            fds_before=fds_before,fds_after=len(list(Path(f'/proc/{server.pid}/fd').iterdir())))
                    if known_bug:
                        assert 0<len(actual)<len(data) and actual==data[:len(actual)],('review changed INCR outcome',receipts[-1])
                        assert len(new_errors)==1 and re.search(r'\[xwayland/selection/incoming.c:112\] write error to target fd \d+: Resource temporarily unavailable$',new_errors[0]),('unclassified transfer error',new_errors)
                        assert receipts[-1]['fds_before']==receipts[-1]['fds_after'],('transfer FD leak',receipts[-1])
                        assert owner.incr[-1]['chunks'][-1]>0,'unexpected successful terminator'
                    if not complete:failures.append(receipts[-1])
                    h.healthy(env)
                save()
                h.quit(server,env,log)
                if h.implementation=='odin':
                    for line in ('Protocol cleanup: layers 0, popups 0','Interaction cleanup: trusted tokens 0, constraints 0, drag false','Input cleanup: keyboards 0, pointers 0, keyboard claim false, pointer claim false','Paint cleanup: live buffers 0, live bytes 0'):
                        assert line in log.read_text(),line
                until(lambda:not server_pids(inner),'owned X server survived INCR shutdown')
                assert not Path('/tmp/.X11-unix/X'+inner[1:]).exists()
                print('PASS: distinct native owners, clipboard/primary Wayland->X11 INCR, slow requestors, exact large payloads and terminators',flush=True)
                if known_bug:
                    assert len(failures)==2,'review unexpected INCR success'
                    (work/'known-bug.json').write_text(json.dumps(dict(outcome='KNOWN BUG',dependency=dependency,failures=failures,responsive=True,clean_exit=True),indent=2)+'\n')
                    print('KNOWN BUG: verified wlroots incoming INCR loses data under backpressure (EAGAIN); exact prefixes '+str([(r['selection'],r['bytes'],r['expected_bytes']) for r in failures])+'. Cutoff is scheduling/pipe dependent; strict correctness probe remains red.',flush=True)
                else:
                    assert not failures,('required slow X->Wayland INCR truncated',failures,str(work/'transfers.json'))
                    print('PASS: X11->Wayland exact large clipboard/primary INCR transfers',flush=True)
            finally:
                save()
                for c in clients:c.close()


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser()
    parser.add_argument('--binary',type=Path,default=Path(__file__).resolve().parents[1]/'build/kiln')
    parser.add_argument('--original',type=Path,default=c_baseline.source())
    parser.add_argument('--implementation',choices=('odin','c'),default='odin')
    parser.add_argument('--known-bug',action='store_true')
    args=parser.parse_args()
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-xtransfers-'));print(out,flush=True)
    run(mod.Harness(args.binary,args.original,out,implementation=args.implementation),known_bug=args.known_bug)
