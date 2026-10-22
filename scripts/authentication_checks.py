"""Compile-time helper stub; no account passwords or host PAM policy changes."""
import c_baseline
import json
import subprocess
import time
from pathlib import Path
from declaration_checks import wait,capture
from idle_checks import CONFIG
ROOT=Path(__file__).resolve().parents[1]

def fixture(h):
    base=h.out/'authentication';base.mkdir()
    binary=base/'kiln-auth-fixture'
    subprocess.run(['odin','build','.', '-collection:deps=build','-define:KILN_AUTH_FIXTURE=true','-define:KILN_OUTPUT_FIXTURE=true','-out:'+str(binary),'-extra-linker-flags:-Wl,--export-dynamic'],cwd=ROOT,check=True,timeout=60)
    return type(h)(binary.resolve(),h.original,base)

def run(h):
    suite=fixture(h)
    with suite.boot(CONFIG+'''\nAUTH={};K.on('session::authenticated',function(e) AUTH[#AUTH+1]=e end)\n''') as (server,env,work,log):
        def ev(s):return suite.ev(env,s)
        def yes(s):wait(suite,env,'return '+s,b'true\n',server)
        def submit(token):return int(ev('return core.authenticate('+json.dumps(token)+')'))
        receipt=[]
        assert ev('return core.authenticate("fixture-success")')==b'nil\n'
        assert ev('return core.lock(),core.unlock(),core.lock()')==b'true\tfalse\tfalse\n'
        for token in ('fixture-no-pidfd','fixture-no-source'):
            before=len(list(Path('/proc',str(server.pid),'fd').iterdir()))
            assert ev('return core.authenticate('+json.dumps(token)+')')==b'nil\n'
            assert ev('return 6*7')==b'42\n'
            yes('not core._lock_state().pending')
            assert ev('return core.unlock()')==b'false\n'
            assert len(list(Path('/proc',str(server.pid),'fd').iterdir()))==before
            receipt.append({'setup_failure':token,'accepted':False,'live_retirement':True})
        for token,reason in [('fixture-failure','rejected'),('fixture-crash','worker'),('fixture-partial','invalid-reply'),('fixture-stale','invalid-reply'),('fixture-old-request','invalid-reply'),('fixture-timeout','timeout')]:
            n=int(ev('return #AUTH'));id=submit(token)
            yes('#AUTH=='+str(n+1));assert ev('return AUTH[#AUTH].id,AUTH[#AUTH].success,AUTH[#AUTH].reason')==f'{id}\tfalse\t{reason}\n'.encode()
            assert ev('return core.unlock(),core._lock_state().pending')==b'false\tfalse\n'
            receipt.append({'id':id,'success':False,'reason':reason})
        start=time.monotonic();id=submit('fixture-delay')
        assert ev('return core.authenticate("fixture-success")')==b'nil\n'
        for _ in range(3):
            assert ev('return 6*7')==b'42\n';ev('core.dirty()');capture(env,work/'pending.png')
        assert time.monotonic()-start<.65
        yes('core._lock_state().authenticated');assert ev('return core.unlock()')==b'true\n'
        assert ev('return core.lock(),core.unlock()')==b'true\tfalse\n'
        submit('fixture-delay');ev('K.reload()');yes('not core._lock_state().pending');time.sleep(.8)
        assert ev('return core.unlock(),core._lock_state().authenticated')==b'false\tfalse\n'
        assert ev('return core.authenticate(string.rep("x",512)),core.authenticate("x"..string.char(0).."y")')==b'nil\tnil\n'
        id=submit('fixture-success');yes('core._lock_state().authenticated');assert ev('return core.unlock(),core.unlock()')==b'true\ttrue\n'
        yes('core._lock_state().owner=="unlocked"')
        samples=[]
        for _ in range(6):
            ev('core.lock()');submit('fixture-delay');ev('K.reload()');yes('not core._lock_state().pending')
            submit('fixture-success');yes('core._lock_state().authenticated');ev('core.unlock()')
            samples.append(len(list(Path('/proc',str(server.pid),'fd').iterdir())))
        assert len(set(samples))==1,samples
        ev('core.lock()');submit('fixture-delay')
        children=Path('/proc',str(server.pid),'task',str(server.pid),'children').read_text().split()
        suite.quit(server,env,log)
        assert all(not Path('/proc',pid).exists() for pid in children),children
        (work/'auth-receipts.json').write_text(json.dumps({'results':receipt,'fd_samples':samples,'shutdown_children':children,'real_credential_authentication':'NOT RUN'},indent=2)+'\n')
    print('PASS: asynchronous fixture failure/delay/crash/partial/stale/timeout, generation gate, live cancellation, six FD samples and pending shutdown')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-auth-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(ROOT/'build/kiln',c_baseline.source(),out))
