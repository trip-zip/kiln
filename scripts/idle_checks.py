"""Real idle protocol peers and private outer-X11 activity receipts."""
import c_baseline
import json
import struct
import subprocess
import time
from protocol_client import Client, u
from policy_checks import private_x11
from declaration_checks import wait, settle

CONFIG='''
K=require('kiln');IDLE_LOG={}
screen.on('added',function(s) tag.new{name='one',screen=s};tag.new{name='two',screen=s};s.tags[1]:view() end)
for _,name in ipairs{'start','stop','inhibit'} do
 K.on('idle::'..name,function(on) IDLE_LOG[#IDLE_LOG+1]=name..(on==nil and '' or ':'..tostring(on)) end)
end
'''

class IdleClient(Client):
    def event(self,obj,op,data):
        kind,meta=self.objects.get(obj,('',None))
        if kind=='idle_notification':
            meta.append('idle' if op==0 else 'resumed')
            self.records.append({'idle_notification':obj,'event':meta[-1]})
        else:super().event(obj,op,data)

    def notification(self,ms):
        manager=self.bind('ext_idle_notifier_v1',1)
        result=[];obj=self.new('idle_notification',result)
        self.send(manager,1,u(obj,ms,self.seat));self.roundtrip()
        return obj,result

    def inhibit(self,surface):
        manager=self.bind('zwp_idle_inhibit_manager_v1',1)
        obj=self.new('inhibitor');self.send(manager,1,u(obj,surface['surface']));self.roundtrip();return obj


def run(h):
    with private_x11(h.out) as display:
        with h.boot(CONFIG,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            c=IdleClient(env)
            def ev(s):return h.ev(env,s)
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            win=subprocess.check_output(['xdotool','search','--name',''],env=env,text=True).splitlines()[-1]
            def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5)
            def starts():return int(ev("local n=0;for _,v in ipairs(IDLE_LOG)do if v=='start' then n=n+1 end end;return n"))
            def last(s):yes('IDLE_LOG[#IDLE_LOG]=='+json.dumps(s))
            try:
                xdo('windowfocus',win);xdo('mousemove','--window',win,200,200)
                n,events=c.notification(250);c.pump(.4);assert events==['idle'],events
                ev('K.set_idle_timeout(250)');time.sleep(.4);last('start')
                before=starts();time.sleep(.4);assert starts()==before
                xdo('mousemove','--window',win,300,300);c.pump(.05);last('stop');assert events[-1]=='resumed',events
                for i in range(7):xdo('mousemove','--window',win,301+i,301+i);time.sleep(.08)
                assert starts()==before
                time.sleep(.35);last('start')
                ev('K.set_idle_timeout(500)');last('stop')
                ev('K.set_idle_timeout(nil)');before=starts();time.sleep(.55);assert starts()==before
                # Every supported native path rearms, including keyboard release and axis.
                for args in [('key','a'),('click',1),('click',5),('mousemove','--window',win,400,400)]:
                    ev('K.set_idle_timeout(200)');time.sleep(.3);last('start');xdo(*args);last('stop')
                ev('K.set_idle_timeout(0)')
                root=c.toplevel('IDLE-PEER');yes('#client.all()==1');settle(log)
                sub=c.subsurface(root);a=c.inhibit(sub);last('inhibit:true');c.pump(.1)
                b=c.inhibit(root);count=int(ev('return #IDLE_LOG'));c.pump(.4)
                assert events[-1]=='resumed',events
                ev('K.set_idle_timeout(200)');time.sleep(.3);last('start');assert events[-1]=='resumed'
                ev('K.set_idle_timeout(nil)');last('stop')
                c.send(a,0);c.roundtrip();assert int(ev('return #IDLE_LOG'))==count+2
                ev('screen.all()[1].tags[2]:view()');settle(log);last('inhibit:false');c.pump(.35);assert events[-1]=='idle'
                ev('screen.all()[1].tags[1]:view()');settle(log);last('inhibit:true');c.pump(.1);assert events[-1]=='resumed'
                ev('core.set_frame_handler(function() end);core.dirty()');settle(log);last('inhibit:false')
                ev('K.reload()');settle(log);last('inhibit:true')
                ev('core.output.set_enabled(screen.all()[1].name,false)');last('inhibit:false')
                ev('core.output.set_enabled(screen.all()[1].name,true)');settle(log);last('inhibit:true')
                c.unmap(root);last('inhibit:false')
                c.destroy_xdg(root);c.roundtrip()
                layer=c.layer('idle-layer',width=200,height=30,anchor=13,zone=30)
                d=c.inhibit(layer);last('inhibit:true');c.unmap(layer);last('inhibit:false');c.destroy(layer)
                # A protocol error must retire an already-live inhibitor too.
                prior=int(ev('return core._lock_state().inhibitors'))
                bad=IdleClient(env)
                try:
                    badroot=bad.toplevel('INVALID-INHIBITOR');bad.inhibit(badroot);last('inhibit:true')
                    manager=bad.bind('zwp_idle_inhibit_manager_v1',1)
                    bad.send(manager,1,u(bad.new('inhibitor'),0xffffffff))
                    try:bad.roundtrip();raise RuntimeError('invalid surface accepted')
                    except AssertionError as error:assert 'protocol error' in str(error)
                finally:bad.close()
                yes('core._lock_state().inhibitors=='+str(prior));last('inhibit:false')
                # Native idle deadlines survive config timer retirement.
                ev('K.set_idle_timeout(250);K.reload()');time.sleep(.4);last('start');ev('K.set_idle_timeout(0)');last('stop')
                (work/'idle-wire.json').write_text(json.dumps(c.records,indent=2)+'\n')
                (work/'idle-events.txt').write_bytes(ev('return table.concat(IDLE_LOG,",")'))
                h.quit(server,env,log)
            finally:c.close()
    print('PASS: idle wire idle/resume, real X11 key/motion/button/axis, independent timer, multi-inhibitor hide/unmap/destroy and reload')

if __name__=='__main__':
    import importlib.util,tempfile
    from pathlib import Path
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-idle-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
