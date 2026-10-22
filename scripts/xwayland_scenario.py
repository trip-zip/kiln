"""Shared owned-display driver for X selection, drag and game lifetime checks."""
import c_baseline
import contextlib
import importlib.util
import json
from pathlib import Path
import tempfile
import time
from declaration_checks import check,wait,capture,settle
from policy_checks import private_x11
from protocol_client import Client
from xwayland_bridge_checks import CONFIG,SelectionClient
from xwayland_checks import xcommand,server_pids,until

CONFIG+='''
STARTS=0;ENDS=0;MOTIONS=0
K.on('input::motion',function(e) MOTIONS=MOTIONS+1;PX=e.x;PY=e.y end)
drag.on('start',function() STARTS=STARTS+1 end)
drag.on('end',function() ENDS=ENDS+1 end)
'''

class Scenario:
    def __init__(self,h,server,env,work,log,config):
        self.h,self.server,self.env,self.work,self.log,self.config=h,server,env,work,log,config
        self.inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip()
        self.x=SelectionClient(self.inner);self.n=Client(env);self.clients=[self.x,self.n];self.rows=[]
        self.w=self.x.create(instance='scenario-x');self.a=self.n.toplevel('scenario-native')
        self.wait('#client.all()==2');self.pick()
        self.ev("core.output.set_position(S.name,137,91);core.output.set_position(T.name,1161,91);T.scale=1.5;X:move_to(T);N:move_to(S)")
        self.pump();settle(log)
        self.refresh_windows()
        self.n.data_device();self.n.data_device(True)
    def refresh_windows(self):
        from x11_client import XClient
        outer=XClient(self.env['DISPLAY'])
        try:
            windows=set(map(str,outer.children()))
            names=self.h.ev(self.env,'local r={} for _,s in ipairs(screen.all())do r[#r+1]=s.name end;return table.concat(r," ")').decode().split()
            # Xvfb backend windows have no name properties here. Preserve known
            # identities across stacking changes; pair newly created outputs
            # and XIDs in allocation order, never QueryTree stacking order.
            retained={name:window for name,window in getattr(self,'windows',{}).items() if name in names and window in windows}
            new_names=sorted(set(names)-retained.keys(),key=lambda n:int(n.split('-')[-1]))
            new_windows=sorted(windows-set(retained.values()),key=int)
            assert len(new_names)==len(new_windows),(names,windows,retained)
            self.windows=retained|dict(zip(new_names,new_windows))
            (self.work/'backend-windows.json').write_text(json.dumps(self.windows,indent=2)+'\n')
        finally:outer.close()
    def ev(self,s):check(self.h,self.env,'do '+s+' end',b'\n')
    def val(self,s):return self.h.ev(self.env,'return '+s)
    def wait(self,s):wait(self.h,self.env,'return '+s,b'true\n',self.server)
    def pick(self):
        self.ev("for _,s in ipairs(screen.all())do if s.name=='X11-1' then S=s else T=s end end;for _,c in ipairs(client.all())do if c.instance=='scenario-x' then X=c elseif c.app_id=='scenario-native' then N=c end end")
    def pump(self,seconds=.035):
        for c in self.clients:
            if not getattr(c,'closed',False):c.pump(seconds)
    def until(self,predicate,label):
        end=time.monotonic()+5
        while time.monotonic()<end:
            self.pump(.01)
            if predicate():return
        raise AssertionError(label)
    def xdo(self,*args):xcommand(self.env,'xdotool',*args);self.pump()
    def point(self,name,dx=50,dy=60):
        vals=self.val("core.hits and (function() core.hits("+name+".screen.name,0,0);local b=core.box({'core.surface',"+name+".handle});return table.concat({"+name+".screen.name,b.x+"+str(dx)+",b.y+"+str(dy)+","+name+".screen.width,"+name+".screen.height},' ') end)()").decode().split()
        output=vals[0];x,y,width,height=map(float,vals[1:]);win=self.windows[output]
        self.xdo('windowraise',win);self.xdo('windowfocus',win)
        self.xdo('mousemove','--window',win,round(x*1024/width),round(y*768/height))
    def click(self,name):self.point(name);self.xdo('click',1)
    def serial(self,c=None):
        c=c or self.n
        return [r for r in c.records if r.get('input')=='pointer' and r['op']==3][-1]['words'][0]
    def focus(self,name):self.ev(name+':focus()');self.pump()
    def reload(self,broken=False):
        (self.work/'rc.lua').write_text("error('lifetime broken reload')" if broken else self.config)
        self.ev('K.reload()');self.pump()
        if not broken:self.pick()
        self.h.healthy(self.env)
    def shot(self,label):capture(self.env,self.work/(label+'.png'))
    def fds(self):return len(list(Path(f'/proc/{self.server.pid}/fd').iterdir()))
    def save(self,name='scenario.json'):
        (self.work/name).write_text(json.dumps(dict(rows=self.rows,x=self.x.records,native=self.n.records),indent=2)+'\n')
    def quit(self):
        self.h.healthy(self.env);self.h.quit(self.server,self.env,self.log)
        until(lambda:not server_pids(self.inner),'owned X server survived shutdown')
        if self.h.implementation=='odin':
            for line in ('Protocol cleanup: layers 0, popups 0','Interaction cleanup: trusted tokens 0, constraints 0, drag false','Input cleanup: keyboards 0, pointers 0, keyboard claim false, pointer claim false','Paint cleanup: live buffers 0, live bytes 0'):
                assert line in self.log.read_text(),line

@contextlib.contextmanager
def scenario(h,fixture=False,debug=False):
    if fixture:
        from output_fixture import harness,LUA
        fh=harness(h);fh.count=h.count;config=CONFIG+LUA
    else:fh=h;config=CONFIG
    try:
        with private_x11(h.out) as outer:
            with fh.boot(config,overrides={'DISPLAY':outer,'WAYLAND_DISPLAY':None,'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2','WAYLAND_DEBUG':'server' if debug else None,'DBUS_SESSION_BUS_ADDRESS':'unix:path=/nonexistent-kiln-test-bus'}) as (server,env,work,log):
                s=Scenario(fh,server,env,work,log,config)
                try:yield s
                finally:
                    s.save()
                    (work/'process-exit.json').write_text(json.dumps(dict(pid=server.pid,returncode=server.poll()))+'\n')
                    for c in s.clients:c.close()
    finally:h.count=fh.count

def main(run,label,known_bug=False):
    import argparse
    parser=argparse.ArgumentParser()
    parser.add_argument('--binary',type=Path,default=Path(__file__).resolve().parents[1]/'build/kiln')
    parser.add_argument('--original',type=Path,default=c_baseline.source())
    parser.add_argument('--implementation',choices=('odin','c'),default='odin')
    if known_bug:parser.add_argument('--known-bug',action='store_true')
    args=parser.parse_args()
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-'+label+'-'));print(out,flush=True)
    run(mod.Harness(args.binary,args.original,out,implementation=args.implementation),**({'known_bug':args.known_bug} if known_bug else {}))
