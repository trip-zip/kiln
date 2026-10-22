"""Disabled output clocks, retained identity and wlroots-owned gamma protocol."""
import c_baseline
import json,os,struct,time
from pathlib import Path
from declaration_checks import check,wait,settle
from protocol_client import Client,u
from layer_checks import CONFIG
from output_fixture import harness,LUA


def run(h):
    with h.boot(CONFIG,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        c=Client(env);observer=Client(env)
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        def yes(s):wait(h,env,'return '+s,b'true\n',server)
        def pump():c.pump(.15);observer.pump(.1)
        try:
            a=c.toplevel('power-client');layer=c.layer('power-layer',output='HEADLESS-1');observer.bind('zwlr_foreign_toplevel_manager_v1',3);pump()
            ev("S=client.all()[1].screen;for _,s in ipairs(screen.all())do if s~=S then T=s end end;C=client.all()[1];OLD=S;TICKS=0;MAXDT=0;K.on('frame::tick',function(e)TICKS=TICKS+1;MAXDT=math.max(MAXDT,e.dt)end);K.animation.start(S.name,'power',1,10,0)")
            time.sleep(.15);ev('core.output.set_enabled(S.name,false)');pump();yes('not S.enabled and S==OLD and C.screen==S and #client.all()==1 and core.client.focused()==nil')
            ev('OFF_TICKS=TICKS;OFF_VALUE=K.animation.get("power",0)')
            before=log.read_text().count('Layout ');time.sleep(.35);yes('TICKS==OFF_TICKS and K.animation.get("power",0)==OFF_VALUE')
            assert log.read_text().count('Layout ')==before
            ev('core.output.set_enabled(S.name,true)');pump();yes('S.enabled and TICKS>OFF_TICKS and MAXDT>.3')
            yes('K.animation.get("power",0)<.2')
            for _ in range(5):
                ev('core.output.set_enabled(S.name,false);core.output.set_enabled(T.name,false)');pump()
                yes('not S.enabled and not T.enabled and #screen.all()==2 and #LS.all==1')
                ev('core.dirty();K.reload()');pump();yes('not S.enabled and S==OLD')
                before=log.read_text().count('Layout ');time.sleep(.1);assert log.read_text().count('Layout ')==before
                ev('core.output.set_enabled(S.name,true);core.output.set_enabled(T.name,true)');pump();settle(log)
                yes('#client.all()==1 and #LS.all==1 and LS.all[1].buffer_mapped')
            handles=[m for _,(k,m) in observer.objects.items() if k=='foreign' and not m.get('closed')];assert len(handles)==1
            (work/'power-wire.json').write_text(json.dumps({'client':c.records,'observer':observer.records},indent=2)+'\n')
            h.quit(server,env,log)
        finally:c.close();observer.close()
    print('PASS: disable/re-enable with clients/layers/animation, true native delta and Lua clamp, all-off IPC/reload recovery and identity retention')
    gamma(h)

def gamma(h):
    with h.boot(CONFIG) as (server,env,work,log):
        c=Client(env)
        try:
            manager=c.bind('zwlr_gamma_control_manager_v1',1);assert c.globals['zwlr_gamma_control_manager_v1'][0][1]==1
            meta={};control=c.new('gamma',meta);c.send(manager,0,u(control,c.outputs[0]));c.roundtrip();assert meta.get('failed') and 'size' not in meta
            # Requests on the unsupported inert object close FDs without interpreting LUTs.
            for payload in [b'',bytes(256*6)]:send_gamma(c,control,payload)
            c.send(control,1);c.roundtrip()
            (work/'gamma-unsupported.json').write_text(json.dumps(c.records,indent=2)+'\n')
            h.quit(server,env,log)
        finally:c.close()
    fh=harness(h);fh.count=h.count
    try:gamma_payloads(fh)
    finally:h.count=fh.count

def send_gamma(c,control,payload=None,fd=None):
    owned=fd is None
    if owned:
        fd=os.memfd_create('kiln-gamma-payload',os.MFD_CLOEXEC);os.write(fd,payload)
    try:c.send(control,0,b'',(fd,));c.roundtrip()
    finally:
        if owned:os.close(fd)

def gamma_payloads(h):
    # Documented wlroots fallback size is enabled only in this private binary.
    # This tests LUT parsing and ownership; it does not create hardware support.
    with h.boot(CONFIG+LUA) as (server,env,work,log):
        check(h,env,"do assert(output_fixture(6,'',256)) end",b'\n')
        records=[]
        def open_control(c):
            m=c.bind('zwlr_gamma_control_manager_v1',1);meta={};obj=c.new('gamma',meta);c.send(m,0,u(obj,c.outputs[0]));c.roundtrip();return obj,meta
        for case in ['short','pipe','valid','pending','disconnect','remove']:
            c=Client(env);other=None
            try:
                obj,meta=open_control(c);assert meta.get('size')==256,meta
                if case=='short':
                    try:send_gamma(c,obj,b'\0'*12)
                    except AssertionError as e:assert "ramps don't have the correct size" in str(e)
                    else:raise AssertionError('short gamma payload accepted')
                elif case=='pipe':
                    r,w=os.pipe()
                    try:send_gamma(c,obj,fd=r)
                    finally:os.close(r);os.close(w)
                    assert meta.get('failed')
                elif case in ('valid','pending'):
                    ramp=[round(i*65535/255) for i in range(256)];payload=struct.pack('=768H',*(ramp*3))
                    if case=='pending':check(h,env,"do core.output.set_enabled(core.output.list()[1].name,false) end",b'\n')
                    send_gamma(c,obj,payload);c.pump(.2)
                    if case=='pending':
                        assert not meta.get('failed'),meta
                        check(h,env,"do core.output.set_enabled(core.output.list()[1].name,true) end",b'\n');c.pump(.2)
                    # Headless has no LUT; the scene reports failure on application.
                    assert meta.get('failed'),meta
                    c.send(obj,1);c.roundtrip()
                elif case=='disconnect':
                    other=Client(env);dup,dm=open_control(other);assert dm.get('failed')
                    c.close();c=None;other.send(dup,1);other.roundtrip();new,nm=open_control(other);assert nm.get('size')==256
                    other.send(new,1);other.roundtrip()
                elif case=='remove':
                    check(h,env,"do assert(output_fixture(1,core.output.list()[1].name)) end",b'\n');c.pump(.1)
                    send_gamma(c,obj,bytes(256*6));c.send(obj,1);c.roundtrip()
                if c:records+=c.records
                h.healthy(env)
            finally:
                if c:c.close()
                if other:other.close()
        (work/'gamma-private-payloads.json').write_text(json.dumps(records,indent=2)+'\n')
        h.quit(server,env,log)
    print('PASS: gamma v1 unsupported-backend failure/FD cleanup; private fallback-size fixture checks valid/short/nonseekable LUT payloads, pending-disabled application, exclusivity, disconnect replacement and removal; no hardware gamma claim')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-power-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
