"""Selection cancellation and recovery, independently of the known slow INCR bug."""
import os
import hashlib
import time
from protocol_client import Client,string,u
from xwayland_bridge_checks import SelectionClient
from xwayland_checks import server_pids
from xwayland_scenario import scenario,main


def run(h):
    with scenario(h) as s:
        x,n=s.x,s.n;payload=b'owner lifetime\0\xff\n'
        s.ev("PIPE_CHILD=nil;K.spawn.pipe({'sh','-c','kill -PIPE $$;exit 99'},{on_exit=function(code)PIPE_CHILD=code end})")
        s.wait('PIPE_CHILD~=nil');assert s.val('PIPE_CHILD')==b'141\n','child SIGPIPE disposition was inherited incorrectly'
        s.rows.append(dict(child_sigpipe_exit=141))
        def native_own(primary=False):
            s.click('N');src=n.data_source({'application/x-kiln-bytes':payload},primary)
            n.selection(src,s.serial(),primary);s.focus('X');return src
        def x_own(owner=x,w=None,primary=False,data=payload):
            s.focus('X');before=len(owner.records)
            owner.own(s.w if w is None else w,'PRIMARY' if primary else 'CLIPBOARD',{'application/x-kiln-bytes':data})
            s.until(lambda:any(r['event']==30 and r['target']==owner.atom('TARGETS') for r in owner.records[before:]),'X TARGETS')
            s.focus('N');s.pump()
            return n.data_device(primary)[1]['selection']
        for primary in (False,True):
            selection='PRIMARY' if primary else 'CLIPBOARD'
            src=native_own(primary)
            for broken in (False,True,False):
                s.reload(broken)
                if not broken:s.focus('X')
                focused=x.focus()
                assert focused in (0,1,s.w),focused
                actual=x.receive(s.w,selection,'application/x-kiln-bytes',s.pump)
                # The bridge denies X reads when reload policy leaves no X focus.
                assert actual==(payload if focused==s.w else None),(selection,broken,focused,actual)
                s.rows.append(dict(selection=selection,broken=broken,x_focus=focused,x_read=None if actual is None else actual.hex()))
            s.focus('N');s.focus('X')
            assert x.receive(s.w,selection,'application/x-kiln-bytes',s.pump)==payload
            offer=x_own(primary=primary)
            for broken in (False,True,False):
                s.reload(broken)
                if not broken:
                    s.focus('N');offer=n.data_device(primary)[1]['selection']
                actual=n.receive(offer,'application/x-kiln-bytes',x)
                assert actual==payload,(selection,broken,actual)
            assert n.receive(offer,'application/x-unsupported',x)==b''
            s.rows.append(dict(selection=selection,reload_focus_bytes=payload.hex()))
            # Disconnected X owner clears only its own selection.
            owner=SelectionClient(s.inner);s.clients.append(owner);w=owner.create(map_now=False)
            x_own(owner,w,primary);owner.close()
            s.until(lambda:not n.data_device(primary)[1].get('selection'),'dead X owner clears selection')
            # Reader closes during a large native->X stream, while the source
            # remains alive. Its FD must close and new transfers must still work.
            s.click('N');large=n.data_source({'application/x-kiln-bytes':payload*100000},primary);n.selection(large,s.serial(),primary);s.focus('X')
            requestor=SelectionClient(s.inner);s.clients.append(requestor);rw=requestor.create(map_now=False)
            requestor.send(24,u(rw,requestor.atom(selection),requestor.atom('application/x-kiln-bytes'),requestor.atom('KILN_TRANSFER'),0))
            s.until(lambda:bool(n.writes),'outgoing source FD')
            requestor.close();s.until(lambda:not n.writes,'dead X requestor cancels source FD')
            assert any(r.get('source')==large and r.get('broken_pipe') for r in n.records)
            native_own(primary);assert x.receive(s.w,selection,'application/x-kiln-bytes',s.pump)==payload
            s.rows.append(dict(selection=selection,native_to_x_reader_death=True,source_fd_closed=True,recovery_bytes=payload.hex()))
            # The X source pauses after advertising INCR; destroying the native
            # reader is a cancellation check, not a slow-transfer success claim.
            owner=SelectionClient(s.inner);s.clients.append(owner);w=owner.create(map_now=False);owner.pause_incr=True
            offer=x_own(owner,w,primary,payload*100000)
            r,fd=os.pipe2(os.O_CLOEXEC|os.O_NONBLOCK)
            n.send(offer,0 if primary else 1,string('application/x-kiln-bytes'),(fd,));os.close(fd);n.roundtrip()
            s.until(lambda:bool(owner.transfers),'paused incoming INCR');os.close(r)
            owner.pause_incr=False
            for window,prop in list(owner.transfers):owner.property_notify(dict(window=window,property=prop,state=1))
            s.until(lambda:not owner.transfers,'native reader death cancels incoming INCR')
            owner.close();s.until(lambda:not n.data_device(primary)[1].get('selection'),'owner cleared after cancellation')
            x_own(primary=primary);assert n.receive(n.data_device(primary)[1]['selection'],'application/x-kiln-bytes',x)==payload
            s.rows.append(dict(selection=selection,requestor_deaths='both directions',responsive=True))
            baseline=s.fds();native_owner=Client(s.env);s.clients.append(native_owner)
            native_owner.toplevel('selection-owner');s.wait('#client.all()==3')
            s.ev("for _,c in ipairs(client.all())do if c.app_id=='selection-owner' then O=c end end")
            s.click('O');data=payload*100000
            src=native_owner.data_source({'application/x-kiln-bytes':data},primary)
            native_owner.selection(src,s.serial(native_owner),primary);s.focus('X')
            requestor=SelectionClient(s.inner);s.clients.append(requestor);rw=requestor.create(map_now=False)
            requestor.send(24,u(rw,requestor.atom(selection),requestor.atom('application/x-kiln-bytes'),requestor.atom('KILN_TRANSFER'),0))
            s.until(lambda:bool(native_owner.writes),'native owner has active transfer FD')
            native_owner.close();native_owner.closed=True
            s.until(lambda:x.owner(selection)==0,'native owner disconnect clears X ownership')
            partial=requestor.receive(rw,selection,'application/x-kiln-bytes',s.pump,pending=True)
            assert 0<len(partial)<len(data) and partial==data[:len(partial)]
            assert requestor.incr[-1]['chunks'][-1]==0,'dead native source must terminate INCR'
            requestor.close();s.until(lambda:s.fds()==baseline,'native owner death releases transfer FDs')
            s.rows.append(dict(selection=selection,native_owner_death=True,terminated_bytes=len(partial),prefix_sha256=hashlib.sha256(partial).hexdigest(),fds_before=baseline,fds_after=s.fds()))
            x_own(primary=primary)
        # Killing only the owned X server clears its selection sources, leaves
        # native clients alive, and permits a fresh bridge after lazy restart.
        old=server_pids(s.inner);assert len(old)==1
        os.kill(old[0],9);s.until(lambda:(x.pump(.01) or x.closed),'X server death')
        s.until(lambda:not n.data_device()[1].get('selection') and not n.data_device(True)[1].get('selection'),'restart clears X owners')
        s.wait('#client.all()==1');s.h.healthy(s.env)
        x=SelectionClient(s.inner);s.x=x;s.clients.append(x);s.w=x.create(instance='scenario-x');s.wait('#client.all()==2');s.pick();s.ev('X:move_to(T)');s.pump()
        for primary in (False,True):
            offer=x_own(owner=x,primary=primary);assert n.receive(offer,'application/x-kiln-bytes',x)==payload
        assert server_pids(s.inner)!=old
        s.rows.append(dict(restart_old=old,restart_new=server_pids(s.inner),native_survived=True))
        s.quit()
    print('PASS: cross-protocol selections survive focus/good/broken/repaired reload, both reader deaths, X owner deaths and owned X server restart with exact fresh bytes',flush=True)

if __name__=='__main__':main(run,'selection-lifetimes')
