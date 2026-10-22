"""Cursor-shape focus eligibility, theme reload and surface cursors at output density."""
import c_baseline
import json
from pathlib import Path
import subprocess
from PIL import Image
from declaration_checks import check,wait
from policy_checks import private_x11
from protocol_client import Client,u
from layer_checks import CONFIG


def run(h,scale=1):
    with private_x11(h.out) as display:
        with h.boot(CONFIG+f"\ncore.output.set_scale(core.output.list()[1].name,{scale})\n",overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            a=Client(env);b=Client(env)
            def ev(s):check(h,env,'do '+s+' end',b'\n')
            def pump():a.pump(.1);b.pump(.1)
            def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);pump()
            def point(x,y):xdo('mousemove','--window',win,int(x*scale),int(y*scale))
            def shot(name):
                path=work/name;subprocess.run(['grim','-c',str(path)],env=env,check=True,timeout=5);return path.read_bytes()
            def honored():return log.read_text().count('Cursor shape:')
            try:
                aa=a.toplevel('cursor-a');bb=b.toplevel('cursor-b');pump()
                ev("for _,c in ipairs(client.all()) do if c.app_id=='cursor-a' then A=c else B=c end end")
                win=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1];xdo('windowfocus',win)
                x,y=map(float,h.ev(env,"core.hits(A.screen.name,0,0);local b=core.box({'core.surface',A.handle});return b.x+100,b.y+100").split());point(x,y)
                ad=a.shape_device();bd=b.shape_device();a.set_shape(ad,9);text=shot('cursor-text.png');before=honored()
                b.set_shape(bd,8,0);assert honored()==before;assert shot('cursor-unfocused.png')==text
                # wlroots validates enums, but neither source cursor route checks serials.
                a.set_shape(ad,8,0);assert honored()==before+1;cross=shot('cursor-crosshair.png');assert cross!=text
                serial=[r for r in a.records if r.get('input')=='pointer' and r['op']==0][-1]['words'][0]
                a.send(a.pointer,0,u(serial,0,0,0));a.roundtrip();hidden=shot('cursor-hidden.png');assert hidden!=cross
                ev('core.input.set_cursor_theme(nil,24)');assert shot('hidden-theme-reload.png')==hidden
                surface={'color':0xfff04060};surface['surface']=a.new('surface',surface);a.send(a.compositor,0,u(surface['surface']))
                a.send(a.pointer,0,u(serial,surface['surface'],0,0));a.paint(surface,16,16);a.roundtrip();shot('cursor-surface.png')
                assert Image.open(work/'cursor-surface.png').convert('RGB').getpixel((int(x*scale)+4,int(y*scale)+4))==(240,64,96)
                ev('core.input.set_cursor_theme(nil,24)');assert shot('surface-theme-reload.png')==(work/'cursor-surface.png').read_bytes()
                for name in ['se-resize','move']:
                    ev("G=K.mousegrabber{};core.input.set_cursor('"+name+"')");pump();before=honored();held=shot('cursor-'+name+'.png')
                    ev('core.input.set_cursor_theme(nil,24)');assert shot('held-theme-reload.png')==held
                    a.set_shape(ad,9,serial);a.send(a.pointer,0,u(serial,surface['surface'],0,0));a.roundtrip()
                    assert honored()==before and shot('cursor-'+name+'-held.png')==held
                    ev('G:stop()');pump();a.set_shape(ad,9);assert honored()==before+1
                point(5,15);before=honored();a.set_shape(ad,8,serial);assert honored()==before
                point(x,y);a.set_shape(ad,9);a.destroy_xdg(aa);pump();point(5,15)
                before=honored();a.set_shape(ad,8,serial);assert honored()==before
                (work/'cursor-wire.json').write_text(json.dumps(a.records+b.records,indent=2)+'\n')
                # Invalid enums are wlroots protocol errors, isolated from the healthy client.
                bad=Client(env)
                try:
                    d=bad.shape_device()
                    try:bad.set_shape(d,999,0)
                    except AssertionError as error:assert 'Invalid shape' in str(error)
                    else:raise AssertionError('invalid cursor enum accepted')
                finally:bad.close()
                h.healthy(env);h.quit(server,env,log)
            finally:a.close();b.close()
    print(f'PASS: cursor shape focus/leave, documented serial boundary, hidden/surface cursors, theme reload, Lua move/resize claims and enum rejection at scale {scale}')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-cursors-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
