"""Supported mixed X/native cycles, isolated from known defective INCR paths."""
import os
import json
from pathlib import Path
from x11_client import u
from xwayland_bridge_checks import SelectionClient
from xwayland_checks import server_pids
from xwayland_game_checks import active
from xwayland_scenario import scenario,main
from declaration_checks import settle
from paint_checks import stats


def run(h):
    with scenario(h,fixture=True,debug=True) as s:
        n=s.n;s.ev('NH=N.handle');samples=[]
        def fds():return {p.name:os.readlink(p) for p in Path(f'/proc/{s.server.pid}/fd').iterdir()}
        def pipes():return sorted(v for v in fds().values() if v.startswith('pipe:'))
        def non_shm(values):return sum(not (v.startswith('/dev/shm/wlroots-') or v.startswith('/memfd:xwayland-shared')) for v in values.values())
        for cycle in range(5):
            x=s.x;s.point('N');s.pump(.2);baseline_fds=s.fds()
            before_fds={p.name:os.readlink(p) for p in Path(f'/proc/{s.server.pid}/fd').iterdir()}
            x.prop(s.w,'WM_WINDOW_ROLE','STRING','cycle-role')
            x.prop(s.w,'_NET_WM_ICON','CARDINAL',u(8,8,*([0xff3070d0]*64)),32);x.sync()
            s.wait("X.role=='cycle-role' and X.icon=='xwl-icon:'..X.handle")
            s.focus('X');x.own(s.w,'CLIPBOARD',{'application/x-kiln-bytes':b'supported cycle bytes'})
            s.pump();s.focus('N');offer=n.data_device()[1]['selection']
            selection_pipes=pipes()
            assert n.receive(offer,'application/x-kiln-bytes',x)==b'supported cycle bytes'
            s.until(lambda:pipes()==selection_pipes,'completed selection releases transfer pipes')
            s.click('X');hidden=x.hidden_cursor(s.w);x.grab_pointer(s.w,s.w,hidden);s.pump()
            s.until(lambda:active(s)==1,'combined game lock')
            s.reload();s.reload(True);s.reload();s.pick();s.wait('N.handle==NH')
            x.ungrab();s.pump();x.unmap(s.w);s.pump();x.map(s.w);s.pump();s.pick()
            s.wait("X.role=='cycle-role' and X.icon~=nil")
            s.ev('core.output.set_enabled(T.name,false)');s.pump();s.ev('core.output.set_enabled(T.name,true)');s.pump()
            s.ev('assert(output_fixture(1,T.name))');s.pump();s.wait('#screen.all()==1')
            s.ev("assert(output_fixture(3,''))");s.pump();s.wait('#screen.all()==2');s.pick();s.refresh_windows()
            s.ev('T.scale=1.5;core.output.set_position(T.name,1161,91);N:move_to(S);X:move_to(T)');s.pump()
            # Native->X transfer/finish is supported and must retire every cycle.
            s.ev('N:move_to(T)');s.pump()
            x.prop(s.w,'XdndAware','ATOM',u(5),32);x.sync();s.point('N');s.xdo('mousedown',1)
            start=len(x.records);source=n.data_source({'text/plain;charset=utf-8':b'cycle drag'},actions=1)
            icon=n.start_drag(source,s.a,s.serial());s.pump();s.point('X')
            def messages(name):return [r for r in x.records[start:] if r['event']==33 and r['type']==x.atom(name)]
            s.until(lambda:bool(messages('XdndEnter')),'combined drag enter');proxy=messages('XdndEnter')[-1]['data'][0]
            x.message(proxy,'XdndStatus',[s.w,1,0,0,x.atom('XdndActionCopy')],destination=proxy,mask=0);s.pump()
            drag_pipes=pipes()
            assert x.receive(s.w,'XdndSelection','UTF8_STRING',s.pump)==b'cycle drag'
            s.until(lambda:pipes()==drag_pipes,'completed drag releases transfer pipes')
            s.xdo('mouseup',1);s.until(lambda:bool(messages('XdndDrop')),'combined drop')
            x.message(proxy,'XdndFinished',[s.w,1,x.atom('XdndActionCopy')],destination=proxy,mask=0)
            s.until(lambda:n.objects[source][1].get('finished'),'combined drag finished')
            n.send(icon['surface'],0);n.roundtrip()
            s.ev('N:move_to(S)');s.pump();s.point('N');s.pump(.3)
            after_fds={p.name:os.readlink(p) for p in Path(f'/proc/{s.server.pid}/fd').iterdir()}
            (s.work/f'live-fds-{cycle}.json').write_text(json.dumps(dict(before=before_fds,after=after_fds),indent=2)+'\n')
            assert non_shm(before_fds)==non_shm(after_fds),(before_fds,after_fds)
            before_restart=list(map(int,s.val('resource_fixture(0),resource_fixture(1),resource_fixture(2),resource_fixture(3)').split()))
            assert before_restart==[0,0,1,256],before_restart
            old=server_pids(s.inner);assert len(old)==1;os.kill(old[0],9)
            s.until(lambda:(x.pump(.01) or x.closed),'combined owned X death');x.close();s.wait('#client.all()==1 and N.handle==NH');s.h.healthy(s.env)
            x=SelectionClient(s.inner);s.x=x;s.clients.append(x);s.w=x.create(instance='scenario-x');s.wait('#client.all()==2');s.pick()
            s.ev('X:move_to(T);N:move_to(S)');s.pump();assert server_pids(s.inner)!=old
            # Sample an identical, settled population after every recovery.
            s.ev('collectgarbage("collect");core.dirty()');s.pump(.2);settle(s.log)
            s.ev('core.dirty()');s.pump(.2);settle(s.log)
            names=s.val('S.name,T.name').decode().split();paint=[stats(s.log,name) for name in names]
            assert all(v[:2]==(0,0) for v in paint),paint
            before=s.log.read_text().count('Layout ');x.paint(s.w);s.pump(.2)
            assert s.log.read_text().count('Layout ')==before,'buffer repaint solved layout'
            refs=int(s.val("(function()local n=0;for k,v in pairs(debug.getregistry())do if type(k)=='number' and type(v)=='function'then n=n+1 end end;return n end)()"))
            samples.append(dict(cycle=cycle,live_fds_before=baseline_fds,live_fds_after_supported=len(after_fds),live_non_shm_fds=non_shm(after_fds),selection_pipes=selection_pipes,drag_pipes=drag_pipes,owners_before_restart=before_restart,fds=s.fds(),refs=refs,paint=[v[2:] for v in paint],active_constraints=active(s),owners=list(map(int,s.val('resource_fixture(0),resource_fixture(1),resource_fixture(2),resource_fixture(3),resource_fixture(4)').split())),old_x=old,new_x=server_pids(s.inner),native_handle=int(s.val('N.handle'))))
            s.rows=samples;s.save('combined-lifecycle.json')
        assert len({r['live_fds_after_supported'] for r in samples[1:]})==1,samples
        assert len({r['fds'] for r in samples[1:]})==1,samples
        assert len({r['refs'] for r in samples[1:]})==1,samples
        assert len({str(r['paint']) for r in samples[1:]})==1,samples
        assert all(r['active_constraints']==0 and r['owners']==[0,0,0,0,0] for r in samples),samples
        s.shot('combined-recovered');s.quit()
    print('PASS: five supported mixed metadata/icon/selection/drag/game/reload/output/X-server recovery cycles; settled FDs/refs/paint and native identity stable, idle zero work and buffer repaint without solves. Known defective paths excluded from these measurements.',flush=True)

if __name__=='__main__':main(run,'combined-lifetimes')
