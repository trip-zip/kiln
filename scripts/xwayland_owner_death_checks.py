"""A live incoming INCR must retire when its X owner connection dies."""
import hashlib
import json
import os
import time
from pathlib import Path
from protocol_client import string
from xwayland_bridge_checks import SelectionClient,verified_dependency
from xwayland_scenario import scenario,main


def attempt(h,primary,known_bug):
    with scenario(h) as s:
        dependency=verified_dependency(s.server,s.inner) if known_bug else None
        selection='PRIMARY' if primary else 'CLIPBOARD'
        n=s.n;owner=SelectionClient(s.inner);s.clients.append(owner)
        w=owner.create(map_now=False);payload=b'owner death bytes\0'*65536
        s.focus('X');owner.own(w,selection,{'application/x-kiln-bytes':b'control'})
        s.until(lambda:any(r['event']==30 for r in owner.records),'owner TARGETS')
        s.focus('N');offer=n.data_device(primary)[1]['selection']
        assert n.receive(offer,'application/x-kiln-bytes',owner)==b'control'
        s.focus('X');before=len(owner.records);owner.pause_incr=True
        owner.own(w,selection,{'application/x-kiln-bytes':payload})
        s.until(lambda:any(r['event']==30 and r['target']==owner.atom('TARGETS') for r in owner.records[before:]),'large owner TARGETS')
        s.focus('N');offer=n.data_device(primary)[1]['selection'];fds=s.fds()
        r,fd=os.pipe2(os.O_CLOEXEC|os.O_NONBLOCK)
        try:
            n.send(offer,0 if primary else 1,string('application/x-kiln-bytes'),(fd,));os.close(fd);n.roundtrip()
            s.until(lambda:bool(owner.transfers),'incoming INCR began')
            transfer=next(iter(owner.transfers.values()))[3]
            owner.pause_incr=False
            for window,prop in list(owner.transfers):owner.property_notify(dict(window=window,property=prop,state=1))
            owner.pause_incr=True
            received=b''
            def first_chunk():
                nonlocal received
                try:received+=os.read(r,65536)
                except BlockingIOError:pass
                return len(received)==32768
            s.until(first_chunk,'first incoming INCR chunk')
            assert received==payload[:32768]
            log_start=len(s.log.read_text());pipe=os.readlink(f'/proc/self/fd/{r}')
            owner.close();s.until(lambda:not n.data_device(primary)[1].get('selection'),'owner loss clears selection')
            assert owner.closed and s.x.owner(selection)==0,'owner connection/selection did not disappear'
            eof=False;deadline=time.monotonic()+3
            while time.monotonic()<deadline:
                s.pump(.01)
                try:chunk=os.read(r,65536)
                except BlockingIOError:continue
                if not chunk:eof=True;break
                received+=chunk
            s.rows.append(dict(case='X owner disconnect during incoming INCR',control=b'control'.hex(),selection=selection,selection_cleared=True,owner_disconnected=True,
                               expected_bytes=len(payload),expected_sha256=hashlib.sha256(payload).hexdigest(),sha256=hashlib.sha256(received).hexdigest(),
                               bytes=len(received),exact_prefix=received==payload[:len(received)],eof=eof,fds_before=fds,fds_after=s.fds(),transfer=transfer,
                               errors=[line for line in s.log.read_text()[log_start:].splitlines() if '[ERROR]' in line],pipe=pipe,
                               retained_pipe_fds=[p.name for p in Path(f'/proc/{s.server.pid}/fd').iterdir() if os.readlink(p)==pipe]))
            s.h.healthy(s.env)
        finally:os.close(r)
        s.pump();row=s.rows[-1];row['fds_after_reader_close']=s.fds()
        row['retained_after_reader_close']=[p.name for p in Path(f'/proc/{s.server.pid}/fd').iterdir() if os.readlink(p)==pipe]
        s.save('owner-death.json')
        s.quit()
        if known_bug:
            assert not eof and row['exact_prefix'] and 0<row['bytes']<len(payload),('review changed owner-death result',row)
            assert not row['errors'] and row['fds_after']==fds+1 and row['fds_after_reader_close']==fds+1,row
            assert len(row['retained_pipe_fds'])==1 and row['retained_after_reader_close']==row['retained_pipe_fds'],row
            (s.work/'known-bug.json').write_text(json.dumps(dict(outcome='KNOWN BUG',dependency=dependency,receipt=row,responsive=True,clean_exit=True,live_transfer_cleanup=False),indent=2)+'\n')
        return row


def run(h,known_bug=False):
    rows=[attempt(h,primary,known_bug) for primary in (False,True)]
    if known_bug:
        print('KNOWN BUG: verified wlroots incoming INCR X-owner death leaves no EOF and retains one pipe FD per isolated clipboard/primary case; responsive until owned shutdown, not live cleanup.',flush=True)
    else:
        assert all(r['eof'] and r['fds_after']==r['fds_before'] and not r['retained_pipe_fds'] for r in rows),('incoming INCR owner death failed to retire transfer',rows)
        print('PASS: incoming INCR owner death closes native FD and retires transfer',flush=True)

if __name__=='__main__':main(run,'owner-death',known_bug=True)
