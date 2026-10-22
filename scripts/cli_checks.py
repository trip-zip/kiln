"""Command dispatch, exact stream/status receipts and controlled EOF peers."""
import c_baseline
import base64
import importlib.util
import json
import os
from pathlib import Path
from protocol_client import Client
import socket
import subprocess
import tempfile
import threading
import time

ROOT=Path(__file__).resolve().parents[1]
CONFIG='''K=require('kiln')
screen.on('added',function(s)
 tag.new{name='web',screen=s};tag.new{name='code',screen=s}
end)
require('kiln.ipc').register('echoargs',function(...)
 return require('kiln.ipc').json({...})
end,{desc='test argument bytes',args={{name='word',rest=true}}})
'''

def run(h,client=None):
    client=client or ROOT/'build/kiln-client'
    receipts=[]
    def kc(env,*args,status=0,out=None):
        p=subprocess.run([str(client),*args],env=env,capture_output=True,timeout=10)
        receipts.append(dict(args=args,status=p.returncode,stdout=base64.b64encode(p.stdout).decode(),stderr=base64.b64encode(p.stderr).decode()))
        assert p.returncode==status,(args,p.returncode,p.stdout,p.stderr)
        assert not (p.stderr if status==0 else p.stdout),(args,p.stdout,p.stderr)
        if out is not None:assert p.stdout==out,(args,p.stdout,out)
        return p.stdout if status==0 else p.stderr
    try:
        with h.boot(CONFIG) as (server,env,work,log),h.boot(CONFIG.replace("name='code'","name='other instance'")) as (other,env2,work2,log2):
            kc(env,'ping',out=b'pong\n')
            kc(env,'--json','screen','count',out=b'{"result":1,"status":"ok"}\n')
            kc(env,'--socket',env2['KILN_SOCK'],'tag','list')
            assert b'other instance' in kc(env,'-s',env2['KILN_SOCK'],'tag','list')
            assert b'other instance' not in kc(env,'tag','list')
            for args in [[],['--socket'],['-s',''],['--socket',str(work/'absent')],['--socket','x'*200]]:
                kc(env,*args,*([] if not args or args==['--socket'] else ['ping']),status=2)
            kc(env,'--help');kc(env,'--jsonping',status=1)
            for args in [('bogus',),('tag','view','missing'),('get','core','all','set_event_handler'),('call','client','focused','on'),('eval','error("boom")')]:
                kc(env,*args,status=1)
                assert json.loads(kc(env,'--json',*args,status=1))['status']=='error'
            words=['','two words','a\tb','a\nb','a\rb','a\vb','a\fb','"42"',"a'b",'a"b',r'a\nb','café 日本語','[=[ ]=] [[ ]]','");INJECTED=true;--','--socket','--json']
            data=kc(env,'echoargs',*words)
            assert json.loads(data)==words,data
            assert h.ev(env,'return INJECTED')==b'nil\n'
            for value,kind in [('42','number'),('true','boolean'),('"42"','string'),('two words','string'),('','string')]:
                h.ev(env,'screen.all()[1].tags[1].probe=nil')
                kc(env,'set','tag','web','probe',value)
                assert h.ev(env,'return type(screen.all()[1].tags[1].probe)')==(kind+'\n').encode()
            h.ev(env, "screen.all()[1].tags[1].probe=nil;kiln_ipc('set tag web probe \"42\"')")
            assert h.ev(env, 'return type(screen.all()[1].tags[1].probe),screen.all()[1].tags[1].probe')==b'string\t42\n'
            kc(env,'call','tag','code','view')
            kc(env,'tag','current',out=b'code\n')
            kc(env,'set','tag','code','friend','@tag:web')
            assert h.ev(env,'return screen.all()[1].tags[2].friend==screen.all()[1].tags[1]')==b'true\n'
            kc(env,'eval','return "a\\n\\nb"',out=b'a\n\nb\n')
            kc(env,'eval','return string.rep("x",1000000)',out=b'x'*1000000+b'\n')
            assert json.loads(kc(env,'--json','get',*(['x']*10000),status=1))['status']=='error'
            # A nested object reproduces the C client's substring-status bug.
            kc(env,'eval',"tag.new{name='nested',screen=screen.all()[1],probe={status='error'}}")
            assert json.loads(kc(env,'--json','get','tag','nested','probe'))['status']=='ok'
            specs=json.loads(kc(env,'--json','help'))['result']
            commands=kc(env,'commands').decode().splitlines()
            assert set(commands)=={x['name'] for x in specs}
            for spec in specs:
                kc(env,'help',spec['name'])
                n=sum(bool(a.get('required')) for a in spec['args'])
                if n:
                    error=kc(env,*spec['name'].split('.'),*(['x']*(n-1)),status=1)
                    assert spec['usage'].encode() in error,error
            assert b'web\n' in kc(env,'complete','3','get','tag','')
            assert b'toggle_fullscreen\n' in kc(env,'complete','4','call','client','focused','')
            kc(env,'notify','--title','--json','--timeout','1')
            assert b'--json' in kc(env,'get','notification','all','title')
            peer=Client(env)
            try:
                peer.toplevel('CLI one');peer.toplevel('CLI two');peer.pump(.2)
                assert len(json.loads(kc(env,'--json','client','list'))['result'])==2
                kc(env,'set','client','all','floating','true')
                assert all(x['value'] for x in json.loads(kc(env,'--json','get','client','all','floating'))['result'])
                kc(env,'call','client','focused','toggle_fullscreen')
                kc(env,'get','client','title:CLI','title')
                kc(env,'call','client','focused','swap','@client:previous')
            finally:peer.close()
            # The registry survives the same deferred reload and repair path as policy.
            (work/'rc.lua').write_text('error("cli reload failure")')
            kc(env,'reload');time.sleep(.1);kc(env,'ping',out=b'pong\n')
            (work/'rc.lua').write_text(CONFIG)
            kc(env,'reload');time.sleep(.1);kc(env,'tag','current',out=b'web\n')
            kc(env,'eval','kiln_ipc=nil')
            kc(env,'--json','ping',status=1)
            h.quit(server,env,log);h.quit(other,env2,log2)
        with h.boot('-- no library') as (server,env,work,log):
            kc(env,'--json','ping',status=1)
            h.quit(server,env,log)
        # Fragmentation and early closure use only owned temporary Unix sockets.
        for idx,(reply,as_json,status) in enumerate([
            (b'OK\nfirst\n\nlast\n',False,0),
            (b'{"result":{"status":"error"},"status":"ok"}\n',True,0),
            (b'ERROR: outer failure\n',True,1),(b'',False,2),
            (b'OK\n'+b'x'*200000,False,0),
        ]):
            path=h.out/f'peer-{idx}.sock';listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
            listener.bind(str(path));listener.listen();requests=[];errors=[]
            def peer():
                try:
                    conn,_=listener.accept()
                    with conn:
                        body=b''
                        while data:=conn.recv(31):body+=data
                        requests.append(body)
                        for offset in range(0,len(reply),17):conn.sendall(reply[offset:offset+17])
                except BaseException as e:errors.append(repr(e))
            thread=threading.Thread(target=peer);thread.start()
            kc(dict(os.environ,KILN_SOCK=str(path)),*(['--json'] if as_json else []),'ping',status=status,
               out=reply[3:] if status==0 and not as_json else reply if status==0 else None)
            thread.join(5);listener.close();path.unlink()
            assert not thread.is_alive() and not errors,errors
            assert requests==[b'return kiln_ipc("'+(b'--json ' if as_json else b'')+b'ping")'],requests
        path=h.out/'early.sock';listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);listener.bind(str(path));listener.listen()
        def close_early():
            conn,_=listener.accept();conn.close()
        thread=threading.Thread(target=close_early);thread.start()
        kc(dict(os.environ,KILN_SOCK=str(path)),'echoargs',*(['x'*10000]*100),status=2)
        thread.join(5);listener.close();path.unlink()
    finally:
        (h.out/'cli-streams.json').write_text(json.dumps(receipts,indent=2)+'\n')
    print('PASS: command registry/reflection/quoting, two sockets, reload/repair, JSON status, EOF/fragmentation/early close; receipts:',h.out)

if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-cli-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(ROOT/'build/kiln',c_baseline.source(),out))
