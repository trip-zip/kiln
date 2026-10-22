"""Combined owned lifetimes; headless output mutations are synthetic fixtures."""
import c_baseline
import json
import subprocess
from pathlib import Path
import time
from PIL import Image
from authentication_checks import fixture
from lock_checks import Locker
from idle_checks import IdleClient
from declaration_checks import wait,capture,settle
from dbus_checks import private_bus,peer,control,notify,close,CONFIG
from output_fixture import LUA
from window_state_checks import launch,stop,counts

COUNTS='''
function refs()local n=0;for k,v in pairs(debug.getregistry())do if type(k)=='number' and type(v)=='function'then n=n+1 end end;return n end
LOADS=(LOADS or 0)+1
K.on('idle::inhibit',function(on) INHIBITED=on end)
'''

def covered(env,path,output=None):
    if output:subprocess.run(["grim","-o",output,str(path)],env=env,check=True,timeout=5)
    else:capture(env,path)
    colors=Image.open(path).convert('RGB').getcolors(1000000)
    assert colors is not None
    forbidden={(48,80,144),(238,17,34),(255,128,32),(96,64,32),(32,64,96)}
    assert not any(color in forbidden for _,color in colors),path


def run(h):
    base=h.out/'lock-lifecycle';base.mkdir()
    seed=type(h)(h.binary,h.original,base);suite=fixture(seed)
    config=CONFIG+LUA+COUNTS
    with private_bus(base/'bus') as (address,bus):
        with suite.boot(config,overrides={'DBUS_SESSION_BUS_ADDRESS':address,'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
            def ev(s):return suite.ev(env,s)
            def yes(s):wait(suite,env,'return '+s,b'true\n',server)
            c=IdleClient(env);foot,f=launch(env,work,'LOCK-LIFETIME');locker=None
            samples=[];receipt=[];last_id=0
            try:
                root=c.toplevel('LOCK-SENTINEL');yes('#client.all()==2');ev('HANDLE=client.all()[1].handle;core.output.set_position("HEADLESS-1",-301,77);core.output.set_scale("HEADLESS-1",1.3)')
                sub=c.subsurface(root);inhibitor=c.inhibit(sub);yes('core._lock_state().inhibitors==1');c.pump(.15)
                yes('INHIBITED==true')
                # No remaining output means no future reconcile can repair inhibition.
                ev('assert(output_fixture(1,"HEADLESS-1"));assert(output_fixture(1,"HEADLESS-2"))')
                yes('#core.output.list()==0 and INHIBITED==false')
                ev('assert(output_fixture(2,"HEADLESS-1",1280,720));assert(output_fixture(2,"HEADLESS-2",1280,720))')
                yes('#client.all()==2 and INHIBITED==true')
                ev('core.output.set_position("HEADLESS-1",-301,77);core.output.set_scale("HEADLESS-1",1.3)')
                # Same resident peer and foot population at every settled sample.
                for cycle in range(6):
                    id=notify(env,title='Locked notification',hints='{"urgency": <byte 2>}',timeout=0);assert id>last_id;last_id=id
                    expires=notify(env,title='Locked expiry',timeout=650)
                    with peer(env,work,'org.ktest.LockCycle') as (p,marker):
                        yes('#K.systray.items()==1');ev('K.set_idle_timeout(100)');time.sleep(.15)
                        if cycle==0:ev('core.set_lock_handler(function() end)')
                        assert ev('return core.lock(),core.unlock()')==b'true\tfalse\n'
                        yes('K.lockscreen.active');yes('resource_fixture(10)==1')
                        for n in range(3):covered(env,work/f'engage-{cycle}-{n}.png')
                        if cycle==0:assert Image.open(work/'engage-0-0.png').convert('RGB').getbbox() is None
                        # Unchanged native lock only solves on its scheduled clock.
                        yes('#notification.all()==1')
                        time.sleep(.15);solve=int(ev('return resource_fixture(16)'));time.sleep(.3)
                        assert int(ev('return resource_fixture(16)'))-solve<=2
                        ev('core.authenticate("fixture-failure")');yes('not core._lock_state().pending');assert ev('return core.unlock()')==b'false\n'
                        ev('core.authenticate("fixture-delay")');yes('core._lock_state().pending')
                        dispatch=int(ev('return resource_fixture(8)'))
                        control(env,'org.ktest.LockCycle','SetTitle','while authenticating')
                        yes('K.systray.items()[1].title=="while authenticating"');assert int(ev('return resource_fixture(8)'))>dispatch
                        ev('core.dirty()');covered(env,work/f'auth-pending-{cycle}.png')
                        # Reload cancels the worker while retaining protocol service state.
                        ev('K.reload()');yes('not core._lock_state().pending');assert ev('return core.unlock()')==b'false\n'
                        yes('#notification.all()==1 and notification.all()[1].id=='+str(id));yes('#K.systray.items()==1')
                        (work/'rc.lua').write_text('error("private lock lifecycle repair")');ev('K.reload()');time.sleep(.05)
                        covered(env,work/f'broken-{cycle}.png');assert ev('return core.unlock()')==b'false\n'
                        (work/'rc.lua').write_text(config);ev('K.reload()');yes('#client.all()==2 and #K.systray.items()==1')
                        ev('core.authenticate("fixture-success")');yes('core._lock_state().authenticated');ev('core.unlock()');yes('not K.lockscreen.active')
                        locker=Locker(env);locker.pump(.15);assert locker.lock_events==['locked']
                        for o in locker.outputs:locker.cover(o)
                        covered(env,work/f'external-{cycle}.png')
                        # Both external-lock reload paths keep the resource as sole unlock authority.
                        ev('K.reload()');yes('core._lock_state().owner=="ext"');assert ev('return core.unlock()')==b'false\n'
                        (work/'rc.lua').write_text('error("external repair")');ev('K.reload()');covered(env,work/f'external-broken-{cycle}.png')
                        (work/'rc.lua').write_text(config);ev('K.reload()');yes('core._lock_state().owner=="ext"')
                        # Resize and disable/re-enable are fixture output transactions, not DPMS.
                        ev('core.output.set_mode("HEADLESS-1",900,660,0);core.output.set_enabled("HEADLESS-2",false)');locker.pump(.15)
                        covered(env,work/f'output-resize-{cycle}.png','HEADLESS-1')
                        ev('core.output.set_enabled("HEADLESS-2",true)');locker.pump(.15)
                        covered(env,work/f'output-enabled-{cycle}.png')
                        ev('assert(output_fixture(1,"HEADLESS-1"));assert(output_fixture(1,"HEADLESS-2"))');locker.pump(.1);yes('#core.output.list()==0')
                        assert ev('return core.unlock()')==b'false\n';suite.healthy(env)
                        ev('assert(output_fixture(2,"HEADLESS-1",1280,720));assert(output_fixture(2,"HEADLESS-2",1280,720))');locker.pump(.15)
                        for o in locker.outputs:locker.cover(o)
                        covered(env,work/f'output-return-{cycle}.png')
                        (work/f'wire-{cycle}.json').write_text(json.dumps(locker.records,indent=2)+'\n')
                        locker.close();locker=None;yes('core._lock_state().owner=="native"')
                        for n in range(3):covered(env,work/f'crash-{cycle}-{n}.png')
                        assert ev('return core.unlock()')==b'false\n'
                        ev('core.authenticate("fixture-success")');yes('core._lock_state().authenticated');ev('core.unlock()')
                        close(env,id);yes('#notification.all()==0')
                    yes('#K.systray.items()==0')
                    ev('K.set_idle_timeout(nil);core.output.set_position("HEADLESS-1",-301,77);core.output.set_scale("HEADLESS-1",1.3)')
                    yes('resource_fixture(14)==0 and resource_fixture(15)==0 and resource_fixture(13)==0 and resource_fixture(10)==0 and resource_fixture(11)==0')
                    c.pump(.15);settle(log);ev('collectgarbage("collect")')
                    vals=list(map(int,ev('return refs(),resource_fixture(12),resource_fixture(13),resource_fixture(14),resource_fixture(15),resource_fixture(17),resource_fixture(18),resource_fixture(19),resource_fixture(10),resource_fixture(11)').split()))
                    samples.append({'fds':len(list(Path('/proc',str(server.pid),'fd').iterdir())),'counts':vals})
                    before=counts(log);time.sleep(.2);assert counts(log)==before
                    receipt.append({'cycle':cycle,'notification':id,'expiry':expires,'repair_unlock':True,'zero_output_recovery':True})
                assert all(v==samples[0] for v in samples),samples
                # Retire an inhibitor and prove its three listener owners disappear live.
                c.send(inhibitor,0);c.roundtrip();yes('resource_fixture(12)==0');new_inhib=c.inhibit(root)
                # Shutdown owns a helper, live inhibitor and external locker object.
                ev('core.lock();core.authenticate("fixture-delay")');yes('core._lock_state().pending')
                locker=Locker(env);assert locker.lock_events==['finished']
                children=Path('/proc',str(server.pid),'task',str(server.pid),'children').read_text().split()
                suite.quit(server,env,log)
                assert all(not Path('/proc',p).exists() for p in children)
                (work/'lifecycle.json').write_text(json.dumps({'samples':samples,'cycles':receipt,'shutdown_children':children,'output_mutations':'synthetic headless fixture','auth':'compile-time worker stub'},indent=2)+'\n')
                assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
            finally:
                if locker:locker.close()
                c.close();stop(foot);f.close()
        # Native authentication and an owning external lock are exclusive;
        # exercise shutdown of an active locker separately from its rejected peer.
        with suite.boot(config,overrides={'DBUS_SESSION_BUS_ADDRESS':address}) as (server,env,work,log):
            c=IdleClient(env);locker=None
            try:
                root=c.toplevel('SHUTDOWN-INHIBITOR');c.inhibit(root)
                locker=Locker(env);locker.pump(.15);assert locker.lock_events==['locked']
                locker.cover(locker.outputs[0])
                wait(suite,env,'return core._lock_state().surfaces==1 and core._lock_state().inhibitors==1',b'true\n',server)
                suite.quit(server,env,log)
                assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
            finally:
                if locker:locker.close()
                c.close()
    print('PASS: six combined idle/native/external/auth/reload/bus/output cycles, bounded coverage frames, zero-output recovery and equivalent live resources')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-lock-life-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
