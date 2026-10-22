"""Behavioral checks for public verbs, runnable against either implementation."""
import c_baseline
import argparse
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
from declaration_checks import wait, settle
from protocol_client import Client
from x11_client import XClient
from xwayland_bridge_checks import CONFIG

ROOT = Path(__file__).resolve().parents[1]


def run(h):
    with h.boot(CONFIG, overrides={'WLR_HEADLESS_OUTPUTS': '2'}) as (server, env, work, log):
        def ev(source):
            result = h.ev(env, source)
            assert not result.startswith(b'ERROR:'), (source, result)
            return result
        def yes(source):
            wait(h, env, 'return '+source, b'true\n', server)
        native = Client(env)
        observer = Client(env)
        x = None
        receipt = []
        try:
            a = native.toplevel('public-native')
            observer.bind('zwlr_foreign_toplevel_manager_v1', 3)
            yes('#client.all()==1')
            ev('A=client.all()[1];S,T=unpack(screen.all());core.tick(S.name,false);core.tick(T.name,false)')
            settle(log)
            assert ev('return K.object.lookup(A.handle)==A')==b'true\n'
            assert ev('core.hits(S.name,0,0);local b=core.box("root");local c=S.canvas;return c.width==b.width and c.height==b.height and c.x==b.x and c.y==b.y')==b'true\n'
            native.pump(.2); observer.pump(.2)
            foreign = next(m for k,m in observer.objects.values() if k=='foreign')
            original_outputs = set(foreign['outputs'])
            assert len(original_outputs)==1
            for target, count in [('nil',0), ('"NO-SUCH-OUTPUT"',0), ('T.name',1), ('S.name',1)]:
                assert ev(f'return select("#",core.client.set_output_mirror(A.handle,{target}))')==b'0\n'
                observer.pump(.12)
                assert len(foreign['outputs'])==count, foreign
                if target=='T.name': assert not original_outputs.intersection(foreign['outputs'])
                if target=='S.name': assert foreign['outputs']==original_outputs
                receipt.append(dict(mirror=target,outputs=list(foreign['outputs'])))
            assert ev('return select("#",core.client.configure(A.handle,333,211))')==b'0\n'
            native.pump(.2)
            assert a['size']==(333,211), a['size']
            receipt.append(dict(native_size=a['size']))
            # Decode configure arrays without changing the shared wire client's policy.
            original_dispatch = native.event
            states = []
            def dispatch(obj, op, data):
                if obj==a['role'] and op==0:
                    size=struct.unpack_from('=I',data,8)[0]
                    states.append(list(struct.unpack('='+str(size//4)+'I',data[12:12+size])))
                original_dispatch(obj,op,data)
            native.event=dispatch
            for edges, expected in [(0,[]),(4,[5]),(15,[5,6,7,8])]:
                ev(f'core.client.set_tiled_hint(A.handle,{edges})');native.pump(.15)
                assert states and [v for v in states[-1] if v in (5,6,7,8)]==expected, states
                receipt.append(dict(edges=edges,states=states[-1]))
            x=XClient(ev('return os.getenv("DISPLAY")').decode().strip())
            w=x.create(instance='public-x')
            # Restore normal declaration before mapping the X client.
            ev('K.reload()');yes('#client.all()==2');native.pump(.2);x.pump(.2);settle(log)
            ev('for _,c in ipairs(client.all())do if c.instance=="public-x" then X=c end end;core.tick(S.name,false);core.tick(T.name,false)')
            settle(log)
            before=x.geometry(w)
            ev('core.client.configure(X.handle,321,213);core.client.set_tiled_hint(X.handle,15)')
            x.pump(.2);after=x.geometry(w)
            assert after==before[:2]+[321,213], (before,after)
            receipt.append(dict(x_before=before,x_after=after))
            unmanaged=x.create(instance='public-or',override=True,box=(80,90,120,100))
            yes('#client.all()==3')
            ev('for _,c in ipairs(client.all())do if c.instance=="public-or" then OR=c end end')
            before=x.geometry(unmanaged)
            ev('core.client.configure(OR.handle,444,222)');x.pump(.1)
            assert x.geometry(unmanaged)==before
            receipt.append(dict(override_redirect_unchanged=before))
            x.destroy(unmanaged);yes('#client.all()==2')
            class Legacy(Client):
                def bind(self,interface,version,required=True):
                    return super().bind(interface,1 if interface=='xdg_wm_base' else version,required)
            legacy=Legacy(env)
            try:
                old=legacy.toplevel('public-v1')
                yes('#client.all()==3')
                ev('for _,c in ipairs(client.all())do if c.app_id=="public-v1" then V1=c end end;core.client.set_tiled_hint(V1.handle,15);core.client.configure(V1.handle,200,160)')
                legacy.pump(.2)
                assert old['size']==(200,160)
                receipt.append(dict(xdg_version=1,size=old['size'],wire=legacy.records))
            finally:legacy.close()
            yes('#client.all()==2')
            for name,args in [('configure','123,99'),('set_tiled_hint','15'),('set_output_mirror','nil')]:
                assert ev(f'return select("#",core.client.{name}(4294967295,{args}))')==b'0\n'
            assert ev('return require("kiln.ipc").eval("return 1,nil,false")')==b'1\tnil\tfalse\n\n'
            assert ev('return require("kiln.ipc").eval("return setmetatable({},{__tostring=function() error(1) end}),42")')==b'?\t42\n\n'
            assert ev('return require("kiln.ipc").eval([[error("public probe")]]):match("public probe")')==b'public probe\n'
            (work/'public-contract.json').write_text(json.dumps(dict(implementation=h.implementation,observations=receipt,native=native.records,foreign=observer.records),indent=2)+'\n')
            h.quit(server,env,log)
        finally:
            if x:x.close()
            native.close();observer.close()
    print('PASS: direct public configure/native tiled state/foreign output mirror/X configure/stale handles and exact ipc.eval bytes')


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--binary',type=Path,default=ROOT/'build/kiln')
    parser.add_argument('--original',type=Path,default=c_baseline.source())
    parser.add_argument('--implementation',choices=['odin','c'],default='odin')
    args=parser.parse_args()
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py')
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-public-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(args.binary.resolve(),args.original.resolve(),out,args.implementation))
