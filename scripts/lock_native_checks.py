"""Installed native lockscreen, actual X11 typing, controlled authentication only."""
import c_baseline
import json
import shutil
import subprocess
import time
from pathlib import Path
from PIL import Image
from authentication_checks import ROOT
from declaration_checks import wait,capture
from policy_checks import private_x11
from window_state_checks import launch,stop
from protocol_client import Client
from lock_checks import keys
from x11_client import XClient


def installed(h):
    base=h.out/'lock-installed';base.mkdir()
    data=base/'share';data.mkdir();shutil.copytree(ROOT/'lua',data/'lua')
    (data/'rc.lua').write_text((ROOT/'kilnrc.lua').read_text()+"\nK=require('kiln');LOADS=(LOADS or 0)+1\n")
    binary=base/'kiln-auth-fixture'
    subprocess.run(['odin','build','.', '-collection:deps=build','-define:KILN_AUTH_FIXTURE=true','-define:KILN_OUTPUT_FIXTURE=true','-define:KILN_DATADIR='+str(data),'-out:'+str(binary),'-extra-linker-flags:-Wl,--export-dynamic'],cwd=ROOT,check=True,timeout=60)
    return type(h)(binary.resolve(),h.original,base),base


def run(h):
    suite,base=installed(h)
    with private_x11(h.out) as display:
        with suite.boot(None,cwd=base,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            def ev(s):return suite.ev(env,s)
            def yes(s):wait(suite,env,'return '+s,b'true\n',server)
            foot,f=launch(env,work,'LOCK-FOOT');desktop=Client(env);xpeer=XClient(ev('return os.getenv("DISPLAY")').decode().strip())
            rc=Path(ev('return core._config_path()').decode().strip());saved=rc.read_text()
            try:
                yes('#client.all()==1');root=desktop.toplevel('LOCK-RECEIPTS');yes('#client.all()==2');xwindow=xpeer.create('LOCK-X11');yes('#client.all()==3')
                ev('s=screen.all()[1];core.output.set_position(s.name,-301,77);BINDINGS=0;K.on("input::key",function() BINDINGS=BINDINGS+1 end)')
                win=subprocess.check_output(['xdotool','search','--name',''],env=env,text=True).splitlines()[-1]
                def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);time.sleep(.025)
                def type_text(text):xdo('type','--clearmodifiers','--delay','10',text)
                def pic(name):time.sleep(.06);capture(env,work/name)
                def locked():yes('core._lock_state().owner=="native" and K.lockscreen.active')
                def unlocked():yes('core._lock_state().owner=="unlocked" and not K.lockscreen.active')
                xdo('windowfocus',win)
                for scale in (1,1.3):
                    ev('s.scale='+str(scale));xdo('key','super+shift+Escape');locked()
                    before=int(ev('return BINDINGS'));desktop.pump(.1);native_before=len(keys(desktop));xpeer.pump(.1);x_before=sum(r['event'] in (2,3) for r in xpeer.records)
                    pic(f'native-{scale}.png')
                    type_text('wrong');pic(f'masked-{scale}.png');xdo('key','BackSpace');xdo('key','Escape')
                    # Compose yields one Unicode codepoint; backspace clears it as one unit.
                    ev('core.input.set_keymap{layout="us",variant="intl"}')
                    xdo('key','apostrophe','e')
                    ev("local p;for i=1,30 do local n,v=debug.getupvalue(K.lockscreen.on_key,i);if n=='password' then p=v;break end end;assert(p and #p==2,'composed UTF-8 length')")
                    pic(f'composed-{scale}.png');xdo('key','BackSpace')
                    ev("for i=1,30 do local n,v=debug.getupvalue(K.lockscreen.on_key,i);if n=='password' then assert(#v==0,'whole-codepoint backspace');break end end;core.input.set_keymap{layout='us'}")
                    type_text('fixture-failure');xdo('key','Return');yes('not core._lock_state().pending')
                    pic(f'failed-{scale}.png');assert ev('return core.unlock()')==b'false\n'
                    type_text('fixture-delay');xdo('key','Return');yes('core._lock_state().pending')
                    request=ev('return core._lock_state().request');xdo('key','Return','Return');assert ev('return core._lock_state().request')==request
                    pic(f'pending-{scale}.png');unlocked()
                    desktop.pump(.1);assert len(keys(desktop))==native_before and int(ev('return BINDINGS'))==before
                    xpeer.pump(.1);assert sum(r['event'] in (2,3) for r in xpeer.records)==x_before
                    pic(f'restored-{scale}.png')
                    # Restored focus can receive ordinary typing again.
                    xdo('key','z');desktop.pump(.1);assert int(ev('return BINDINGS'))>before
                ev('K.lock()');locked();type_text('fixture-delay');xdo('key','Return');yes('core._lock_state().pending')
                ev('K.reload()');yes('LOADS==2 and not core._lock_state().pending');locked()
                time.sleep(.8);assert ev('return core.unlock()')==b'false\n'
                # An error after opening a declaration cannot remove the independent floor.
                ev('core.set_lock_handler(function() core.open{id="broken-lock"};error("lock declaration failure") end);core.dirty()')
                pic('broken-handler.png');assert ev('return core.unlock()')==b'false\n'
                rc.write_text('error("private broken lock config")');ev('K.reload()');time.sleep(.2);locked();pic('broken-config.png')
                rc.write_text(saved);ev('K.reload()');yes('LOADS==3');locked();pic('repaired.png')
                type_text('fixture-success');xdo('key','Return');unlocked();pic('repair-unlocked.png')
                time.sleep(1.1)
                n=log.read_text().count('Lock layout ');time.sleep(1.1);assert log.read_text().count('Lock layout ')==n
                (work/'x11-wire.json').write_text(json.dumps(xpeer.records,indent=2)+'\n')
                (work/'desktop-wire.json').write_text(json.dumps(desktop.records,indent=2)+'\n')
                (work/'receipt.json').write_text(json.dumps({'backend':'private Xvfb X11','scales':[1,1.3],'origin':[-301,77],'real_credentials':'NOT RUN','repair_unlock':True},indent=2)+'\n')
                suite.quit(server,env,log)
            finally:rc.write_text(saved);desktop.close();xpeer.close();stop(foot);f.close()
    print('PASS: installed lock chord, masked/compose/backspace/Escape native input, failure/pending/success, fractional output, broken/repaired reload and clock retirement')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-lock-native-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(ROOT/'build/kiln',c_baseline.source(),out))
