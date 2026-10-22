"""Real clipboard/primary FD transfer and pointer drag negotiation."""
import c_baseline
import json
import os
from pathlib import Path
import subprocess
from declaration_checks import check,wait,capture
from policy_checks import private_x11
from protocol_client import Client,u,string
from layer_checks import CONFIG

CONFIG+='''
STARTS=STARTS or 0;ENDS=ENDS or 0;GEN=(GEN or 0)+1
local generation=GEN
 drag.on('start',function()assert(generation==GEN);STARTS=STARTS+1 end)
 drag.on('end',function()assert(generation==GEN);ENDS=ENDS+1 end)
'''


def run(h):
    with private_x11(h.out) as display:
        with h.boot(CONFIG,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            a=Client(env);b=Client(env)
            def ev(s):check(h,env,'do '+s+' end',b'\n')
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            def pump():a.pump(.1);b.pump(.1)
            def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);pump()
            def point(c):
                x,y=map(float,h.ev(env,"core.hits("+c+".screen.name,0,0);local b=core.box({'core.surface',"+c+".handle});return b.x+80,b.y+80").split())
                xdo('mousemove','--window',win,int(x),int(y));return x,y
            def serial(c):return [r for r in c.records if r.get('input')=='pointer' and r['op']==3][-1]['words'][0]
            try:
                aa=a.toplevel('data-source');bb=b.toplevel('data-target');pump()
                ev("for _,c in ipairs(client.all()) do if c.app_id=='data-source' then A=c else B=c end end")
                win=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1]
                xdo('windowfocus',win)
                for primary in [False,True]:
                    a.data_device(primary);device,target=b.data_device(primary)
                    sources=[]
                    for payload in [b'clipboard\x00bytes\n',b'replacement \xe2\x98\x83']:
                        point('A');xdo('click',1)
                        source=a.data_source({'text/plain;charset=utf-8':payload,'application/x-fixture':b'alternate'},primary)
                        a.selection(source,serial(a),primary);pump()
                        if sources:assert a.objects[sources[-1]][1].get('cancelled')
                        sources.append(source)
                        ev('B:focus()');pump();offer=target['selection']
                        assert set(b.objects[offer][1]['mimes'])=={'text/plain;charset=utf-8','application/x-fixture'}
                        assert b.receive(offer,'text/plain;charset=utf-8',a)==payload
                        assert b.receive(offer,'application/x-fixture',a)==b'alternate'
                    point('A');xdo('click',1);a.selection(0,serial(a),primary);ev('B:focus()');pump();assert target['selection']==0
                # Actual button serials, with target-controlled copy/move negotiation.
                for mode in ['icon','iconless','icon-first','reload','reject','source-first','target-first']:
                    point('A');xdo('mousedown',1);before=int(h.ev(env,'return STARTS'))
                    source=a.data_source({'text/plain':b'drag payload\x00\n'},actions=3)
                    icon=a.start_drag(source,aa,serial(a),icon=mode!='iconless');pump();yes(f'STARTS=={before+1} and ENDS=={before}')
                    if mode=='icon-first':a.send(icon['surface'],0);a.roundtrip();pump();icon=None
                    if mode=='reload':
                        ev('AH=A.handle;BH=B.handle;K.reload()');pump()
                        ev("A=require('kiln.object').lookup(AH);B=require('kiln.object').lookup(BH)")
                        yes(f'STARTS=={before+1} and ENDS=={before}')
                    x,y=point('B');pump();device,target=b.data_device();enter=target.get('enter');assert enter and enter[1]==bb['surface'],target
                    offer=enter[-1]
                    if mode=='reject':
                        b.send(offer,0,u(enter[0])+u(0));b.send(offer,4,u(0,0));b.roundtrip()
                    else:
                        b.send(offer,0,u(enter[0])+string('text/plain'));b.send(offer,4,u(3,2));b.roundtrip();pump()
                        assert a.objects[source][1]['action']==2
                        assert b.receive(offer,'text/plain',a)==b'drag payload\x00\n'
                    if mode=='icon':
                        capture(env,work/'drag-icon-over-target.png')
                        from PIL import Image
                        assert Image.open(work/'drag-icon-over-target.png').convert('RGB').getpixel((int(x)+15,int(y)+15))==(255,128,32)
                    if mode=='source-first':a.send(source,1);a.roundtrip();pump()
                    if mode=='target-first':b.destroy_xdg(bb);pump()
                    xdo('mouseup',1);yes(f'STARTS=={before+1} and ENDS=={before+1}')
                    if mode not in ['reject','source-first','target-first']:
                        assert target.get('dropped');target.pop('dropped',None)
                        b.send(offer,3);b.roundtrip();pump();assert a.objects[source][1].get('finished')
                    if mode=='target-first':
                        bb=b.toplevel('data-target');pump();ev("for _,c in ipairs(client.all()) do if c.app_id=='data-target' then B=c end end")
                    if icon:a.send(icon['surface'],0);a.roundtrip()
                # Invalid serial and a live serial on the wrong origin never begin a drag.
                for wrong in [False,True]:
                    point('A');xdo('mousedown',1)
                    source=a.data_source({'text/plain':b'invalid'},actions=1);before=int(h.ev(env,'return STARTS'))
                    origin=aa
                    if wrong:
                        origin={'surface':a.new('surface')};a.send(a.compositor,0,u(origin['surface']))
                    a.start_drag(source,origin,serial(a) if wrong else 0,icon=False);pump()
                    assert a.objects[source][1].get('cancelled');yes(f'STARTS=={before} and ENDS=={before}')
                    xdo('mouseup',1)
                    if wrong:a.send(origin['surface'],0)
                # Disconnect clears both selection owners and leaves the recipient usable.
                for primary in [False,True]:
                    point('A');xdo('click',1);source=a.data_source({'text/plain':b'disconnect'},primary);a.selection(source,serial(a),primary)
                ev('B:focus()');pump()
                a.close();a=Client(env);b.pump(.2)
                for _,target in b.devices.values():assert target.get('selection')==0
                (work/'data-wire.json').write_text(json.dumps(b.records,indent=2)+'\n')
                h.quit(server,env,log)
            finally:a.close();b.close()
    print('PASS: clipboard/primary MIME and FD bytes; pointer DnD action, icon, rejection, destruction orders and reload')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-data-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
