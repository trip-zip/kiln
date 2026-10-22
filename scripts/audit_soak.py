"""Bounded combined workload using the existing private-display harness."""
import c_baseline
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import time
from authentication_checks import fixture
from dbus_checks import private_bus,peer,notify,close,control
from policy_checks import private_x11
from xwayland_scenario import Scenario,CONFIG
from output_fixture import LUA
from protocol_client import Client
from x11_client import XClient
from window_state_checks import launch,stop
from declaration_checks import settle
from lock_lifecycle_checks import covered
from paint_checks import stats

ROOT=Path(__file__).resolve().parents[1]
EXTRA='''
jit.off();jit.flush()
screen.on('added',function(s)tag.new{name='two',screen=s}end)
K.key{mods={},key='F8',press=function() NATIVE_KEYS=(NATIVE_KEYS or 0)+1 end}
'''


def run(h,cycles=10,seconds=600):
    assert cycles>=1 and seconds>=0
    suite=fixture(h);config=CONFIG+LUA+EXTRA
    samples=[];rounds=[];pending=None
    with private_bus(h.out/'bus') as (address,bus),private_x11(h.out) as outer:
        with suite.boot(config,overrides={'DISPLAY':outer,'WAYLAND_DISPLAY':None,'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2','DBUS_SESSION_BUS_ADDRESS':address,'KILN_IMAGE_BUDGET_MB':'8'}) as (server,env,work,log):
            s=Scenario(suite,server,env,work,log,config)
            foot,f=launch(env,work,'AUDIT-FOOT')
            started=time.monotonic()
            try:
                s.wait('#client.all()==3');s.ev('NH=N.handle;T.scale=1.3;core.output.set_position(T.name,-1001,77)')
                s.shot('initial-both-outputs')
                def shot(label):
                    path=work/(label+'.png')
                    key=s.val('core.screenshot(S.name,'+json.dumps(str(path))+')').decode().strip()
                    assert key.startswith('screenshot:'),key
                    s.ev('core.image_reload('+json.dumps(key)+')')
                def active_round():
                    s.ev('PIPE_DONE=false;TIMER_DONE=false;K.spawn.pipe({"sh","-c","printf audit"},{on_line=function(v)assert(v=="audit")end,on_exit=function(code)assert(code==0);PIPE_DONE=true end});K.timer(10,function()TIMER_DONE=true end);K.animation.start(S.name,"audit",1,.08,0);N.maximized=not N.maximized')
                    s.wait('PIPE_DONE and TIMER_DONE and resource_fixture(27)==0')
                    s.x.paint(s.w);s.pump(.1)
                    shot('active-latest')
                for cycle in range(cycles):
                    deadline=started+seconds*(cycle+1)/cycles
                    count=0
                    s.pick();s.ev('N:move_to(S);X:move_to(T);N.maximized=false;N.fullscreen=false;N.minimized=false;S.tags[1]:view();T.tags[1]:view()')
                    s.click('N');s.xdo('key','F8');s.wait('(NATIVE_KEYS or 0)>0')
                    s.ev('S.tags[2]:view()');s.pump(.2);s.ev('S.tags[1]:view();S.tags[1].layout=K.layout.fair');s.pump(.2)
                    s.ev('N.fullscreen=true');s.pump(.1);s.ev('N.fullscreen=false;N.minimized=true');s.pump(.1);s.ev('N.minimized=false;S.tags[1].layout=K.layout.tile')
                    # Ephemeral clients, layer and popup retire inside the same server lifetime.
                    temporary=Client(env);tx=XClient(s.inner)
                    try:
                        temporary.toplevel('audit-temporary');tx.create(instance='audit-temporary-x');s.wait('#client.all()==5')
                        layer=temporary.layer('audit-layer',output='X11-1',height=20,zone=20)
                        popup=s.n.popup(s.a,size=(90,60));s.pump(.15);shot(f'popup-{cycle}')
                        s.n.destroy_xdg(popup);temporary.destroy(layer)
                    finally:temporary.close();tx.close()
                    s.wait('#client.all()==3 and #require("kiln.layers").all==0')
                    s.focus('X');payload=b'audit supported clipboard\x00\xff'
                    s.x.own(s.w,'CLIPBOARD',{'application/x-kiln-bytes':payload});s.pump();s.focus('N')
                    offer=s.n.data_device()[1]['selection']
                    assert s.n.receive(offer,'application/x-kiln-bytes',s.x)==payload
                    s.click('N');source=s.n.data_source({'text/plain;charset=utf-8':b'audit outgoing'})
                    s.n.selection(source,s.serial());s.pump();s.focus('X')
                    assert s.x.receive(s.w,'CLIPBOARD','UTF8_STRING',s.pump)==b'audit outgoing'
                    s.rows.append(dict(cycle=cycle,incoming_bytes=len(payload),incoming_sha256=hashlib.sha256(payload).hexdigest(),outgoing_bytes=len(b'audit outgoing'),outgoing_sha256=hashlib.sha256(b'audit outgoing').hexdigest(),native_keys=int(s.val('NATIVE_KEYS'))))
                    s.n.send(source,1);s.n.roundtrip();s.pump()
                    with peer(env,work,'org.ktest.Audit') as (_,marker):
                        s.wait('#K.systray.items()==1')
                        nid=notify(env,title='Audit cycle',timeout=0)
                        control(env,'org.ktest.Audit','SetTitle','cycle '+str(cycle));s.wait('K.systray.items()[1].title=="cycle '+str(cycle)+'"')
                        s.ev('core.inspector(S.name,true);core.inspector(T.name,true)');s.pump(.2)
                        win=s.windows[s.val('S.name').decode().strip()]
                        s.xdo('mousemove','--window',win,850,75,'click',1);s.xdo('click',5)
                        shot(f'inspector-{cycle}')
                        pending=suite.connect(env,b'-- pending audit',eof=False)
                        s.reload(True);s.reload();s.wait('#client.all()==3 and N.handle==NH')
                        shot(f'repaired-{cycle}')
                        s.ev('core.inspector(S.name,false);core.inspector(T.name,false)')
                        s.ev('assert(core.lock());core.authenticate("fixture-success")')
                        s.wait('core._lock_state().authenticated')
                        covered(env,work/f'locked-{cycle}.png')
                        s.ev('assert(core.unlock())');s.wait('not K.lockscreen.active')
                        close(env,nid);s.wait('#notification.all()==0')
                    s.wait('#K.systray.items()==0')
                    s.ev('assert(output_fixture(1,T.name))');s.pump();s.wait('#screen.all()==1')
                    s.ev('assert(output_fixture(3,""))');s.pump();s.wait('#screen.all()==2');s.pick();s.refresh_windows()
                    s.ev('T.scale=1.3;core.output.set_position(T.name,-1001,77);X:move_to(T);N:move_to(S)')
                    pending.close();pending=None
                    # Time is occupied by real commands, timers, animation, client repaint and readback.
                    while count<2 or time.monotonic()<deadline:
                        assert time.monotonic()-started<max(seconds+180,180),'soak deadline'
                        active_round();count+=1
                    s.ev('N.maximized=false;K.animation.reset();collectgarbage("collect");core.dirty()');s.pump(.25);settle(log)
                    s.ev('collectgarbage("collect");core.dirty()');s.pump(.1);settle(log)
                    paint=[stats(log,n) for n in s.val('S.name,T.name').decode().split()]
                    assert all(v[:2]==(0,0) for v in paint),paint
                    before=log.read_text().count('Layout ');s.pump(.3)
                    assert log.read_text().count('Layout ')==before,'static scene kept solving'
                    kinds=[0,1,2,3,4,5,6,7,9,10,11,13,14,15,17,18,20,21,22,23,24,25,26,27,28,29]
                    values=list(map(int,s.val(','.join('resource_fixture('+str(k)+')' for k in kinds)).split()))
                    resources=dict(zip(map(str,kinds),values))
                    for k in [0,1,2,3,4,6,7,9,10,11,13,14,15,22,23,24,27,28,29]:assert resources[str(k)]==0,resources
                    refs,heap=map(float,s.val('(function()local n=0;for k,v in pairs(debug.getregistry())do if type(k)=="number" and type(v)=="function"then n=n+1 end end;return n end)(),collectgarbage("count")').split())
                    status=Path(f'/proc/{server.pid}/status').read_text()
                    memory={line.split(':')[0]:line.split(':')[1].strip() for line in status.splitlines() if line.startswith(('VmRSS:','VmHWM:'))}
                    children=Path(f'/proc/{server.pid}/task/{server.pid}/children').read_text().split()
                    samples.append(dict(cycle=cycle,fds=s.fds(),refs=refs,resources=resources,heap_kib=heap,memory=memory,children=children))
                    rounds.append(dict(cycle=cycle,active_rounds=count,elapsed=time.monotonic()-started))
                    (work/'audit-soak.json').write_text(json.dumps(dict(samples=samples,rounds=rounds,auth='compile-time fixture',output='private synthetic X11 backend',known_defective_transfers='excluded',idle_seconds=.3),indent=2)+'\n')
                    print('audit cycle',cycle+1,'rounds',count,'elapsed',round(time.monotonic()-started,1),'fds',s.fds(),flush=True)
                settled=samples[1:] or samples
                assert len({v['fds'] for v in settled})==1,settled
                assert len({v['refs'] for v in settled})==1,settled
                assert all(v['resources']==settled[0]['resources'] for v in settled),settled
                assert all(v['children']==settled[0]['children'] for v in settled),settled
                assert settled[-1]['heap_kib']-settled[0]['heap_kib']<2048,settled
                shot('final-desktop')
                s.shot('final-both-outputs')
                pending=suite.connect(env,b'-- pending shutdown',eof=False)
                s.ev('K.timer(10000,function()error("retired shutdown callback")end)')
                s.quit();assert pending.recv(1)==b''
                assert 'Async cleanup: timers 0, pipes 0' in log.read_text()
            finally:
                s.save('audit-wire.json')
                (work/'process-exit.json').write_text(json.dumps(dict(pid=server.pid,returncode=server.poll()))+'\n')
                if pending:pending.close()
                stop(foot);f.close()
                for c in s.clients:c.close()
    print('PASS: combined audit soak',cycles,'cycles',round(time.monotonic()-started,1),'seconds;',work)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--cycles',type=int,default=10);parser.add_argument('--seconds',type=float,default=600)
    args=parser.parse_args()
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-audit-soak-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(ROOT/'build/kiln',c_baseline.source(),out),args.cycles,args.seconds)
