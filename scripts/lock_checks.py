"""External lock wire clients with independent desktop and locker receipts."""
import c_baseline
import json
import struct
import subprocess
import time
from PIL import Image
from protocol_client import Client,u
from policy_checks import private_x11
from declaration_checks import wait,capture
from idle_checks import CONFIG

class Locker(Client):
    def __init__(self,env):
        super().__init__(env)
        self.manager=self.bind('ext_session_lock_manager_v1',1)
        self.lock_events=[];self.lock=self.new('session_lock',self.lock_events)
        self.send(self.manager,1,u(self.lock));self.roundtrip()

    def event(self,obj,op,data):
        kind,meta=self.objects.get(obj,('',None))
        if kind=='session_lock':
            meta.append('locked' if op==0 else 'finished');self.records.append({'lock':obj,'event':meta[-1]})
        elif kind=='lock_surface':
            serial,w,h=struct.unpack('=III',data)
            self.records.append({'lock_surface':obj,'configure':serial,'width':w,'height':h})
            self.send(obj,1,u(serial));self.paint(meta,w,h)
            self.records.append({'lock_surface':obj,'ack':serial})
        else:super().event(obj,op,data)

    def cover(self,output):
        meta={'color':0xff203040}
        meta['surface']=self.new('surface',meta);self.send(self.compositor,0,u(meta['surface']))
        meta['role']=self.new('lock_surface',meta)
        self.send(self.lock,1,u(meta['role'],meta['surface'],output));self.roundtrip();return meta

    def unlock(self):self.send(self.lock,2);self.roundtrip()


def keys(c):return [r for r in c.records if r.get('input')=='keyboard' and r['op']==3]

def run(h):
    with private_x11(h.out) as display:
        cfg=CONFIG+'''\nSESSIONS={};KEYS=0;K.on('session::lock',function(e) SESSIONS[#SESSIONS+1]=e.kind end)
K.on('input::key',function() KEYS=KEYS+1 end)\n'''
        with h.boot(cfg,overrides={'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            desktop=Client(env);locker=None
            def ev(s):return h.ev(env,s)
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            try:
                root=desktop.toplevel('LOCK-DESKTOP');yes('#client.all()==1')
                win=subprocess.check_output(['xdotool','search','--name',''],env=env,text=True).splitlines()[-1]
                def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5)
                xdo('windowfocus',win);ev('client.all()[1]:focus()');xdo('key','a');desktop.pump(.1);assert keys(desktop)
                before=len(keys(desktop));lua_before=int(ev('return KEYS'))
                ev('core.output.set_position(screen.all()[1].name,-301,77);screen.all()[1].scale=1.3')
                locker=Locker(env);locker.pump(.3);assert locker.lock_events==['locked'],locker.records
                yes('SESSIONS[#SESSIONS]=="ext"');assert ev('return core.unlock(),core.lock()')==b'false\tfalse\n'
                capture(env,work/'floor.png');assert Image.open(work/'floor.png').convert('RGB').getbbox() is None
                surfaces=[locker.cover(o) for o in locker.outputs];assert len(surfaces)==2
                locker.pump(.15);capture(env,work/'external.png')
                second=Locker(env);assert second.lock_events==['finished'];second.close()
                ev('core.client.focus(client.all()[1].handle);core.input.grab_keyboard(true);core.input.grab_pointer(true)')
                xdo('key','b','super+shift+q');xdo('click',1);xdo('click',5)
                desktop.pump(.1);locker.pump(.1)
                assert len(keys(desktop))==before and int(ev('return KEYS'))==lua_before
                assert keys(locker),locker.records
                locker.unlock();yes('core.unlock()')
                (work/'normal-wire.json').write_text(json.dumps(locker.records,indent=2)+'\n')
                locker.close();locker=None
                ev('core.client.focus(client.all()[1].handle)');xdo('key','c');desktop.pump(.1);assert len(keys(desktop))>before
                ev('core.set_lock_handler(function() end)')
                locker=Locker(env);locker.pump(.2);locker.cover(locker.outputs[0]);locker.close();locker=None
                yes('SESSIONS[#SESSIONS]=="native"');assert ev('return core.unlock()')==b'false\n'
                capture(env,work/'crashed-floor.png');assert Image.open(work/'crashed-floor.png').convert('RGB').getbbox() is None
                xdo('key','d');desktop.pump(.1)
                (work/'desktop-wire.json').write_text(json.dumps(desktop.records,indent=2)+'\n')
                h.quit(server,env,log)
            finally:
                if locker:locker.close()
                desktop.close()
    with h.boot('assert(core.lock())') as (server,env,work,log):
        assert h.ev(env,'return core.unlock()')==b'false\n'
        capture(env,work/'no-handler-floor.png')
        assert Image.open(work/'no-handler-floor.png').convert('RGB').getbbox() is None
        h.quit(server,env,log)
    print('PASS: external lock presentation ack, two configured outputs, native keyboard quarantine, rejection, unlock and crash floor')

if __name__=='__main__':
    import importlib.util,tempfile
    from pathlib import Path
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-lock-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
