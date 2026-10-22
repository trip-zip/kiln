"""Owned composed-frame capture, cache use, failed save and lock coverage."""
import c_baseline
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import time
from PIL import Image,ImageChops
from declaration_checks import settle,wait,capture
from protocol_client import Client
from lock_checks import Locker

ROOT=Path(__file__).resolve().parents[1]
CONFIG='''K=require('kiln');ui=K.ui
screen.on('added',function(s) tag.new{name='one',screen=s} end)
core.set_frame_handler(function(name,w,h)
 ui.box({id='capture-root',w='grow',h='grow',color='#123456',dir='column'},function()
  ui.box{w=100,h=80,color='#ff2010'}
  ui.box{w=60,h=40,color='#10ef30'}
  if SHOT then ui.image(SHOT,{w=320,h=180}) end
  for _,c in ipairs(client.all()) do if c.screen.name==name then ui.surface(c,{w=200,h=150}) end end
 end)
end)
'''

def run(h,client=None):
    receipts=[];client=client or ROOT/'build/kiln-client'
    with h.boot(CONFIG,overrides={'WLR_HEADLESS_OUTPUTS':'2','KILN_IMAGE_BUDGET_MB':'8'}) as (server,env,work,log):
        def ev(code):return h.ev(env,code).decode().strip()
        def shot(label,name='HEADLESS-1',prefix=''):
            path=work/(label+'.png')
            key=ev(prefix+f'return core.screenshot({json.dumps(name)},{json.dumps(str(path))})')
            assert key.startswith('screenshot:'),key
            im=Image.open(path).convert('RGBA')
            receipts.append(dict(label=label,key=key,size=im.size))
            return key,im,path
        settle(log)
        key,im,path=shot('controlled')
        assert im.size==(1280,720),im.size
        assert im.getpixel((10,10))==(255,32,16,255),im.getpixel((10,10))
        assert im.getpixel((10,100))==(16,239,48,255)
        assert im.getpixel((1100,600))==(18,52,86,255)
        subprocess.run(['grim','-o','HEADLESS-1',str(work/'independent.png')],env=env,check=True,timeout=5)
        independent=Image.open(work/'independent.png').convert('RGBA')
        assert ImageChops.difference(im.convert("RGB"),independent.convert("RGB")).getbbox() is None
        ev(f'SHOT={json.dumps(key)};core.dirty()');settle(log)
        _,rendered,_=shot('key-rendered')
        assert rendered.getpixel((5,125))==(255,32,16,255),rendered.getpixel((5,125))
        ev('SHOT=nil;core.dirty()');settle(log)
        bad=work/'missing'/'capture.png'
        failed=ev(f'return core.screenshot("HEADLESS-1",{json.dumps(str(bad))})')
        assert failed.startswith('screenshot:') and not bad.exists()
        p=subprocess.run([str(client),'-s',env['KILN_SOCK'],'screenshot',str(bad),'HEADLESS-1'],capture_output=True,timeout=5)
        assert p.returncode==0 and p.stdout==str(bad).encode()+b'\n' and not p.stderr and not bad.exists(),p
        assert 'PNG write failed' in log.read_text()
        assert ev('return core.screenshot("missing") or "nil"')=='nil'
        ev('core.output.set_enabled("HEADLESS-2",false)');settle(log)
        assert ev('return core.screenshot("HEADLESS-2") or "nil"')=='nil'
        ev('core.output.set_enabled("HEADLESS-2",true);core.output.set_position("HEADLESS-2",-401,99);core.output.set_scale("HEADLESS-2",1.3)');settle(log)
        _,fractional,_=shot('fractional','HEADLESS-2')
        assert fractional.size==(1280,720) and fractional.getpixel((10,10))==(255,32,16,255)
        peer=Client(env)
        try:
            peer.toplevel('capture-client');peer.pump(.2)
            wait(h,env,'return #client.all()',b'1\n',server);settle(log)
            _,with_client,_=shot('client',ev('return client.all()[1].screen.name'))
            assert ImageChops.difference(im.convert("RGB"),with_client.convert("RGB")).getbbox() is not None
            ev('K.reload()');time.sleep(.15);settle(log)
            newer,_,_=shot('after-reload');assert int(newer.split(':')[1])>int(failed.split(':')[1])
            before=len(list(Path(f'/proc/{server.pid}/fd').iterdir()))
            for i in range(12):
                k=ev('return core.screenshot("HEADLESS-1")');assert k.startswith('screenshot:')
                ev('core.image_reload('+json.dumps(k)+')')
            after=len(list(Path(f'/proc/{server.pid}/fd').iterdir()))
            assert after==before,(before,after)
            receipts.append(dict(fd_before=before,fd_after=after))
            # Capturing the lock in the same request cannot see the last desktop frame.
            _,locked,_=shot('native-immediate',prefix='core.inspector("HEADLESS-1",true);core.inspector("HEADLESS-2",true);assert(core.lock());')
            assert locked.convert('RGB').getbbox() is None
            ev('core.set_lock_handler(function()error("broken lock capture")end);core.dirty()');settle(log)
            _,broken,_=shot('native-broken','HEADLESS-2')
            assert not ({(255,32,16),(16,239,48),(18,52,86)} & set(broken.convert('RGB').get_flattened_data()))
            assert ev('return core.unlock()')=='false'
        finally:peer.close()
        h.quit(server,env,log)
    with h.boot(CONFIG) as (server,env,work,log):
        h.ev(env,'core.inspector("HEADLESS-1",true);core.dirty()');settle(log)
        locker=Locker(env)
        try:
            locker.cover(locker.outputs[0]);locker.pump(.2);settle(log)
            path=work/'external.png'
            assert h.ev(env,f'return core.screenshot("HEADLESS-1",{json.dumps(str(path))})').startswith(b'screenshot:')
            im=Image.open(path).convert('RGB');assert set(im.get_flattened_data())=={(32,48,64)}
            locker.close();locker=None;time.sleep(.1)
            path=work/'locker-death.png'
            assert h.ev(env,f'return core.screenshot("HEADLESS-1",{json.dumps(str(path))})').startswith(b'screenshot:')
            assert not ({(255,32,16),(16,239,48),(18,52,86),(32,48,64)} & set(Image.open(path).convert('RGB').get_flattened_data()))
            h.quit(server,env,log)
        finally:
            if locker:locker.close()
    (h.out/'screenshot-receipts.json').write_text(json.dumps(receipts,indent=2)+'\n')
    print('PASS: composed readback/cache/render/save-failure/scale/origin/reload/FD retirement and immediate/native/external/crashed lock coverage:',h.out)

if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-shot-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(ROOT/'build/kiln',c_baseline.source(),out))
