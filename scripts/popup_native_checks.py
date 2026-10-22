"""Protocol popup grabs and actual leaf input on a private Xvfb display."""
import c_baseline
import json
import subprocess
from declaration_checks import check,wait,settle,capture
from policy_checks import private_x11
from window_state_checks import launch,stop
from protocol_client import Client
from layer_checks import CONFIG


def run(h):
    with private_x11(h.out) as display:
        with h.boot(CONFIG,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            c=Client(env);p,f=launch(env,work,'POPUP-NEIGHBOR')
            def ev(src):check(h,env,'do '+src+' end',b'\n')
            def yes(src):wait(h,env,'return '+src,b'true\n',server)
            def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);c.pump(.12)
            def point(x,y):xdo('mousemove','--window',win,int(x),int(y))
            def box():return list(map(float,h.ev(env,"core.hits(A.screen.name,0,0);local b=core.box({'core.surface',A.handle});return b.x,b.y,b.width,b.height").split()))
            def buttons(start):return [r for r in c.records[start:] if r.get('input')=='pointer' and r['op']==3]
            def keys(start):return [r for r in c.records[start:] if r.get('input')=='keyboard' and r['op']==3]
            try:
                yes('#client.all()==1');a=c.toplevel('native-popup-root');c.pump(.2)
                yes('#client.all()==2')
                ev("for _,v in ipairs(client.all()) do if v.app_id=='native-popup-root' then A=v else F=v end end;A:lower();A:focus()")
                c.pump(.2);settle(log)
                win=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1]
                xdo('windowfocus',win)
                x,y,w,ht=box();point(x+30,y+50);start=len(c.records);xdo('mousedown',1)
                serial=buttons(start)[-1]['words'][0]
                pop=c.popup(a,anchor=(int(w)-30,70,5,5),grab=serial)
                xdo('mouseup',1)
                point(x+pop['box'][0]+20,y+pop['box'][1]+20);start=len(c.records);xdo('click',1)
                assert len(buttons(start))==2
                enters=[r for r in c.records if r.get('input')=='pointer' and r['op']==0]
                assert enters[-1]['words'][1]==pop['surface'],enters[-1]
                start=len(c.records);xdo('key','F6');assert len(keys(start))==2
                start=len(c.records);xdo('mousedown',1);serial=buttons(start)[-1]['words'][0]
                nested=c.popup(pop,anchor=(100,30,4,4),size=(100,70),grab=serial,color=0xff20b0b0);xdo('mouseup',1)
                point(x+pop['box'][0]+nested['box'][0]+15,y+pop['box'][1]+nested['box'][1]+15)
                start=len(c.records);xdo('click',1);assert len(buttons(start))==2
                enters=[r for r in c.records if r.get('input')=='pointer' and r['op']==0]
                assert enters[-1]['words'][1]==nested['surface']
                # Lua keyboard/pointer claims supersede dispatch while wlroots owns its grab.
                ev('G=K.keygrabber{};M=K.mousegrabber{}');start=len(c.records)
                xdo('keydown','F7');xdo('mousedown',1);ev('G:stop();M:stop()');xdo('keyup','F7');xdo('mouseup',1)
                assert not keys(start) and not buttons(start)
                start=len(c.records);xdo('key','F8');assert len(keys(start))==2
                capture(env,work/'native-nested-popup.png')
                ev('AH=A.handle;K.reload()');c.pump(.3);yes('#client.all()==2')
                ev("A=require('kiln.object').lookup(AH);A:focus()")
                c.pump(.2)
                # Outside click on another Wayland client dismisses both grabs.
                bx,by=map(float,h.ev(env,"for _,v in ipairs(client.all()) do if v~=A then F=v end end;core.hits(F.screen.name,0,0);local b=core.box({'core.surface',F.handle});return b.x+b.width-20,b.y+b.height-20").split())
                point(bx,by);xdo('click',1)
                assert pop.get('done') and nested.get('done'),c.records[-12:]
                c.destroy_xdg(nested);c.destroy_xdg(pop)
                yes('core.client.focused()==F.handle')
                before=(work/'POPUP-NEIGHBOR.log').read_text();xdo('key','F9')
                assert '.key(' in (work/'POPUP-NEIGHBOR.log').read_text()[len(before):]
                # Actual backend resize refreshes layer facts and sizing without an output API.
                layer=c.layer('resize-layer',height=40,zone=40)
                yes('#LS.all==1 and LS.all[1].buffer_mapped')
                old=layer['size'][0];xdo('windowsize',win,860,600);c.pump(.3);settle(log)
                yes('LS.all[1].w==860 and LS.all[1].screen.width==860')
                assert layer['size'][0]==860 and old!=860
                lp=c.popup(layer,anchor=(840,30,5,5));c.pump(.2)
                ev('L=LS.all[1]')
                lx,ly=map(float,h.ev(env,"core.hits(L.screen.name,0,0);local b=core.box({'layer',L.handle});return b.x,b.y").split())
                point(lx+lp['box'][0]+10,ly+lp['box'][1]+10);start=len(c.records);xdo('click',1)
                assert len(buttons(start))==2
                enters=[r for r in c.records if r.get('input')=='pointer' and r['op']==0]
                assert enters[-1]['words'][1]==lp['surface']
                capture(env,work/'resized-layer-popup.png')
                # Quit with every protocol family alive exercises native listener teardown.
                (work/'native-wire.json').write_text(json.dumps(c.records,indent=2)+'\n')
                h.quit(server,env,log)
            finally:c.close();stop(p);f.close()
    print('PASS: native nested popup grabs, actual leaf input, Lua claims, held releases, reload, dismissal and resized layer popup')

if __name__=='__main__':
    import importlib.util,tempfile
    from pathlib import Path
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-popup-input-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
