"""Output verb contract, physical discovery and logical screen geometry."""
import c_baseline
import json
from pathlib import Path
import subprocess
import time
from declaration_checks import check,wait,settle
from layer_checks import CONFIG as DESKTOP
from policy_checks import private_x11

CAPTURE='''
OUTPUT_EVENTS={}
local set=core.set_event_handler
core.set_event_handler=function(fn) set(function(e)
 if e.class=='output' then OUTPUT_EVENTS[#OUTPUT_EVENTS+1]={name=e.name,output=e.output,fields=(function()local n=0;for _ in pairs(e)do n=n+1 end;return n end)()} end
 fn(e)
end) end
'''
CONFIG=CAPTURE+DESKTOP

def run(h):
    with h.boot(CONFIG,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        def yes(s):wait(h,env,'return '+s,b'true\n',server)
        ev("s1,s2=unpack(screen.all());function out(n)for _,o in ipairs(core.output.list())do if o.name==n then return o end end end")
        yes('#core.output.list()==2 and s1.scale==1 and s2.scale==1')
        check(h,env,"local o=out(s1.name);return type(o.modes),type(o.scale),type(o.x),type(o.y),type(o.enabled)",b'table\tnumber\tnumber\tnumber\tboolean\n')
        # Pin both positions before counting changes, so auto placement is not involved.
        ev('core.output.set_position(s1.name,0,0);core.output.set_position(s2.name,1400,0)')
        settle(log)
        def change(s):
            ev('OUTPUT_EVENTS={};'+s)
            yes('#OUTPUT_EVENTS==1')
            time.sleep(.1)
            check(h,env,"return #OUTPUT_EVENTS,OUTPUT_EVENTS[1].name,OUTPUT_EVENTS[1].output==s1.name,OUTPUT_EVENTS[1].fields",b'1\tchange\ttrue\t3\n')
        change("assert(select('#',core.output.set_scale(s1.name,1.5))==0)")
        yes('out(s1.name).scale==1.5 and s1.scale==1.5 and s1.width==853 and s1.height==480 and out(s1.name).width==1280')
        change('s1.scale=2')
        yes('s1.width==640 and s1.height==360 and s2.scale==1 and s2.width==1280')
        change("assert(select('#',core.output.set_mode(s1.name,1280,720))==0)")
        yes('out(s1.name).width==1280 and out(s1.name).height==720')
        change('core.output.set_mode(s1.name,1020,660,59940)')
        yes('out(s1.name).refresh==59940 and out(s1.name).width==1020 and s1.width==510 and s1.height==330')
        change('core.output.set_position(s1.name,100,50)')
        yes('out(s1.name).x==100 and out(s1.name).y==50 and s1.x==100 and s1.y==50')
        change('core.output.set_position(s1.name,-301,-77)')
        yes('s1.x==-301 and s1.y==-77')
        change('core.output.set_scale(s1.name,2)')
        ev('OUTPUT_EVENTS={};'+";".join("assert(select('#',core.output."+v+"('ABSENT',"+a+"))==0)" for v,a in [('set_mode','800,600'),('set_scale','1.5'),('set_position','-10,5'),('set_enabled','false'),('set_adaptive_sync','true')]))
        time.sleep(.1);yes('#OUTPUT_EVENTS==0')
        for verb,args in [('set_mode','0,720'),('set_mode','1/0,720'),('set_mode','800,600,-1'),('set_mode','800,600,1.5'),('set_mode','32769,10'),('set_scale','0'),('set_scale','-1'),('set_scale','0/0'),('set_scale','1/0'),('set_scale','1e100'),('set_position','1/0,0'),('set_position','1.5,2'),('set_enabled','1'),('set_adaptive_sync','nil')]:
            reply=h.ev(env,f'core.output.{verb}(s1.name,{args})');assert reply.startswith(b'ERROR:'),(verb,args,reply)
            h.healthy(env)
        yes('#OUTPUT_EVENTS==0 and s1.scale==2 and out(s1.name).width==1020')
        ev("assert(select('#',core.output.set_adaptive_sync(s1.name,true))==0)")
        time.sleep(.1);yes('#OUTPUT_EVENTS==0')
        assert 'rejected requested state' in log.read_text()
        change('core.output.set_scale(s1.name,1)')
        ev('OLD=s1;require("kiln").reload()');yes('screen.all()[1]==OLD and OLD.scale==1')
        settle(log);before=log.read_text().count('Layout ');time.sleep(.25);assert before==log.read_text().count('Layout ')
        (work/'output-readback.txt').write_bytes(h.ev(env,'return out(s1.name).width,out(s1.name).height,out(s1.name).refresh,s1.width,s1.height,s1.scale,s1.x,s1.y'))
        # The removed development environment override stays absent in the implementation.
        assert all('KILN_SCALE' not in p.read_text() for p in Path(__file__).resolve().parents[1].rglob('*.odin'))
        assert not any(x in log.read_text() for x in ["error in '",'tree==scene:'])
        h.quit(server,env,log)
    print('PASS: output battery assertions; five write-only verbs, mHz, physical/logical sizes, event counts, unknown/invalid requests, backend VRR rejection and reload')
    resize(h)

def resize(h):
    with private_x11(h.out) as display:
        with h.boot(CONFIG,overrides={'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            check(h,env,"core.output.set_position('X11-1',-80,40);core.output.set_position('X11-2',1400,0)",b'\n')
            settle(log)
            check(h,env,'OUTPUT_EVENTS={}',b'\n')
            windows=subprocess.check_output(['xdotool','search','--name',''],env=env).splitlines();assert len(windows)==3
            subprocess.run(['xdotool','windowsize',windows[-2].decode(),'900','630'],env=env,check=True)
            wait(h,env,"local o=core.output.list()[2];return o.width==900 and o.height==630 and screen.all()[1].width==900",b'true\n',server)
            wait(h,env,"return #OUTPUT_EVENTS==1 and OUTPUT_EVENTS[1].output=='X11-1'",b'true\n',server)
            # X11 fixes its status to enabled and only sets a window hint;
            # matching wlroots rejects disabling that hint's nominal state.
            for enabled,accepted,count in [('false','false',0),('true','true',1)]:
                check(h,env,f"OUTPUT_EVENTS={{}};core.output.set_adaptive_sync('X11-1',{enabled})",b'\n')
                assert f'Adaptive sync X11-1: requested {enabled} accepted {accepted} enabled true' in log.read_text()
                wait(h,env,'return #OUTPUT_EVENTS',str(count).encode()+b'\n',server)
                h.healthy(env)
            h.quit(server,env,log)
    print('PASS: X11 resize publishes one event/live geometry; fixed enabled VRR hint rejects disable and accepts enable without hardware claims')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-output-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
