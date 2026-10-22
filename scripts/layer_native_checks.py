"""Real layer input and keyboard arbitration on a private X11 backend."""
import c_baseline
import json
import subprocess
import time
from contextlib import contextmanager
from declaration_checks import check, wait, settle, capture
from policy_checks import private_x11
from window_state_checks import launch,stop
from protocol_client import Client
from layer_checks import CONFIG


@contextmanager
def window_manager_atoms(display):
    """wlroots only looks up existing atoms; keep this private server alive."""
    import ctypes as ct
    x=ct.CDLL('libX11.so.6')
    x.XOpenDisplay.argtypes=[ct.c_char_p];x.XOpenDisplay.restype=ct.c_void_p
    x.XInternAtom.argtypes=[ct.c_void_p,ct.c_char_p,ct.c_int];x.XInternAtom.restype=ct.c_ulong
    x.XCloseDisplay.argtypes=[ct.c_void_p]
    connection=x.XOpenDisplay(display.encode());assert connection
    try:
        for name in (b'WM_PROTOCOLS',b'WM_DELETE_WINDOW',b'_NET_WM_NAME',b'UTF8_STRING',b'_VARIABLE_REFRESH'):
            assert x.XInternAtom(connection,name,0)
        yield
    finally:x.XCloseDisplay(connection)


def close_output(display,window):
    """Send WM_DELETE_WINDOW to one owned backend window, not a host output."""
    import ctypes as ct
    class Message(ct.Structure):
        _fields_=[('type',ct.c_int),('serial',ct.c_ulong),('send_event',ct.c_int),
                  ('display',ct.c_void_p),('window',ct.c_ulong),('message_type',ct.c_ulong),
                  ('format',ct.c_int),('data',ct.c_long*5)]
    class Event(ct.Union):
        _fields_=[('message',Message),('padding',ct.c_long*24)]
    assert ct.sizeof(Message)==96 and ct.alignment(Message)==8 and ct.sizeof(Event)==192
    assert [getattr(Message,k).offset for k,_ in Message._fields_]==[0,8,16,24,32,40,48,56]
    x=ct.CDLL('libX11.so.6')
    x.XOpenDisplay.argtypes=[ct.c_char_p];x.XOpenDisplay.restype=ct.c_void_p
    x.XInternAtom.argtypes=[ct.c_void_p,ct.c_char_p,ct.c_int];x.XInternAtom.restype=ct.c_ulong
    x.XSendEvent.argtypes=[ct.c_void_p,ct.c_ulong,ct.c_int,ct.c_long,ct.POINTER(Event)]
    x.XFlush.argtypes=[ct.c_void_p];x.XCloseDisplay.argtypes=[ct.c_void_p]
    connection=x.XOpenDisplay(display.encode());assert connection
    try:
        event=Event();m=event.message
        m.type=33;m.send_event=1;m.display=connection;m.window=window;m.format=32
        m.message_type=x.XInternAtom(connection,b'WM_PROTOCOLS',0)
        m.data[0]=x.XInternAtom(connection,b'WM_DELETE_WINDOW',0)
        assert x.XSendEvent(connection,window,0,0,ct.byref(event))
        x.XFlush(connection)
    finally:x.XCloseDisplay(connection)


def removal(h):
    with private_x11(h.out) as display, window_manager_atoms(display):
        with h.boot(CONFIG,overrides={'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2',
                                    'DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            c=Client(env)
            def ev(src):check(h,env,'do '+src+' end',b'\n')
            def yes(src):wait(h,env,'return '+src,b'true\n',server)
            try:
                yes('#screen.all()==2')
                ev("for _,s in ipairs(screen.all()) do if s.name=='X11-1' then screen.focused=s end end")
                explicit=c.layer('explicit-removal',output='X11-1',width=160,height=40,zone=40)
                selected=c.layer('selected-removal',width=170,height=50,zone=50)
                child=c.popup(explicit);other=c.popup(selected)
                yes('#LS.all==2 and LS.all[2].buffer_mapped')
                ev("L=LS.all[2];LH=L.handle;assert(L.screen.name=='X11-1' and L.output==nil)")
                windows=subprocess.check_output(['xdotool','search','--name',''],env=env).splitlines()
                # Root plus two private backend windows, in creation order.
                # The postcondition checks which output was actually removed.
                assert len(windows)==3,windows
                window=int(windows[-2])
                close_output(display,window);c.pump(.4);settle(log);c.pump(.2)
                yes("#screen.all()==1 and #LS.all==1 and LS.all[1]==L and L.handle==LH and L.screen.name=='X11-2' and L.buffer_mapped")
                assert explicit.get('closed') and child.get('done')
                assert not selected.get('closed') and not other.get('done')
                capture(env,work/'output-removal.png')
                (work/'removal-wire.json').write_text(json.dumps(c.records,indent=2)+'\n')
                h.quit(server,env,log)
            finally:c.close()
    print('PASS: synthetic X11 output removal closes explicit layers and preserves compositor-selected owners/popups')

def run(h):
    with private_x11(h.out) as display:
        with h.boot(CONFIG,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            c=Client(env);p,f=launch(env,work,'LAYER-INPUT')
            def ev(src):check(h,env,'do '+src+' end',b'\n')
            def yes(src):wait(h,env,'return '+src,b'true\n',server)
            def keys(start):return [r for r in c.records[start:] if r.get('input')=='keyboard' and r['op']==3]
            def xdo(*args):
                subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);c.pump(.1)
            def point(meta):
                index=c.surfaces.index(meta)+1
                # Layer fixtures precede any protocol toplevels in this test.
                x,y=map(float,h.ev(env,f"local l=LS.all[{index}];core.hits(l.screen.name,l.screen.x,l.screen.y);local b=core.box({{'layer',l.handle}});return b.x+b.width/2,b.y+b.height/2").split())
                xdo('mousemove','--window',win,int(x),int(y))
            try:
                yes('#client.all()==1');ev('C=client.all()[1]');yes('core.client.focused()==C.handle')
                win=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1]
                xdo('windowfocus',win)
                a=c.layer('none',width=260,height=70,zone=70)
                yes('#LS.all==1 and LS.all[1].buffer_mapped');settle(log)
                point(a);start=len(c.records);xdo('click',1)
                assert any(r.get('input')=='pointer' and r['op']==3 for r in c.records[start:])
                yes('core.client.focused()==C.handle')
                child=c.subsurface(a)
                lx,ly=map(float,h.ev(env,"local l=LS.all[1];core.hits(l.screen.name,0,0);local b=core.box({'layer',l.handle});return b.x,b.y").split())
                xdo('mousemove','--window',win,int(lx+30),int(ly+20));start=len(c.records);xdo('click',1)
                enters=[r for r in c.records if r.get('input')=='pointer' and r['op']==0]
                assert enters[-1]['words'][1]==child['surface']
                assert len([r for r in c.records[start:] if r.get('input')=='pointer' and r['op']==3])==2
                start=len(c.records);xdo('key','F6');assert not keys(start)
                c.change(a,keyboard=2);yes('core.client.focused()==C.handle')
                c.change(a,keyboard=1);yes('core.client.focused()==LS.all[1].handle')
                start=len(c.records);xdo('key','F6');assert len(keys(start))==2
                b=c.layer('exclusive-two',width=240,height=60,anchor=14,zone=60,keyboard=1,color=0xffb06020)
                yes('#LS.all==2 and core.client.focused()==LS.all[2].handle')
                c.change(a,keyboard=0);yes('core.client.focused()==LS.all[2].handle')
                c.change(a,keyboard=1);yes('core.client.focused()==LS.all[2].handle')
                c.unmap(b);yes('core.client.focused()==LS.all[1].handle')
                # Temporary Lua claims quarantine held releases and restore the layer.
                start=len(c.records)
                ev("G=K.keygrabber{key=function() end}")
                xdo('keydown','F7');ev('G:stop()');xdo('keyup','F7')
                assert not keys(start)
                yes('core.client.focused()==LS.all[1].handle')
                start=len(c.records);xdo('key','F8');assert len(keys(start))==2
                ev("old=LS.all[1];K.reload()")
                yes('LS.all[1]==old and core.client.focused()==old.handle and #client.all()==1')
                c.pump(.2)
                start=len(c.records);xdo('key','F9');assert len(keys(start))==2
                c.change(a,keyboard=0);yes('core.client.focused()==client.all()[1].handle')
                # Replaceable policy may explicitly grant on-demand focus.
                ev("K.defaults.layer_keyboard=function(l) l.kb_granted=l.interactivity=='on_demand';if l.kb_granted then core.client.focus(l.handle) end end")
                c.change(a,keyboard=2);yes('core.client.focused()==old.handle')
                start=len(c.records);xdo('key','F10');assert len(keys(start))==2
                capture(env,work/'layer-native.png')
                stop(p);f.close();yes('#client.all()==0 and core.client.focused()==old.handle')
                p,f=launch(env,work,'LAYER-INPUT')
                yes('#client.all()==1 and core.client.focused()==old.handle')
                c.unmap(a);yes('core.client.focused()==client.all()[1].handle')
                before=(work/'LAYER-INPUT.log').read_text();xdo('key','F11')
                after=(work/'LAYER-INPUT.log').read_text()[len(before):]
                assert 'wl_keyboard' in after and '.key(' in after,after
                c.destroy(a);c.destroy(b);yes('#LS.all==0')
                (work/'input-wire.json').write_text(json.dumps(c.records,indent=2)+'\n')
                h.quit(server,env,log)
            finally:c.close();stop(p);f.close()
    print('PASS: native layer pointer, none/on-demand/exclusive, contenders, Lua claims, reload and client restoration')
    removal(h)

if __name__=='__main__':
    import importlib.util,tempfile
    from pathlib import Path
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-layer-input-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
