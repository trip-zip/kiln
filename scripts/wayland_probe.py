"""Transparent test-only Wayland relay recording xdg configure arrays on the wire."""
import array
import contextlib
import json
import os
from pathlib import Path
import selectors
import socket
import struct
import threading


class Probe:
    def __init__(self, env, path):
        self.path=Path(path)
        self.upstream=Path(env['XDG_RUNTIME_DIR'])/env['WAYLAND_DISPLAY']
        self.listener=socket.socket(socket.AF_UNIX)
        self.listener.bind(str(self.path));self.listener.listen(1);self.listener.settimeout(.1)
        self.stop=threading.Event();self.records=[];self.errors=[]
        self.ids={1:'wl_display'};self.pending=[b'',b''];self.sockets=[]
        self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()

    def parse(self,data,direction):
        data=self.pending[direction]+data
        while len(data)>=8:
            obj,word=struct.unpack_from('=II',data);size,op=word>>16,word&65535
            assert size>=8 and size%4==0
            if len(data)<size:break
            payload=data[8:size];data=data[size:];kind=self.ids.get(obj)
            if direction==0:
                if kind=='wl_display' and op==1:self.ids[struct.unpack_from('=I',payload)[0]]='wl_registry'
                elif kind=='wl_registry' and op==0:
                    length=struct.unpack_from('=I',payload,4)[0]
                    interface=payload[8:8+length-1].decode()
                    offset=8+(length+3)//4*4
                    version,new=struct.unpack_from('=II',payload,offset)
                    self.ids[new]=interface
                    if interface=='xdg_wm_base':self.records.append({'bind':interface,'version':version})
                elif kind=='xdg_wm_base' and op==2:self.ids[struct.unpack_from('=I',payload)[0]]='xdg_surface'
                elif kind=='xdg_surface' and op==1:self.ids[struct.unpack_from('=I',payload)[0]]='xdg_toplevel'
                elif kind=='xdg_surface' and op==4:self.records.append({'ack':struct.unpack_from('=I',payload)[0]})
                elif kind=='xdg_toplevel' and op in (9,10,11,12,13):self.records.append({'request':{9:'maximize',10:'unmaximize',11:'fullscreen',12:'unfullscreen',13:'minimize'}[op]})
            elif kind=='xdg_toplevel' and op==0:
                w,h,length=struct.unpack_from('=iiI',payload)
                states=list(struct.unpack_from('='+str(length//4)+'I',payload,12))
                self.records.append({'width':w,'height':h,'states':states})
        self.pending[direction]=data

    def run(self):
        try:
            while not self.stop.is_set():
                try:client,_=self.listener.accept();break
                except socket.timeout:continue
            else:return
            upstream=socket.socket(socket.AF_UNIX);upstream.connect(str(self.upstream))
            self.sockets=[client,upstream]
            with selectors.DefaultSelector() as sel:
                sel.register(client,selectors.EVENT_READ,(upstream,0));sel.register(upstream,selectors.EVENT_READ,(client,1))
                while not self.stop.is_set():
                    for key,_ in sel.select(.1):
                        dest,direction=key.data
                        data,anc,flags,_=key.fileobj.recvmsg(65536,socket.CMSG_SPACE(256))
                        if not data:return
                        assert not flags&socket.MSG_CTRUNC
                        try:
                            self.parse(data,direction)
                            sent=dest.sendmsg([data],anc)
                            if sent<len(data):dest.sendall(data[sent:])
                        finally:
                            for level,kind,buf in anc:
                                if level==socket.SOL_SOCKET and kind==socket.SCM_RIGHTS:
                                    fds=array.array('i');fds.frombytes(buf)
                                    for fd in fds:os.close(fd)
        except (BrokenPipeError,ConnectionResetError):pass
        except Exception as e:self.errors.append(repr(e))
        finally:
            for s in self.sockets:s.close()

    def close(self):
        self.stop.set();self.thread.join(timeout=3);self.listener.close();self.path.unlink()
        assert not self.thread.is_alive() and not self.errors,self.errors


@contextlib.contextmanager
def probe(env,work,label):
    p=Probe(env,Path(env['XDG_RUNTIME_DIR'])/('probe-'+label))
    try:yield dict(env,WAYLAND_DISPLAY=p.path.name),p.records
    finally:
        p.close()
        (work/(label+'-wire.json')).write_text(json.dumps(p.records,indent=2)+'\n')
