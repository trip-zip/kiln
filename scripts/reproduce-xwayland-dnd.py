#!/usr/bin/env python3
"""Minimal required Xdnd-to-Wayland offer reproducer, on owned displays only."""
import c_baseline
import importlib.util
import json
import tempfile
import time
from pathlib import Path
from declaration_checks import check, wait, capture
from layer_checks import CONFIG
from policy_checks import private_x11
from protocol_client import Client
from xwayland_bridge_checks import SelectionClient
from xwayland_checks import xcommand

spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
out=Path(tempfile.mkdtemp(prefix='kiln-xdnd-required-'));print(out,flush=True)
h=mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out)
with private_x11(out) as outer:
    with h.boot(CONFIG,overrides={'DISPLAY':outer,'WAYLAND_DISPLAY':None,'WLR_BACKENDS':'x11','WAYLAND_DEBUG':'server'}) as (server,env,work,log):
        inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip();x=SelectionClient(inner);n=Client(env)
        try:
            w=x.create(title='X drag source');native=n.toplevel('native-target');_,device=n.data_device()
            wait(h,env,'return #client.all()',b'2\n',server)
            check(h,env,"for _,c in ipairs(client.all())do if c.app_id=='native-target' then N=c else X=c end end;X:focus()",b'\n')
            proxies=[v for v in x.children() if x.get_property(v,'XdndAware')[3]==b'\5\0\0\0']
            assert len(proxies)==1,proxies
            proxy=proxies[0];win=xcommand(env,'xdotool','search','--name','').decode().splitlines()[-1]
            def pump():x.pump(.05);n.pump(.05)
            def xdo(*args):xcommand(env,'xdotool',*args);pump()
            def point(name):
                xy=list(map(float,h.ev(env,"core.hits("+name+".screen.name,0,0);local b=core.box({'core.surface',"+name+".handle});return b.x+60,b.y+60").split()))
                xdo('mousemove','--window',win,*map(int,xy));return tuple(map(int,xy))
            xdo('windowfocus',win);point('X');start=len(x.records);xdo('mousedown',1)
            assert any(r['event']==4 and r['window']==w and not r['synthetic'] for r in x.records[start:])
            x.own(w,'XdndSelection',{'UTF8_STRING':b'required Xdnd payload\n'});pump()
            tx,ty=point('N')
            x.message(proxy,'XdndEnter',[w,5<<24,x.atom('UTF8_STRING')],destination=proxy,mask=0)
            x.message(proxy,'XdndPosition',[w,0,(tx<<16)|ty,0,x.atom('XdndActionCopy')],destination=proxy,mask=0)
            deadline=time.monotonic()+2
            while time.monotonic()<deadline and not device.get('enter'):pump()
            capture(env,work/'required-x-to-native.png');xdo('mouseup',1)
            x.message(proxy,'XdndDrop',[w,0,0],destination=proxy,mask=0);pump()
            result=dict(outer=outer,inner=inner,source=w,proxy=proxy,owner=x.owner('XdndSelection'),version=5,target='UTF8_STRING',action='XdndActionCopy',enter=device.get('enter'),dropped=device.get('dropped',False),x=x.records,native=n.records)
            (work/'result.json').write_text(json.dumps(result,indent=2)+'\n');h.healthy(env);h.quit(server,env,log)
            assert result['enter'],f'REQUIRED X11->Wayland Xdnd offer missing; receipts: {work}/result.json'
        finally:x.close();n.close()
