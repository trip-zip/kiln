"""Mixed-density nested input, transformed coordinates and cursor raster evidence."""
import c_baseline
import json,re,subprocess
from pathlib import Path
from declaration_checks import check,wait,settle
from policy_checks import private_x11
from protocol_client import Client
from layer_checks import CONFIG
from output_fixture import harness,LUA
import cursor_checks
import constraint_checks


def run(h):
    cursor_checks.run(h,1.5)
    cursor_checks.run(h,2)
    constraint_checks.run(h,1.5)
    # Raster metadata is the theme's actual bitmap, independent of screenshot scale.
    rows=[]
    for log in h.out.glob('run-*/server.log'):
        rows+=re.findall(r'Cursor raster X11-1: se-resize scale ([\d.]+) device (\d+)x(\d+)',log.read_text())
    dimensions={float(s):int(w) for s,w,hh in rows}
    assert dimensions[1.5]>dimensions[1] and dimensions[2]>=dimensions[1.5],dimensions
    print('Cursor device widths:',dimensions,flush=True)
    fh=harness(h);fh.count=h.count
    try:mixed(fh)
    finally:h.count=fh.count

def mixed(h):
    with private_x11(h.out) as display:
        with h.boot(CONFIG+LUA+"\nK.on('input::motion',function(e)PX=e.x;PY=e.y;PS=e.screen end)\n",overrides={'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            c=Client(env,fractional=True)
            def ev(s):check(h,env,'do '+s+' end',b'\n')
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);c.pump(.12)
            try:
                ev("for _,s in ipairs(screen.all())do if s.name=='X11-1' then S=s else T=s end end;S.scale=1.5;T.scale=2;core.output.set_position(S.name,-301,47);core.output.set_position(T.name,900,-73);screen.focused=S")
                a=c.toplevel('mapped-input');ev('C=client.all()[1];C.floating=true;C.float={x=40,y=60,width=240,height=220}');c.pump(.2);settle(log)
                windows=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines();assert len(windows)==3
                evidence=[]
                for target,index in [('S',-2),('T',-1)]:
                    ev(f'C:move_to({target});C.float={{x=40,y=60,width=240,height=220}}');c.pump(.25);settle(log)
                    for transform in ([0,1,4,0] if target=='S' else [0]):
                        ev(f'assert(output_fixture(0,{target}.name,{transform}))');c.pump(.25);settle(log)
                        x,y,w,hh,ox,oy,lw,lh=map(float,h.ev(env,f"core.hits({target}.name,{target}.x,{target}.y);local b=core.box({{'core.surface',C.handle}});return b.x,b.y,b.width,b.height,{target}.x,{target}.y,{target}.width,{target}.height").split())
                        # Choose an exact normalized backend point and independently derive its logical result.
                        px,py=220,220
                        nx,ny=px/1024,py/768
                        if transform==1:nx,ny=1-ny,nx
                        elif transform==4:nx=1-nx
                        # Relocate the floating client to contain that point, preserving a known surface offset.
                        lx,ly=nx*lw,ny*lh
                        ev(f'C.float={{x={int(lx)-50},y={int(ly)-70},width=240,height=220}}');c.pump(.2);settle(log)
                        x,y=map(float,h.ev(env,f"core.hits({target}.name,{target}.x,{target}.y);local b=core.box({{'core.surface',C.handle}});return b.x,b.y").split())
                        win=windows[index];xdo('windowraise',win);xdo('windowfocus',win);start=len(c.records)
                        xdo('mousemove','--window',win,px,py);xdo('click',1)
                        yes(f"PS=={target}.name and math.abs(PX-({ox+lx}))<1 and math.abs(PY-({oy+ly}))<1")
                        motions=[r for r in c.records[start:] if r.get('input')=='pointer' and r['op'] in (0,2)]
                        assert motions,c.records[-20:]
                        event=motions[-1];coords=event['words'][-2:]
                        assert abs(coords[0]/256-(lx-x))<1 and abs(coords[1]/256-(ly-y))<1,(transform,coords,lx-x,ly-y)
                        assert any(r.get('input')=='pointer' and r['op']==3 for r in c.records[start:])
                        evidence.append({'output':target,'transform':transform,'global':[ox+lx,oy+ly],'client':[v/256 for v in coords]})
                        subprocess.run(['grim','-c','-o','X11-1' if target=='S' else 'X11-2',str(work/f'input-{target}-{transform}.png')],env=env,check=True,timeout=5)
                    # Published UI hit and actual button motion resize on both
                    # mixed-density outputs, with a matching native configure.
                    ev(f'C.float={{x=40,y=60,width=240,height=220}}');c.pump(.2);settle(log)
                    ox,oy,lw,lh=map(float,h.ev(env,f'return {target}.x,{target}.y,{target}.width,{target}.height').split())
                    ev(f"local found=false;for _,hit in ipairs(core.hits({target}.name,{ox+277},{oy+277}))do if hit.name=='resize_se' then found=true end end;assert(found)")
                    def point(lx,ly):xdo('mousemove','--window',windows[index],round(lx*1024/lw),round(ly*768/lh))
                    start=len(c.records);point(277,277);xdo('mousedown',1);point(307,297);xdo('mouseup',1);c.pump(.2);settle(log)
                    yes('math.abs(C.float.width-270)<=1 and math.abs(C.float.height-240)<=1')
                    width,height=map(int,h.ev(env,f"core.hits({target}.name,{ox},{oy});local b=core.box({{'core.surface',C.handle}});return b.width,b.height").split())
                    assert a['size']==(width,height),a
                    assert not any(r.get('input')=='pointer' and r['op']==3 for r in c.records[start:])
                    popup=c.popup(a,anchor=(230,100,5,5));c.pump(.2)
                    x,y=map(float,h.ev(env,f"core.hits({target}.name,{ox},{oy});local b=core.box({{'core.surface',C.handle}});return b.x,b.y").split())
                    px,py,pw,ph=popup['box'];assert px+pw-15>width
                    start=len(c.records);point(x+px+pw-15,y+py+20);xdo('click',1)
                    enters=[r for r in c.records[start:] if r.get('input')=='pointer' and r['op']==0]
                    assert enters and enters[-1]['words'][1]==popup['surface'],c.records[start:]
                    assert any(r.get('input')=='pointer' and r['op']==3 for r in c.records[start:])
                    subprocess.run(['grim','-c','-o','X11-1' if target=='S' else 'X11-2',str(work/f'popup-overhang-{target}.png')],env=env,check=True,timeout=5)
                    c.destroy_xdg(popup)
                (work/'mixed-input.json').write_text(json.dumps({'points':evidence,'wire':c.records},indent=2)+'\n')
                h.quit(server,env,log)
            finally:c.close()
    print('PASS: mixed-scale X11 device/output association, negative origins, native client clicks/UI resize handles/popup overhang, 90-degree and flipped backend states through private fixture')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-output-input-',dir='/tmp'));print(out,flush=True)
    h=mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out)
    cursor_checks.run(h)
    run(h)
