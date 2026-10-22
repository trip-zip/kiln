"""Native lock quarantine of existing claims/constraints/drag; separate queue fixture."""
import json
import subprocess
from authentication_checks import fixture
from lock_checks import Locker, keys
from idle_checks import CONFIG
from output_fixture import LUA
from declaration_checks import wait, settle
from lock_lifecycle_checks import covered
from policy_checks import private_x11
from protocol_client import Client


def run(h):
    base=h.out/'lock-input';base.mkdir()
    suite=fixture(type(h)(h.binary,h.original,base))
    config=CONFIG+LUA+'''
KEYS=0;MOVES=0
K.on('input::key',function() KEYS=KEYS+1 end)
client.on('request::move',function() MOVES=MOVES+1 end)
'''
    with private_x11(base) as display:
        with suite.boot(config,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            c=Client(env)
            def ev(s):return suite.ev(env,s)
            def yes(s):wait(suite,env,'return '+s,b'true\n',server)
            def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);c.pump(.1)
            def unlock():
                ev('core.authenticate("fixture-success")');yes('core._lock_state().authenticated');ev('core.unlock()');yes('not K.lockscreen.active')
            try:
                root=c.toplevel('QUARANTINE');yes('#client.all()==1');settle(log)
                win=subprocess.check_output(['xdotool','search','--name',''],env=env,text=True).splitlines()[-1]
                xdo('windowfocus',win);xdo('mousemove','--window',win,200,200)
                relative=c.relative_pointer();constraint=c.constrain(root);assert c.objects[constraint][1]['active']
                xdo('mousemove','--window',win,240,220);assert any('relative' in r for r in c.records)
                # Real active constraint must deactivate synchronously with lock.
                ev('core.lock()');c.pump(.1);assert not c.objects[constraint][1]['active']
                start=len(c.records);before=int(ev('return KEYS'))
                xdo('mousemove','--window',win,280,260);xdo('click',1);xdo('click',5);xdo('key','a')
                assert not any('relative' in r or (r.get('input')=='pointer' and r['op'] in (2,3,4)) or (r.get('input')=='keyboard' and r['op'] in (3,4)) for r in c.records[start:])
                assert int(ev('return KEYS'))==before
                unlock();c.send(constraint,0);c.roundtrip()
                # Existing Lua claims and held physical keys cannot cross the generation.
                ev('G=K.keygrabber{};P=K.mousegrabber{}');xdo('keydown','a')
                ev('core.lock()');yes('K.lockscreen.active');xdo('keyup','a')
                assert ev('return G.active,P.active')==b'false\tfalse\n'
                unlock()
                # Synthetic queue receipt is distinct from the native events above.
                ev('BEFORE=KEYS;MOVED=MOVES;assert(output_fixture(7,""));assert(core.lock())')
                yes('K.lockscreen.active');yes('KEYS==BEFORE and MOVES==MOVED');unlock()
                # A live wire drag and overlay/popup pixels stay below opaque coverage.
                xdo('mousemove','--window',win,200,200);xdo('mousedown',1)
                serial=[r for r in c.records if r.get('input')=='pointer' and r['op']==3 and r['words'][-1]==1][-1]['words'][0]
                source=c.data_source({'text/plain':b'private drag'},actions=1)
                icon=c.start_drag(source,root,serial);yes('resource_fixture(1)==1')
                ev('core.lock()');yes('K.lockscreen.active');yes('resource_fixture(1)==0')
                popup=c.popup(root,color=0xffee1122)
                layer=c.layer('lock-overlay',width=300,height=80,anchor=5,band=3)
                for n in range(3):covered(env,work/f'covered-{n}.png')
                start=len(c.records);xdo('mousemove','--window',win,350,250);xdo('mouseup',1)
                assert not any('relative' in r or (r.get('input')=='pointer' and r['op'] in (2,3,4)) for r in c.records[start:])
                c.destroy_xdg(popup);c.destroy(layer);unlock()
                (work/'quarantine-wire.json').write_text(json.dumps(c.records,indent=2)+'\n')
                (work/'queue-receipt.txt').write_text('Synthetic pre-lock key and move request both dropped across ownership generation.\n')
                suite.quit(server,env,log)
            finally:c.close()
    print('PASS: native lock suspends active constraints, relative motion, grabs, held keys and wire drag; popup/overlay coverage; synthetic queued-input rejection')
