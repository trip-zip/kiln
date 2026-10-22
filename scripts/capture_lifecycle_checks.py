"""Bounded CLI/capture/reload/output cycles; including the public inspector."""
import c_baseline
import json
from pathlib import Path
import subprocess
import tempfile
import time
from PIL import Image,ImageChops
from output_fixture import harness,LUA
from protocol_client import Client
from declaration_checks import wait,settle
from screenshot_checks import CONFIG,ROOT
from policy_checks import private_x11


def run(h):
    base=h.out/'capture-lifecycle';base.mkdir()
    suite=harness(type(h)(h.binary,h.original,base))
    with private_x11(base) as display:
        with suite.boot(CONFIG+LUA,overrides={'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2','DISPLAY':display,'WAYLAND_DISPLAY':None,'KILN_IMAGE_BUDGET_MB':'8'}) as (server,env,work,log):
            def ev(s):return suite.ev(env,s).decode().strip()
            def yes(s):wait(suite,env,'return '+s,b'true\n',server)
            def cli(*args):
                p=subprocess.run([str(ROOT/'build/kiln-client'),'-s',env['KILN_SOCK'],*args],capture_output=True,timeout=5)
                assert p.returncode==0 and not p.stderr,p
                return p.stdout
            client=Client(env);pending=None;samples=[];transforms=[]
            try:
                client.toplevel('capture-lifetime');yes('#client.all()==1');client.pump(.15)
                ev('core.output.set_position("X11-2",-301,77);core.output.set_scale("X11-2",1.3)');settle(log)
                # PNGs keep physical buffer dimensions, matching the original API.
                # Independent screencopy applies the advertised output transform.
                for transform in range(8):
                    ev(f'assert(output_fixture(0,"X11-1",{transform}))');settle(log)
                    api=work/f'transform-{transform}.png';ind=work/f'screencopy-{transform}.png'
                    key=ev(f'return core.screenshot("X11-1",{json.dumps(str(api))})');assert key.startswith('screenshot:')
                    subprocess.run(['grim','-o','X11-1',str(ind)],env=env,check=True,timeout=5)
                    a=Image.open(api).convert('RGB');b=Image.open(ind).convert('RGB')
                    variants=[('identity',a)]+[(method.name,a.transpose(method)) for method in Image.Transpose]
                    matches=[name for name,image in variants if image.size==b.size and ImageChops.difference(image,b).getbbox() is None]
                    assert matches==[['identity'],['ROTATE_270'],['ROTATE_180'],['ROTATE_90'],['FLIP_LEFT_RIGHT'],['TRANSPOSE'],['FLIP_TOP_BOTTOM'],['TRANSVERSE']][transform],(transform,matches)
                    transforms.append(dict(transform=transform,api=a.size,screencopy=b.size,matches=matches))
                    ev('core.image_reload('+json.dumps(key)+')')
                ev('assert(output_fixture(0,"X11-1",0))');settle(log)
                for stage in range(1,5):
                    before=len(list(Path(f'/proc/{server.pid}/fd').iterdir()))
                    ev(f'assert(output_fixture(8,"",{stage}))')
                    assert ev('return core.screenshot("X11-1") or "nil"')=='nil'
                    assert ev('return resource_fixture(22)')=='0'
                    assert len(list(Path(f'/proc/{server.pid}/fd').iterdir()))==before
                ev('assert(output_fixture(8,"",0))')
                other_name="X11-2"
                windows=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()
                window=windows[-2]
                def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5)
                xdo('windowraise',window);xdo('windowfocus',window)
                for cycle in range(5):
                    assert cli('ping')==b'pong\n'
                    assert cli('inspector','X11-1')==b'on\n'
                    assert cli('inspector',other_name)==b'on\n'
                    settle(log)
                    xdo('mousemove','--window',window,850,75,'mousedown',1,'mouseup',1)
                    xdo('click',5);time.sleep(.1);settle(log)
                    pending=suite.connect(env,b'-- pending capture lifecycle',eof=False)
                    keys=[]
                    for name in ['X11-1',other_name]:
                        path=work/f'cycle-{cycle}-{name}.png'
                        key=ev(f'return core.screenshot({json.dumps(name)},{json.dumps(str(path))})');keys.append(key)
                        assert key.startswith('screenshot:')
                    ev('SHOT='+json.dumps(keys[0])+';core.dirty()');settle(log)
                    ev('SHOT=nil;core.dirty()');settle(log)
                    for key in keys:ev('core.image_reload('+json.dumps(key)+')')
                    (work/'rc.lua').write_text('error("capture repair")')
                    cli('reload');time.sleep(.05)
                    (work/'rc.lua').write_text(CONFIG+LUA);cli('reload');yes('#client.all()==1');settle(log)
                    ev('assert(output_fixture(1,'+json.dumps(other_name)+'))');yes('#core.output.list()==1')
                    assert ev('return core.screenshot('+json.dumps(other_name)+') or "nil"')=='nil'
                    ev('assert(output_fixture(3,"ignored"))');yes('#core.output.list()==2')
                    other_name=ev('for _,o in ipairs(core.output.list())do if o.name~="X11-1" then return o.name end end')
                    ev('core.output.set_position('+json.dumps(other_name)+',-301,77);core.output.set_scale('+json.dumps(other_name)+',1.3)');settle(log)
                    assert ev('return core.inspector('+json.dumps(other_name)+')')=='false'
                    assert cli('inspector','X11-1')==b'off\n'
                    xdo('mousemove','--window',window,300,300)
                    pending.close();pending=None
                    ev('collectgarbage("collect")');client.pump(.15);settle(log)
                    refs=int(ev("local n=0;for k,v in pairs(debug.getregistry())do if type(k)=='number' and type(v)=='function' then n=n+1 end end;return n"))
                    counts={str(k):int(ev(f'return resource_fixture({k})')) for k in [3,9,10,11,17,18,20,21,22,23,24,25,26]}
                    assert counts['3']==0 and counts['9']==0 and counts['22']==0 and counts['23']==0 and counts['24']==0 and counts['26']==4,counts
                    samples.append(dict(cycle=cycle,fds=len(list(Path(f'/proc/{server.pid}/fd').iterdir())),refs=refs,resources=counts))
                    before=log.read_text().count('Layout ');time.sleep(.2);assert log.read_text().count('Layout ')==before
                assert len({s['fds'] for s in samples})==1,samples
                assert len({s['refs'] for s in samples})==1,samples
                assert all(s['resources']==samples[0]['resources'] for s in samples),samples
                # Output return while locked is covered before any later desktop solve.
                ev('assert(core.lock());assert(output_fixture(1,'+json.dumps(other_name)+'));assert(output_fixture(3,"ignored"))')
                yes('#core.output.list()==2');path=work/'locked-return.png'
                other_name=ev('for _,o in ipairs(core.output.list())do if o.name~="X11-1" then return o.name end end')
                key=ev(f'return core.screenshot({json.dumps(other_name)},{json.dumps(str(path))})');assert key.startswith('screenshot:')
                assert not ({(255,32,16),(16,239,48),(18,52,86)} & set(Image.open(path).convert('RGB').get_flattened_data()))
                pending=suite.connect(env,b'-- shutdown pending',eof=False)
                suite.quit(server,env,log)
                assert pending.recv(1)==b''
                assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
            finally:
                if pending:pending.close()
                client.close()
                (work/'capture-lifecycle.json').write_text(json.dumps(dict(samples=samples,transforms=transforms,inspector='public default palette; native clicks/wheel, reload and output ownership included'),indent=2)+'\n')
    print('PASS: five private-Xvfb CLI/inspector/input/capture/cache-retirement/reload/output cycles, eight transforms, lock output return, idle/FD/ref/resource stability and pending IPC shutdown:',base)

if __name__=='__main__':
    import importlib.util
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-capture-life-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(ROOT/'build/kiln',c_baseline.source(),out))
