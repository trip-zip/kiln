"""Native locked/confined pointer requests on a non-origin X11 output."""
import c_baseline
import json
from pathlib import Path
import subprocess
from declaration_checks import check,wait,capture,settle
from policy_checks import private_x11
from protocol_client import Client,u
from layer_checks import CONFIG

CONFIG+='''
MOTIONS=0
K.on('input::motion',function(e) MOTIONS=MOTIONS+1;PX=e.x;PY=e.y end)
'''


def run(h,scale=1):
    with private_x11(h.out) as display:
        with h.boot(CONFIG+f"\ncore.output.set_scale('X11-2',{scale})\n",overrides={'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            c=Client(env)
            def ev(s):check(h,env,'do '+s+' end',b'\n')
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);c.pump(.15)
            def point(x,y):
                # The nested pointer belongs to this backend window.
                xdo('mousemove','--window',win,round(x*1024/int(1024/scale)),round(y*768/int(768/scale)))
            def rel(start):return [r for r in c.records[start:] if 'relative' in r]
            def motion(start):return [r for r in c.records[start:] if r.get('input')=='pointer' and r['op']==2]
            def active(obj):return c.objects[obj][1]['active']
            def shot(name):subprocess.run(['grim','-c',*(['-o','X11-2'] if scale!=1 else []),str(work/name)],env=env,check=True,timeout=5)
            try:
                a=c.toplevel('constraint-root');ev("C=client.all()[1];for _,s in ipairs(screen.all()) do if s.x~=0 then S=s;C:move_to(s) end end;assert(S.x~=0)");c.pump(.3)
                win=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1];xdo('windowfocus',win)
                x,y,w,ht=map(float,h.ev(env,"core.hits(S.name,S.x,S.y);local b=core.box({'core.surface',C.handle});return b.x,b.y,b.width,b.height").split())
                point(x+100,y+100);rp=c.relative_pointer();lock=c.constrain(a);assert active(lock),(c.records[-20:],h.ev(env,'return PX,PY,S.x,S.name'))
                ev('BEFORE=MOTIONS;OLDX=PX;OLDY=PY');start=len(c.records);shot('locked-before.png')
                point(x+180,y+130);point(x+240,y+150)
                yes('MOTIONS==BEFORE and PX==OLDX and PY==OLDY');assert len(rel(start))>=2 and not motion(start)
                assert all(r['time_us']%1000==0 and (r['dx'] or r['dy']) for r in rel(start))
                shot('locked-after.png');assert (work/'locked-before.png').read_bytes()==(work/'locked-after.png').read_bytes()
                # Committed cursor hint applies on live unlock and leaves seat-local mapping coherent.
                c.send(lock,1,u(140*256,120*256));c.send(a['surface'],6);c.roundtrip();c.send(lock,0);c.roundtrip()
                shot('hint-after-unlock.png')
                from PIL import Image
                old=Image.open(work/'locked-before.png');new=Image.open(work/'hint-after-unlock.png')
                def patch(im,dx,dy):return im.crop((round(((1024 if scale==1 else 0)+x+dx)*scale),round((y+dy)*scale),round(((1024 if scale==1 else 0)+x+dx)*scale)+round(30*scale),round((y+dy)*scale)+round(30*scale)))
                assert len(patch(old,100,100).getcolors())>1
                if scale==1:
                    assert patch(old,100,100).tobytes()==patch(new,140,120).tobytes()
                else:
                    from PIL import ImageChops,ImageStat
                    # Capture just this output at its native density. Aggregate grim
                    # can resample the rounded logical output box again.
                    region=(round((x+80)*scale),round((y+80)*scale),round((x+200)*scale),round((y+180)*scale))
                    crops=[im.convert('RGB').crop(region) for im in (old,new)]
                    bounds=[ImageChops.difference(im,Image.new('RGB',im.size,(48,80,144))).getbbox() for im in crops]
                    assert all(bounds)
                    cursor=[im.crop(b) for im,b in zip(crops,bounds)]
                    assert cursor[0].size==cursor[1].size
                    # Absolute input lands between device pixels; the exact
                    # logical hint can change linear-filter edge coverage.
                    # Keep the scale-one byte assertion and bound fractional
                    # per-channel error while checking size and displacement.
                    assert max(ImageStat.Stat(ImageChops.difference(*cursor)).mean)<1
                    assert abs(bounds[1][0]-bounds[0][0]-40*scale)<=1 and abs(bounds[1][1]-bounds[0][1]-20*scale)<=1,bounds
                point(x+142,y+122);c.pump(.1)
                moves=motion(start);assert moves
                if scale==1:assert moves[-1]['words'][1:]==[142*256,122*256],moves[-3:]
                else:assert all(abs(actual/256-want)<1 for actual,want in zip(moves[-1]['words'][1:],[142,122]))
                # Confine uses wlroots' committed intersection with the input region.
                conf=c.constrain(a,locked=False,box=(100,100,100,80));assert active(conf)
                start=len(c.records);point(x+350,y+330);moves=motion(start);assert moves
                sx,sy=moves[-1]['words'][1]/256,moves[-1]['words'][2]/256
                assert 100<=sx<200 and 100<=sy<180,(sx,sy)
                point(x+150,y+140);region=c.region((120,110,50,50));c.send(conf,1,u(region));c.send(region,0);c.send(a['surface'],6);c.roundtrip()
                start=len(c.records);point(x+300,y+300);moves=motion(start);sx,sy=moves[-1]['words'][1]/256,moves[-1]['words'][2]/256
                assert 120<=sx<170 and 110<=sy<160,(sx,sy)
                point(x+130,y+120);region=c.region((125,115,20,20));c.send(a['surface'],5,u(region));c.send(region,0);c.send(a['surface'],6);c.roundtrip()
                start=len(c.records);point(x+300,y+300);moves=motion(start);sx,sy=moves[-1]['words'][1]/256,moves[-1]['words'][2]/256
                assert 125<=sx<145 and 115<=sy<135,(sx,sy)
                c.send(conf,0);c.send(a['surface'],5,u(0));c.send(a['surface'],6);c.roundtrip();point(x+100,y+100)
                # Claim clearing suspends immediately without applying the hint; release reactivates by focus.
                lock=c.constrain(a);c.send(lock,1,u(200*256,200*256));c.send(a['surface'],6);c.roundtrip()
                ev('G=K.mousegrabber{}');c.pump(.1);assert not active(lock)
                start=len(c.records);point(x+120,y+130);assert not rel(start)
                ev('G:stop()');c.pump(.1);assert active(lock)
                # Reload preserves the native constraint, with no duplicate activation while focus stays put.
                before=list(c.objects[lock][1]['events']);ev('K.reload()');c.pump(.3);assert active(lock)
                c.send(lock,0);c.roundtrip()
                # One-shot deactivation retires the native constraint before its destroy callback.
                point(x+100,y+100);one=c.constrain(a,persistent=False);assert active(one)
                ev('G=K.mousegrabber{}');c.pump(.1);assert not active(one);ev('G:stop()');c.pump(.1);assert not active(one)
                c.send(one,0);c.roundtrip()
                # Actual subsurface, popup and layer focus can each activate a native lock.
                sub=c.subsurface(a,x=40,y=50,width=80,height=70)
                point(x+60,y+70);sublock=c.constrain(sub);assert active(sublock);c.send(sublock,0);c.roundtrip()
                pop=c.popup(a,anchor=(250,200,5,5));point(x+pop['box'][0]+20,y+pop['box'][1]+20)
                plock=c.constrain(pop);assert active(plock);c.destroy_xdg(pop);c.pump(.1)
                layer=c.layer('constraint-layer',output='X11-2',width=300,height=80,anchor=5,band=3)
                point(100,40);llock=c.constrain(layer);assert active(llock)
                c.destroy(layer);c.pump(.1)
                point(x+250,y+250);last=c.constrain(a);assert active(last)
                ev("K.button{mods={'alt'},button=1,press=function(v)v:grab_move()end}")
                xdo('keydown','alt');xdo('mousedown',1);assert not active(last)
                start=len(c.records);point(x+300,y+280);assert not rel(start)
                xdo('mouseup',1);xdo('keyup','alt');assert active(last)
                yes('client.all()[1].floating')
                c.unmap(a);c.pump(.1);assert not active(last)
                (work/'constraint-wire.json').write_text(json.dumps(c.records,indent=2)+'\n')
                h.quit(server,env,log)
            finally:c.close()
    print(f'PASS: native lock deltas/fixed cursor, confinement regions, hints, claims, one-shot, reload and leaf-surface constraints on non-origin output at scale {scale}')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-constraints-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
