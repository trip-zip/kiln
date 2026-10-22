"""Layer protocol lifetimes, wire handshakes and Clay reservation publication."""
import c_baseline
import json
import subprocess
import time
from pathlib import Path
from PIL import Image
from declaration_checks import check, wait, settle, capture
from window_state_checks import launch, stop, counts
from protocol_client import Client, u

CONFIG='''
K=require('kiln'); LS=require('kiln.layers'); ui=K.ui
screen.on('added',function(s)
 tag.new{name='one',screen=s}
 ui.bar(s,{h=32,pad=0},function() ui.text('stock bar') end)
end)
'''

def run(h):
    with h.boot(CONFIG,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        c=Client(env);p,f=launch(env,work,'LAYER-FOOT');p2=f2=None
        def ev(src):check(h,env,'do '+src+' end',b'\n')
        def ready(src):wait(h,env,'return '+src,b'true\n',server)
        def answer_count():return sum('configure' in r for r in c.records)
        try:
            ready('#client.all()==1')
            p2,f2=launch(env,work,'SECOND-FOOT');ready('#client.all()==2')
            ev('s1,s2=unpack(screen.all());screen.focused=s1;C=client.all()[1];C:move_to(s1);for _,v in ipairs(client.all()) do if v~=C then v:move_to(s2) end end;screen.focused=s1')
            assert any(r.get('bind')=='zwlr_layer_shell_v1' and r['version']==4 for r in c.records)
            a=c.layer('top-one',output='HEADLESS-1',margin=(5,7,0,11))
            b=c.layer('top-two',output='HEADLESS-1',height=25,zone=25,color=0xffa04020)
            left=c.layer('left',output='HEADLESS-1',width=30,height=0,anchor=7,zone=30,margin=(2,0,3,4),band=1)
            bottom=c.layer('bottom',output='HEADLESS-1',height=20,anchor=14,zone=20,band=0)
            right=c.layer('right',output='HEADLESS-1',width=22,height=0,anchor=11,zone=22,band=3)
            ready('#LS.all==5 and LS.all[5].buffer_mapped')
            settle(log)
            ev('''for _,s in ipairs(screen.all()) do
              local w=s.workarea
              if s.name=='HEADLESS-1' then
                assert(w.x==34 and w.y==102 and w.width==1224 and w.height==598)
              else assert(w.x==0 and w.y==32 and w.width==1280 and w.height==688) end
            end
            assert(LS.all[1].w==1262 and LS.all[1].h==40 and LS.all[1].output=='HEADLESS-1')
            assert(LS.all[3].h==715 and LS.all[3].anchors.left and LS.all[3].margin.left==4)''')
            capture(env,work/'reserved.png')
            image=Image.open(work/'reserved.png').convert('RGB')
            for i in range(1,6):
                x,y=map(float,h.ev(env,f"local l=LS.all[{i}];local s=l.screen;core.hits(s.name,s.x,s.y);local b=core.box({{'layer',l.handle}});return s.x+b.x+b.width/2,s.y+b.y+b.height/2").split())
                actual=image.getpixel((int(x),int(y)))
                assert actual==((160,64,32) if i==2 else (32,160,96)),(i,x,y,actual)
            n=answer_count();before=counts(log)
            for _ in range(4):c.paint(a,*a['size']);c.pump(.05)
            assert answer_count()==n and counts(log)==before
            c.change(b,zone=0);settle(log)
            ev("assert(LS.all[2].screen.workarea.y==77)")
            c.change(b,zone=25,anchor=5,size=(100,25));settle(log)
            ev("assert(LS.all[2].screen.workarea.y==77)")
            c.change(b,anchor=13);settle(log)
            ev("assert(LS.all[2].screen.workarea.y==102)")
            loose=c.layer('unspecified',width=100,height=60,anchor=0,zone=-1,band=3)
            ready('#LS.all==6 and LS.all[6].buffer_mapped')
            ev("U=LS.all[6];assert(U.output==nil and U.screen==s1);core.hits(s1.name,s1.x,s1.y);local b=core.box({'layer',U.handle});assert(b.x==590 and b.y==330)")
            c.change(loose,zone=0);settle(log)
            ev("core.hits(s1.name,s1.x,s1.y);local b=core.box({'layer',U.handle});local w=s1.workarea;assert(b.x==math.floor(w.x+(w.width-100)/2+.5) and b.y==math.floor(w.y+(w.height-60)/2+.5))")
            # Remap retains the handle, while requiring a fresh configure/ack cycle.
            ev('A=LS.all[1];AH=A.handle')
            n=answer_count();c.unmap(a)
            ready('not A.mapped and not A.buffer_mapped')
            c.change(a,size=(0,40),anchor=13,zone=40,margin=(5,7,0,11))
            ready('A.mapped and A.buffer_mapped and A.handle==AH')
            assert answer_count()==n+1
            # An unanswered initial commit stays absent and diagnoses only once.
            ev("saved=K.defaults.layer;K.defaults.layer=function(l) if l.namespace=='unanswered' then error('unanswered layer policy') else saved(l) end end")
            missing=c.layer('unanswered',width=80,height=50,anchor=0,zone=0)
            ready('#LS.all==7')
            assert not missing.get('painted')
            time.sleep(3.2)
            assert log.read_text().count("surface 'unanswered'")==1
            ev("assert(not LS.all[7].buffer_mapped and LS.all[7].w==nil);K.defaults.layer=saved;LS.all[7]:emit('commit')")
            c.pump(.3);ready('LS.all[7].buffer_mapped')
            c.pump(.1);n=answer_count();time.sleep(.2);c.pump(.1);assert answer_count()==n
            # A declaration's configure must not escape a rejected candidate.
            capture(env,work/'before-failed.png')
            ev("failhook=K.on_declare(function() core.layer_configure(A.handle,300,70);error('layer candidate rejected') end);core.dirty()")
            settle(log);c.pump(.1);assert answer_count()==n
            capture(env,work/'failed.png')
            assert (work/'failed.png').read_bytes()==(work/'before-failed.png').read_bytes()
            ev('K.off_declare(failhook);core.dirty()');settle(log)
            # Numeric rejection precedes unsigned conversion; stale handles are inert.
            ev("for _,v in ipairs{-1,0/0,math.huge,1.5,4294967296} do assert(not pcall(core.layer_configure,A.handle,v,40)) end;core.layer_configure(999999,40,40)")
            ev("old=A;old:on('commit',function() OLD_LISTENER=true end);K.reload()")
            ready('#client.all()==2 and LS.all[1]==old and LS.all[1].buffer_mapped')
            c.pump(.2);settle(log)
            ev("assert(not OLD_LISTENER and require('kiln.object').lookup(AH)==old);old:emit('commit');assert(not OLD_LISTENER)")
            capture(env,work/'reloaded.png')
            original=(work/'rc.lua').read_text()
            (work/'rc.lua').write_text('invalid !!!')
            ev('K.reload()');c.pump(.2);settle(log)
            ev('assert(LS.all[1]==old and old.buffer_mapped)')
            (work/'rc.lua').write_text(original)
            ev('K.reload()');c.pump(.2);settle(log)
            ready('#client.all()==2 and LS.all[1]==old and old.buffer_mapped')
            for _ in range(4):
                item=c.layer('cycle',width=80,height=30,anchor=0,zone=0)
                c.unmap(item);c.destroy(item)
            ready('#LS.all==7')
            # Destroy before the queued initial map is dispatched cannot resurrect an object.
            c.batch=[]
            item=c.layer('early',width=80,height=30,anchor=0,zone=0,wait=False)
            c.send(item['role'],7);c.send(item['surface'],0);c.flush_batch();c.roundtrip()
            ready('#LS.all==7')
            assert not any(r.get('layer')==item['role'] and 'configure' in r for r in c.records)
            wallpaper=c.layer('wallpaper',output='HEADLESS-2',width=0,height=0,anchor=15,zone=-1,band=0,color=0xff132537)
            ready('#LS.all==8 and LS.all[8].buffer_mapped');settle(log)
            capture(env,work/'background-top-overlay.png')
            image=Image.open(work/'background-top-overlay.png').convert('RGB')
            x,y=map(int,h.ev(env,"local s=LS.all[8].screen;return s.x+2,s.y+40").split())
            assert image.getpixel((x,y))==(19,37,55)
            c.destroy(wallpaper);ready('#LS.all==7')
            def resources():
                settle(log)
                return {'fds':len(list(Path('/proc',str(server.pid),'fd').iterdir())),
                        'lua':h.ev(env,"collectgarbage('collect');local n=0;for k,v in pairs(debug.getregistry()) do if type(k)=='number' and type(v)=='function' then n=n+1 end end;return n,#LS.all").decode().strip()}
            # Compare identical surviving native owners, not caches keyed by new handles.
            before=resources()
            for _ in range(8):
                c.unmap(a);c.change(a,size=(0,40),anchor=13,zone=40,margin=(5,7,0,11))
                ev('K.reload()');c.pump(.15)
            ready('#LS.all==7 and old.buffer_mapped and #client.all()==2')
            after=resources()
            assert before==after,(before,after)
            (work/'resources.json').write_text(json.dumps({'before':before,'after':after},indent=2)+'\n')
            (work/'wire.json').write_text(json.dumps(c.records,indent=2)+'\n')
            stop(p);f.close()
            h.quit(server,env,log)
        finally:
            c.close();stop(p)
            if not f.closed:f.close()
            if p2 is not None:stop(p2);f2.close()
    print('PASS: layer wire handshake, reservations, remap, policy failure, declaration rejection and reload')

if __name__=='__main__':
    import importlib.util,tempfile
    from pathlib import Path
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-layer-checks-',dir='/tmp'))
    print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
