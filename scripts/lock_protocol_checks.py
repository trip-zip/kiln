"""Bounded malformed ext-session-lock peers; every error leaves native coverage."""
import c_baseline
import json
from pathlib import Path
import time
from authentication_checks import fixture
from declaration_checks import wait,capture
from lock_checks import Locker
from protocol_client import u
from idle_checks import CONFIG


def run(h):
    base=h.out/'lock-protocol';base.mkdir();suite=fixture(type(h)(h.binary,h.original,base))
    with suite.boot(CONFIG) as (server,env,work,log):
        def ev(s):return suite.ev(env,s)
        def yes(s):wait(suite,env,'return '+s,b'true\n',server)
        results=[]
        for case in ('before-surface-death','mapped-death','destroy-locked','duplicate-output','invalid-ack','unacked-commit','null-buffer','wrong-size'):
            c=Locker(env);c.pump(.1);assert c.lock_events==['locked']
            error=None
            try:
                if case=='mapped-death':c.cover(c.outputs[0])
                elif case=='destroy-locked':c.send(c.lock,0);c.roundtrip()
                elif case=='duplicate-output':c.cover(c.outputs[0]);c.cover(c.outputs[0])
                elif case not in ('before-surface-death',):
                    meta={'color':0xff203040};surface=c.new('surface',meta);meta['surface']=surface
                    role=c.new('unacked');c.send(c.compositor,0,u(surface));c.send(c.lock,1,u(role,surface,c.outputs[0]));c.roundtrip()
                    if case=='invalid-ack':c.send(role,1,u(0xffffffff));c.roundtrip()
                    elif case=='unacked-commit':c.paint(meta,1280,720);c.roundtrip()
                    elif case=='null-buffer':c.send(surface,6);c.roundtrip()
                    elif case=='wrong-size':
                        # Configure serial is received on the wire, not guessed from compositor state.
                        # Reissue with a recorder that deliberately paints the wrong dimensions.
                        c.send(role,0);c.send(surface,0);c.roundtrip()
                        original=c.paint
                        c.paint=lambda meta,w,h:original(meta,w+1,h)
                        c.cover(c.outputs[0])
            except AssertionError as e:
                error=str(e);assert 'protocol error' in error,error
            finally:c.close()
            if case not in ('before-surface-death','mapped-death'):assert error is not None,case
            yes('core._lock_state().owner=="native" and core._lock_state().surfaces==0')
            assert ev('return core.unlock()')==b'false\n'
            capture(env,work/(case+'.png'))
            ev('core.authenticate("fixture-success")');yes('core._lock_state().authenticated');ev('core.unlock()')
            results.append({'case':case,'wire_error':error,'locked_until_current_authentication':True})
        (work/'malformed.json').write_text(json.dumps(results,indent=2)+'\n')
        suite.quit(server,env,log)
    print('PASS: locker death before/after map and six invalid lock wire sequences preserve gate and recover')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-lock-protocol-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
