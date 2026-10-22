"""Two-protocol bridge receipts; a required unsupported direction stays red."""
import c_baseline
import hashlib
import json
import struct
import time
from pathlib import Path
from declaration_checks import check, wait, settle, capture
from policy_checks import private_x11
from protocol_client import Client, string
from x11_client import XClient, u
from xwayland_checks import dependencies, xcommand, server_pids, until as process_until

CONFIG='''
K=require('kiln'); ui=K.ui
screen.on('added',function(s)
 tag.new{name='one',screen=s}
 ui.bar(s,{h=32,pad=0},function() ui.text('bridge control') end)
end)
'''


class SelectionClient(XClient):
    def __init__(self,display):
        super().__init__(display);self.selections={};self.transfers={};self.incr=[];self.pause_incr=False
        for name in ('TARGETS','ATOM','UTF8_STRING','TEXT','application/x-kiln-bytes','XdndSelection','CLIPBOARD','PRIMARY','KILN_TRANSFER'):
            self.atom(name)

    def selection_request(self,r):
        payloads=self.selections.get(r['selection'],{})
        prop=r['property'] or r['target'];target=r['target']
        if target==self.atom('TARGETS'):data=u(self.atom('TARGETS'),*payloads);kind=self.atom('ATOM');bits=32
        elif target in payloads:data=payloads[target];kind=target;bits=8
        else:data=None;kind=target;bits=8;prop=0
        if data is not None and len(data)>65536:
            self.send(2,u(r['requestor'],1<<11,(1<<22)|(1<<17)))
            record=dict(direction='send',bytes=len(data),window=r['requestor'],chunks=[])
            self.transfers[(r['requestor'],prop)]=[data,0,target,record]
            self.incr.append(record)
            data=u(len(data));kind=self.atom('INCR');bits=32
        if data is not None:
            self.send(18,u(r['requestor'],prop,kind)+struct.pack('<B3xI',bits,len(data)//(bits//8))+data)
        event=struct.pack('<BBH5I8x',31,0,0,r['time'],r['requestor'],r['selection'],target,prop)
        self.send(25,u(r['requestor'],0)+event)

    def property_notify(self,r):
        key=(r['window'],r['property'])
        if r['state']!=1 or key not in self.transfers:return
        if self.pause_incr:return
        data,offset,target,record=self.transfers[key];chunk=data[offset:offset+32768]
        self.send(18,u(*key,target)+struct.pack('<B3xI',8,len(chunk))+chunk)
        record['chunks'].append(len(chunk))
        if chunk:self.transfers[key][1]+=len(chunk)
        else:del self.transfers[key]

    def window_destroyed(self,r):
        for key in list(self.transfers):
            if key[0]==r['window']:
                self.transfers.pop(key)[3]['requestor_destroyed']=True

    def own(self,window,selection,payloads):
        atom=self.atom(selection);self.selections[atom]={self.atom(k):v for k,v in payloads.items()}
        self.send(22,u(window,atom,0));self.sync()

    def owner(self,selection):return struct.unpack_from('<I',self.reply(self.send(23,u(self.atom(selection)))),8)[0]

    def receive(self,window,selection,target,pump,slow=False,pending=False):
        start=0 if pending else len(self.records);prop=self.atom('KILN_TRANSFER')
        if not pending:self.send(24,u(window,self.atom(selection),self.atom(target),prop,0))
        end=time.monotonic()+5
        while time.monotonic()<end:
            pump()
            found=[r for r in self.records[start:] if r['event']==31 and r['requestor']==window]
            if found:
                if found[-1]['property']==0:return None
                kind,bits,after,data=self.get_property(window,'KILN_TRANSFER',delete=True)
                assert not after
                if kind==self.atom('INCR'):
                    record=dict(direction='receive',advertised=struct.unpack('<I',data)[0],chunks=[]);self.incr.append(record)
                    result=b'';deadline=time.monotonic()+20
                    while time.monotonic()<deadline:
                        pump()
                        kind,bits,after,data=self.get_property(window,'KILN_TRANSFER')
                        if not kind:continue
                        assert bits==8 and not after
                        if slow:time.sleep(.02)
                        self.delete_property(window,'KILN_TRANSFER');record['chunks'].append(len(data))
                        if not data:return result
                        result+=data
                    raise AssertionError('INCR did not terminate')
                return data
        raise AssertionError('X selection response timed out')


def verified_dependency(server,inner):
    paths={line.split()[-1] for line in Path(f'/proc/{server.pid}/maps').read_text().splitlines() if 'libwlroots-0.20.so' in line}
    assert len(paths)==1,paths
    pids=server_pids(inner);assert len(pids)==1,pids
    executable=Path(f'/proc/{pids[0]}/exe').resolve()
    identities={str(next(iter(paths))):'7edca9a7d65855addda68e29ba5db94d57c803eb5fa7d0f86db3136b90ca9837',
                str(executable):'34c7f25b5e6a8dd5b52090e82f6f5e73140554b1423103b2f918b2a56ec7c460'}
    for path,expected in identities.items():
        assert hashlib.sha256(Path(path).read_bytes()).hexdigest()==expected,('review shared selection/DnD classifications after dependency change',path)
    return identities


def run(h,known_limitation=False):
    dependencies()
    with private_x11(h.out) as outer:
        with h.boot(CONFIG+"\nSTARTS=0;drag.on('start',function()STARTS=STARTS+1 end)",overrides={'DISPLAY':outer,'WAYLAND_DISPLAY':None,'WLR_BACKENDS':'x11','WAYLAND_DEBUG':'server'}) as (server,env,work,log):
            dependency=None
            inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip();x=SelectionClient(inner);n=Client(env);proof=[]
            def ev(s):check(h,env,'do '+s+' end',b'\n')
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            def pump():x.pump(.05);n.pump(.05)
            def xdo(*args):xcommand(env,'xdotool',*args);pump()
            def point(name):
                bx,by=map(float,h.ev(env,"core.hits("+name+".screen.name,0,0);local b=core.box({'core.surface',"+name+".handle});return b.x+60,b.y+60").split())
                xdo('mousemove','--window',win,int(bx),int(by));return int(bx),int(by)
            def serial():return [r for r in n.records if r.get('input')=='pointer' and r['op']==3][-1]['words'][0]
            def receipt(direction,selection,mime,data):proof.append(dict(direction=direction,selection=selection,mime=mime,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
            def messages(name,start=0):return [r for r in x.records[start:] if r['event']==33 and r['type']==x.atom(name)]
            def until(predicate,label,seconds=4):
                end=time.monotonic()+seconds
                while time.monotonic()<end:
                    pump()
                    if predicate():return
                raise AssertionError(label)
            try:
                w=x.create(title='X bridge',instance='bridge');a=n.toplevel('native-bridge');pump();yes('#client.all()==2')
                dependency=verified_dependency(server,inner) if known_limitation else None
                ev("for _,c in ipairs(client.all())do if c.instance=='bridge' then X=c else N=c end end")
                win=xcommand(env,'xdotool','search','--name','').decode().splitlines()[-1];xdo('windowfocus',win)
                for primary in (False,True):n.data_device(primary)
                # Both selections coexist; UTF-8, binary and empty payloads have exact receipts.
                for payload in ('bridge snowman ☃\n'.encode(),b'',b'replacement\0bytes'):
                    point('N');xdo('click',1)
                    for primary in (False,True):
                        data=payload+(b' primary' if primary and payload else b'')
                        source=n.data_source({'text/plain;charset=utf-8':data,'application/x-kiln-bytes':b'\0\xff\x80\n'},primary)
                        n.selection(source,serial(),primary)
                    ev('X:focus()');pump()
                    targets_before=len([r for r in x.records if r['event']==30 and r['target']==x.atom('TARGETS')])
                    for primary in (False,True):
                        selection='PRIMARY' if primary else 'CLIPBOARD';data=payload+(b' primary' if primary and payload else b'')
                        for target,expected in [('UTF8_STRING',data),('application/x-kiln-bytes',b'\0\xff\x80\n')]:
                            actual=x.receive(w,selection,target,pump);assert actual==expected,(selection,target,actual,expected)
                            receipt('Wayland->X11',selection,target,actual)
                        assert x.receive(w,selection,'application/x-unsupported',pump) is None
                    ev('X:focus()');pump()
                    for primary in (False,True):
                        data=payload+(b' primary' if primary and payload else b'')
                        x.own(w,'PRIMARY' if primary else 'CLIPBOARD',{'UTF8_STRING':data,'application/x-kiln-bytes':b'\0\xff\x80\n'})
                    until(lambda:len([r for r in x.records if r['event']==30 and r['target']==x.atom('TARGETS')])>=targets_before+2,'TARGETS requests')
                    pump();ev('N:focus()');pump()
                    for primary in (False,True):
                        _,target=n.data_device(primary);offer=target.get('selection');assert offer,target
                        data=payload+(b' primary' if primary and payload else b'')
                        for mime,expected in [('text/plain;charset=utf-8',data),('application/x-kiln-bytes',b'\0\xff\x80\n')]:
                            actual=n.receive(offer,mime,x);assert actual==expected,(mime,actual,expected)
                            receipt('X11->Wayland','PRIMARY' if primary else 'CLIPBOARD',mime,actual)
                (work/'selection-receipts.json').write_text(json.dumps(proof,indent=2)+'\n')
                print('PASS: small clipboard/primary both directions, simultaneous selections, UTF-8/binary/empty/replacement exact bytes and native-to-X unsupported target refusal',flush=True)
                # Native source to real Xdnd target, with outer input and an actual byte request.
                x.prop(w,'XdndAware','ATOM',u(5),32);x.sync()
                point('N');xdo('mousedown',1)
                payload=b'cross protocol drag\0\n';source=n.data_source({'text/plain;charset=utf-8':payload},actions=1)
                icon=n.start_drag(source,a,serial());pump();point('X')
                until(lambda:bool(messages('XdndEnter')),'Wayland->X11 XdndEnter')
                proxy=messages('XdndEnter')[-1]['data'][0]
                x.message(proxy,'XdndStatus',[w,1,0,0,x.atom('XdndActionCopy')],destination=proxy,mask=0)
                until(lambda:n.objects[source][1].get('action')==1,'copy negotiation')
                actual=x.receive(w,'XdndSelection','UTF8_STRING',pump);assert actual==payload;receipt('Wayland->X11','XdndSelection','UTF8_STRING',actual)
                capture(env,work/'native-to-x-drag.png')
                xdo('mouseup',1);until(lambda:bool(messages('XdndDrop')),'X drop')
                x.message(proxy,'XdndFinished',[w,1,x.atom('XdndActionCopy')],destination=proxy,mask=0)
                until(lambda:n.objects[source][1].get('finished'),'Wayland source finished')
                n.send(icon['surface'],0);n.roundtrip();pump()
                print('PASS: Wayland->X11 Xdnd v5 copy, exact UTF-8 target bytes, drop/finished and native source completion',flush=True)
                # Reverse direction. The public proxy is known from the completed
                # opposite-direction exchange, not from private XWM storage.
                _,target=n.data_device();target.pop('enter',None);target.pop('dropped',None)
                before_fds=len(list(Path(f'/proc/{server.pid}/fd').iterdir()))
                point('X');press_start=len(x.records);xdo('mousedown',1)
                assert any(r['event']==4 and r['window']==w and not r['synthetic'] for r in x.records[press_start:]),'no real X source press'
                x.own(w,'XdndSelection',{'UTF8_STRING':b'X to Wayland required\n'});assert x.owner('XdndSelection')==w
                pump();tx,ty=point('N');ns=len(n.records);xs=len(x.records)
                x.message(proxy,'XdndEnter',[w,5<<24,x.atom('UTF8_STRING')],destination=proxy,mask=0)
                x.message(proxy,'XdndPosition',[w,0,(tx<<16)|ty,0,x.atom('XdndActionCopy')],destination=proxy,mask=0)
                deadline=time.monotonic()+2
                while time.monotonic()<deadline and not target.get('enter'):pump()
                enter=target.get('enter');received=None
                if enter:
                    offer=enter[-1]
                    n.send(offer,0,u(enter[0])+string('text/plain;charset=utf-8'));n.send(offer,4,u(1,1));n.roundtrip();pump()
                    received=n.receive(offer,'text/plain;charset=utf-8',x)
                    assert received==b'X to Wayland required\n'
                    assert n.objects[offer][1].get('action')==1
                capture(env,work/'x-to-native-required.png')
                xdo('mouseup',1)
                x.message(proxy,'XdndDrop',[w,0,0],destination=proxy,mask=0);pump()
                if enter:
                    until(lambda:target.get('dropped'),'reverse drop');n.send(offer,3);n.roundtrip()
                    until(lambda:bool(messages('XdndFinished',xs)),'reverse finished')
                result=dict(outer=outer,inner=inner,source=w,proxy=proxy,version=5,target='UTF8_STRING -> text/plain;charset=utf-8',action='XdndActionCopy',owner=x.owner('XdndSelection'),native_enter=enter,native_drop=target.get('dropped',False),received_bytes=len(received) if received is not None else None,status=messages('XdndStatus',xs),starts=h.ev(env,'return STARTS').decode().strip(),receipts=proof,x=x.records,native=n.records,reverse_native=n.records[ns:])
                (work/'bridge-receipts.json').write_text(json.dumps(result,indent=2)+'\n')
                x.own(0,'XdndSelection',{});pump();assert x.owner('XdndSelection')==0
                after_fds=len(list(Path(f'/proc/{server.pid}/fd').iterdir()))
                assert before_fds==after_fds,('incoming DnD leaked FDs',before_fds,after_fds)
                h.healthy(env);h.quit(server,env,log)
                process_until(lambda:not server_pids(inner),'owned X server survived bridge shutdown')
                assert not Path('/tmp/.X11-unix/X'+inner[1:]).exists()
                if known_limitation:
                    assert result['native_enter'] is None and not result['native_drop'] and result['received_bytes'] is None and not result['status'] and result['starts']=='1',('review changed incoming DnD behavior',result)
                    if h.implementation=='odin':
                        for line in ('Protocol cleanup: layers 0, popups 0','Interaction cleanup: trusted tokens 0, constraints 0, drag false','Input cleanup: keyboards 0, pointers 0, keyboard claim false, pointer claim false','Paint cleanup: live buffers 0, live bytes 0'):
                            assert line in log.read_text(),line
                    (work/'unsupported.json').write_text(json.dumps(dict(outcome='UNSUPPORTED',direction='X11->Wayland DnD',dependency=dependency,c_baseline='82ad185fad98bcebf191df047494a9561ffb043b',owner_cleared=True,responsive=True,clean_exit=True,fds_before=before_fds,fds_after=after_fds),indent=2)+'\n')
                    print('UNSUPPORTED: X11->Wayland DnD on verified wlroots 0.20.2 / XWayland 24.1.14; shared C/Odin baseline, bounded missing offer, owner release and clean shutdown. Strict capability probe remains red.',flush=True)
                else:
                    assert result['native_enter'] and result['native_drop'],('REQUIRED BRIDGE BLOCKER: X11->Wayland Xdnd v5 UTF8_STRING/copy produced no native offer/drop; wlroots 0.20.2 selection/incoming.c has a DND TODO and selection/dnd.c handles only Status/Finished; receipts',str(work/'bridge-receipts.json'))
            finally:x.close();n.close()


if __name__=='__main__':
    import argparse,importlib.util,tempfile
    parser=argparse.ArgumentParser()
    parser.add_argument('--binary',type=Path,default=Path(__file__).resolve().parents[1]/'build/kiln')
    parser.add_argument('--original',type=Path,default=c_baseline.source())
    parser.add_argument('--implementation',choices=('odin','c'),default='odin')
    parser.add_argument('--known-limitation',action='store_true')
    args=parser.parse_args()
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-xbridge-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(args.binary,args.original,out,implementation=args.implementation),known_limitation=args.known_limitation)
