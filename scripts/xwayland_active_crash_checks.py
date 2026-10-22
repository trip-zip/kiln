"""Owned X server failure with metadata, a game lock and outgoing INCR active."""
import os
from x11_client import u
from xwayland_bridge_checks import SelectionClient
from xwayland_checks import server_pids
from xwayland_game_checks import lock_events
from xwayland_scenario import scenario,main
from declaration_checks import settle


def run(h):
    with scenario(h,fixture=True,debug=True) as s:
        n=s.n;s.ev('NH=N.handle');samples=[]
        for cycle in range(5):
            x=s.x
            x.prop(s.w,'WM_WINDOW_ROLE','STRING','active-crash')
            x.prop(s.w,'_NET_WM_ICON','CARDINAL',u(8,8,*([0xff20b070]*64)),32);x.sync()
            s.wait("X.role=='active-crash' and X.icon~=nil")
            s.click('N');source=n.data_source({'application/x-kiln-bytes':b'pending outgoing INCR\0'*65536},True)
            n.selection(source,s.serial(),True);s.focus('X')
            x.send(24,u(s.w,x.atom('PRIMARY'),x.atom('application/x-kiln-bytes'),x.atom('KILN_TRANSFER'),0))
            s.until(lambda:bool(n.writes),'active native writer')
            s.until(lambda:x.get_property(s.w,'KILN_TRANSFER')[0]==x.atom('INCR'),'pending X INCR announcement')
            lock_start=len(lock_events(s));s.click('X');hidden=x.hidden_cursor(s.w);x.grab_pointer(s.w,s.w,hidden);s.pump()
            s.until(lambda:bool(lock_events(s)[lock_start:]) and lock_events(s)[-1][1]=='locked','fresh active X lock before crash')
            assert n.writes,'outgoing transfer completed before crash'
            before=dict(lock_events=lock_events(s)[lock_start:],fds=s.fds(),pending_writer_fds=list(n.writes),owners=list(map(int,s.val('resource_fixture(0),resource_fixture(1),resource_fixture(2),resource_fixture(3)').split())))
            assert before['owners']==[1,0,1,256],before
            old=server_pids(s.inner);assert len(old)==1;os.kill(old[0],9)
            s.until(lambda:(x.pump(.01) or x.closed),'owned X connection closes');x.close()
            s.until(lambda:not n.writes,'X server death cancels outgoing native writer')
            assert any(r.get('source')==source and r.get('broken_pipe') for r in n.records),'native source did not observe cancellation'
            s.wait('#client.all()==1 and N.handle==NH');s.h.healthy(s.env)
            s.wait('resource_fixture(0)==0 and resource_fixture(2)==0 and resource_fixture(3)==0')
            x=SelectionClient(s.inner);s.x=x;s.clients.append(x);s.w=x.create(instance='scenario-x')
            s.wait('#client.all()==2');s.pick();s.ev('X:move_to(T);N:move_to(S)');s.pump()
            s.focus('X');x.own(s.w,'CLIPBOARD',{'application/x-kiln-bytes':b'fresh incoming'})
            s.pump();s.focus('N');assert n.receive(n.data_device()[1]['selection'],'application/x-kiln-bytes',x)==b'fresh incoming'
            s.click('N');small=n.data_source({'application/x-kiln-bytes':b'fresh outgoing'},True);n.selection(small,s.serial(),True);s.focus('X')
            assert x.receive(s.w,'PRIMARY','application/x-kiln-bytes',s.pump)==b'fresh outgoing'
            s.point('N');s.ev('collectgarbage("collect");core.dirty()');s.pump(.2);settle(s.log)
            owners=list(map(int,s.val('resource_fixture(0),resource_fixture(1),resource_fixture(2),resource_fixture(3),resource_fixture(4)').split()))
            assert owners==[0,0,0,0,0],owners
            samples.append(dict(cycle=cycle,before_crash=before,old_x=old,new_x=server_pids(s.inner),fds=s.fds(),owners=owners,native_handle=int(s.val('N.handle')),cancelled=True,fresh_incoming=True,fresh_outgoing=True))
            s.rows=samples;s.save('active-crash.json')
        assert len({r['fds'] for r in samples[1:]})==1,samples
        s.shot('active-crash-recovered');s.quit()
    print('PASS: five owned X crashes with outgoing INCR and real game lock active; native writer cancellation, icon/constraint retirement, native/IPC survival, fresh two-way transfers and stable settled FDs',flush=True)

if __name__=='__main__':main(run,'active-crash')
