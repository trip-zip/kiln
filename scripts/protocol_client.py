"""Small native Wayland wire fixture. No generated code or compositor event injection."""
import array
import os
from pathlib import Path
import select
import socket
import struct
import time


def u(*values):
    return struct.pack('='+'I'*len(values), *(v & 0xffffffff for v in values))


def string(value):
    data=value.encode()+b'\0'
    return u(len(data))+data+b'\0'*((-len(data))%4)


def read_string(data, offset=0):
    size=struct.unpack_from('=I',data,offset)[0]
    return data[offset+4:offset+3+size].decode(),offset+4+(size+3)//4*4


class Client:
    def __init__(self, env, fractional=False):
        self.sock=socket.socket(socket.AF_UNIX)
        self.sock.connect(str(Path(env['XDG_RUNTIME_DIR'])/env['WAYLAND_DISPLAY']))
        self.batch=None;self.next_id=2;self.objects={1:('display',None)};self.pending=b''
        self.globals={};self.ready_outputs=False;self.outputs=[];self.records=[];self.surfaces=[];self.fds=[];self.devices={}
        self.writes={}
        self.registry=self.new('registry')
        self.send(1,1,u(self.registry));self.roundtrip()
        self.compositor=self.bind('wl_compositor',4)
        self.fractional=self.bind('wp_fractional_scale_manager_v1',1) if fractional else 0
        self.viewporter=self.bind('wp_viewporter',1) if fractional else 0
        self.shm=self.bind('wl_shm',1)
        self.layer_shell=self.bind('zwlr_layer_shell_v1',4,False)
        self.xdg=self.bind('xdg_wm_base',6,False)
        self.activation=self.bind('xdg_activation_v1',1,False)
        self.decorations=self.bind('zxdg_decoration_manager_v1',1,False)
        self.seat=self.bind('wl_seat',5,False)
        for name,version in self.globals.get('wl_output',[]):
            obj=self.new('output',{'global':name})
            self.send(self.registry,0,u(name)+string('wl_output')+u(min(version,4),obj));self.outputs.append(obj)
        self.ready_outputs=True
        self.roundtrip()

    def new(self, kind, data=None):
        obj=self.next_id;self.next_id+=1;self.objects[obj]=(kind,data);return obj

    def send(self,obj,op,payload=b'',fds=()):
        message=u(obj,((8+len(payload))<<16)|op)+payload
        if self.batch is not None:
            assert not fds
            self.batch.append(message);return
        anc=[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array('i',fds))] if fds else []
        sent=self.sock.sendmsg([message],anc)
        if sent<len(message):self.sock.sendall(message[sent:])

    def bind(self,interface,version,required=True):
        if interface not in self.globals:
            assert not required,interface
            return 0
        name,supported=self.globals[interface][0]
        obj=self.new(interface)
        self.send(self.registry,0,u(name)+string(interface)+u(min(version,supported),obj))
        self.records.append({'bind':interface,'version':min(version,supported)})
        return obj

    def roundtrip(self):
        done=[];obj=self.new('sync',done);self.send(1,0,u(obj))
        end=time.monotonic()+3
        while not done:
            assert time.monotonic()<end,'roundtrip timeout'
            self.pump(.05)

    def pump(self,seconds=.1):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            readable,writable,_=select.select([self.sock],list(self.writes),[],max(0,end-time.monotonic()))
            for fd in writable:
                payload,offset,record=self.writes[fd]
                try:
                    offset+=os.write(fd,payload[offset:offset+16384])
                except BrokenPipeError:
                    record['broken_pipe']=True;offset=len(payload)
                if offset==len(payload):
                    os.close(fd);del self.writes[fd];record['completed']=not record.get('broken_pipe',False)
                else:self.writes[fd]=(payload,offset,record)
            if not readable:continue
            data,anc,flags,_=self.sock.recvmsg(65536,socket.CMSG_SPACE(256))
            assert data,'Wayland disconnected'
            for level,kind,buf in anc:
                if level==socket.SOL_SOCKET and kind==socket.SCM_RIGHTS:
                    fds=array.array('i');fds.frombytes(buf)
                    self.fds.extend(fds)
            self.pending+=data
            while len(self.pending)>=8:
                obj,word=struct.unpack_from('=II',self.pending);size,op=word>>16,word&65535
                if len(self.pending)<size:break
                payload=self.pending[8:size];self.pending=self.pending[size:]
                self.event(obj,op,payload)

    def event(self,obj,op,data):
        kind,meta=self.objects.get(obj,('unknown',None))
        if kind=='display' and op==0:
            target,code=struct.unpack_from('=II',data)
            raise AssertionError(('protocol error',target,code,read_string(data,8)[0]))
        if kind=='registry' and op==0:
            name=struct.unpack_from('=I',data)[0];interface,offset=read_string(data,4)
            version=struct.unpack_from('=I',data,offset)[0]
            self.globals.setdefault(interface,[]).append((name,version))
            if interface=='wl_output' and self.ready_outputs:
                output=self.new('output',{'global':name})
                self.send(self.registry,0,u(name)+string(interface)+u(min(version,4),output));self.outputs.append(output)
            self.records.append({'global_add':interface,'name':name,'version':version})
        elif kind=='registry' and op==1:
            name=struct.unpack('=I',data)[0]
            for interface,entries in self.globals.items():self.globals[interface]=[(n,v) for n,v in entries if n!=name]
            self.outputs=[o for o in self.outputs if self.objects[o][1]['global']!=name]
            self.records.append({'global_remove':name})
        elif kind=='sync':meta.append(True)
        elif kind=='gamma':
            if op==0:meta['size']=struct.unpack('=I',data)[0]
            else:meta['failed']=True
            self.records.append({'gamma':obj,'op':op,'size':meta.get('size')})
        elif kind=='constraint':
            meta['active']=op==0;meta['events'].append(op);self.records.append({'constraint':obj,'op':op})
        elif kind=='relative':
            hi,lo,dx,dy,ux,uy=struct.unpack('=IIiiii',data)
            self.records.append({'relative':obj,'time_us':(hi<<32)|lo,'dx':dx/256,'dy':dy/256,'ux':ux/256,'uy':uy/256})
        elif kind=='activation_token':
            meta.append(read_string(data)[0]);self.records.append({'token_done':meta[-1]})
        elif kind=='output':
            if op==4:meta['name']=read_string(data)[0]
            elif op==3:meta['scale']=struct.unpack('=i',data)[0]
            elif op==1:meta['mode']=struct.unpack('=Iiii',data)
        elif kind=='surface' and meta is not None:
            if op in (0,1):
                target=struct.unpack('=I',data)[0]
                outputs=meta.setdefault('outputs',set())
                if op==0:outputs.add(target)
                else:outputs.discard(target)
                self.records.append({'surface':obj,'membership':op,'output':target})
        elif kind=='fractional':
            meta['scale120']=struct.unpack('=I',data)[0]
            self.records.append({'surface':meta['surface'],'scale120':meta['scale120']})
            if meta.get('painted'):self.paint(meta,*meta['size'])
        elif kind=='xdg_wm_base' and op==0:self.send(obj,3,data)
        elif kind=='wl_seat' and op==0:
            caps=struct.unpack_from('=I',data)[0]
            if caps&1 and not hasattr(self,'pointer'):
                self.pointer=self.new('pointer');self.send(obj,0,u(self.pointer))
            if caps&2 and not hasattr(self,'keyboard'):
                self.keyboard=self.new('keyboard');self.send(obj,1,u(self.keyboard))
        elif kind in ('pointer','keyboard'):
            if kind=='keyboard' and op==0:os.close(self.fds.pop(0))
            self.records.append({'input':kind,'op':op,'words':list(struct.unpack('='+str(len(data)//4)+'I',data))})
        elif kind in ('data_source','primary_source'):
            sending=op==(1 if kind=='data_source' else 0)
            record={'source':obj,'kind':kind,'op':op}
            if sending:
                mime=read_string(data)[0];fd=self.fds.pop(0)
                os.set_blocking(fd,False)
                self.writes[fd]=(meta['payloads'][mime],0,record)
                record['mime']=mime;record['bytes']=len(meta['payloads'][mime])
            elif op==(2 if kind=='data_source' else 1):meta['cancelled']=True
            elif kind=='data_source' and op==5:meta['action']=struct.unpack('=I',data)[0]
            elif kind=='data_source' and op==4:meta['finished']=True
            self.records.append(record)
        elif kind in ('data_device','primary_device'):
            words=list(struct.unpack('='+str(len(data)//4)+'I',data))
            self.records.append({'device':obj,'kind':kind,'op':op,'words':words})
            if op==0:self.objects[words[0]]=('data_offer' if kind=='data_device' else 'primary_offer',{'mimes':[]})
            elif op==(5 if kind=='data_device' else 1):meta['selection']=words[0]
            elif kind=='data_device' and op==1:meta['enter']=words
            elif kind=='data_device' and op==2:meta.pop('enter',None)
            elif kind=='data_device' and op==4:meta['dropped']=True
        elif kind in ('data_offer','primary_offer'):
            if op==0:meta['mimes'].append(read_string(data)[0])
            elif op==2:meta['action']=struct.unpack('=I',data)[0]
            self.records.append({'offer':obj,'kind':kind,'op':op,'mimes':list(meta['mimes']),'action':meta.get('action')})
        elif kind=='layer' and op==0:
            serial,w,h=struct.unpack('=III',data)
            self.records.append({'layer':obj,'configure':serial,'width':w,'height':h})
            self.send(obj,6,u(serial));self.records.append({'layer':obj,'ack':serial})
            self.paint(meta,w or meta['width'],h or meta['height'])
        elif kind=='layer' and op==1:meta['closed']=True
        elif kind=='xdg_surface' and op==0:
            if meta.get('suspended'):return
            serial=struct.unpack('=I',data)[0]
            self.send(obj,4,u(serial));self.records.append({'xdg':obj,'ack':serial})
            self.paint(meta,*meta.get('size',(240,140)))
        elif kind=='zwlr_foreign_toplevel_manager_v1' and op==0:
            handle=struct.unpack('=I',data)[0]
            self.objects[handle]=('foreign',{'outputs':set(),'states':set(),'done':0})
            self.records.append({'foreign_new':handle})
        elif kind=='foreign':
            record={'foreign':obj,'op':op}
            if op in (0,1):
                value=read_string(data)[0];meta['title' if op==0 else 'app_id']=value;record['value']=value
            elif op in (2,3):
                value=struct.unpack('=I',data)[0];record['output']=value
                if op==2:meta['outputs'].add(value)
                else:meta['outputs'].discard(value)
            elif op==4:
                size=struct.unpack_from('=I',data)[0];meta['states']=set(struct.unpack('='+str(size//4)+'I',data[4:4+size]));record['states']=sorted(meta['states'])
            elif op==5:meta['done']+=1
            elif op==6:meta['closed']=True
            self.records.append(record)
        elif kind=='toplevel' and op==1:meta['closed']=True
        elif kind=='toplevel' and op==0:
            w,h=struct.unpack_from('=ii',data);meta['size']=(w or 240,h or 140)
        elif kind=='decoration':self.records.append({'decoration':obj,'mode':struct.unpack('=I',data)[0]})
        elif kind=='popup':
            self.records.append({'popup':obj,'op':op,'words':list(struct.unpack('='+str(len(data)//4)+'I',data))})
            if op==0:
                x,y,w,h=struct.unpack('=iiii',data);meta['size']=(w,h);meta['box']=(x,y,w,h)
            elif op==1:meta['done']=True

    def paint(self,meta,w,h):
        assert 0<w<=4096 and 0<h<=4096,(w,h)
        size=(w,h)
        if meta.get('kind')=='toplevel':
            gx,gy=meta['geometry']
            self.send(meta['xdg'],3,u(gx,gy,w,h))
            w,h=w+2*gx,h+2*gy
        if meta.get('viewport'):
            self.send(meta['viewport'],2,u(w,h))
            scale=meta.get('scale120',120)/120
            w,h=round(w*scale),round(h*scale)
        meta['buffer_size']=(w,h)
        self.records.append({'surface':meta['surface'],'buffer_size':[w,h],'logical_size':list(size)})
        fd=os.memfd_create('kiln-protocol-fixture',os.MFD_CLOEXEC)
        try:
            os.ftruncate(fd,w*h*4)
            os.write(fd,u(meta.get('color',0xff20a060))*(w*h))
            pool=self.new('pool');buffer=self.new('buffer')
            self.send(self.shm,0,u(pool,w*h*4),(fd,))
            self.send(pool,0,u(buffer,0,w,h,w*4,0));self.send(pool,1)
            self.send(meta['surface'],1,u(buffer,0,0))
            self.send(meta['surface'],2,u(0,0,w,h));self.send(meta['surface'],6)
            self.send(buffer,0)
            meta['size']=size;meta['painted']=meta.get('painted',0)+1
        finally:os.close(fd)

    def layer(self,namespace='fixture',output=None,band=2,width=0,height=40,anchor=13,zone=40,margin=(0,0,0,0),keyboard=0,color=0xff20a060,wait=True):
        assert self.layer_shell,'layer shell unavailable'
        meta={'width':width or 100,'height':height or 100,'color':color}
        surface=self.new('surface',meta);meta['surface']=surface
        role=self.new('layer',meta);meta['role']=role
        self.send(self.compositor,0,u(surface))
        target=0
        if output:
            target=next(o for o in self.outputs if self.objects[o][1].get('name')==output)
        self.send(self.layer_shell,0,u(role,surface,target,band)+string(namespace))
        self.send(role,0,u(width,height));self.send(role,1,u(anchor));self.send(role,2,u(zone));self.send(role,3,u(*margin));self.send(role,4,u(keyboard))
        self.send(surface,6);self.surfaces.append(meta)
        if wait:self.pump(.2)
        return meta

    def change(self,meta,**kwargs):
        role=meta['role']
        for key,value in kwargs.items():
            op={'size':0,'anchor':1,'zone':2,'margin':3,'keyboard':4,'band':8}[key]
            self.send(role,op,u(*value) if isinstance(value,tuple) else u(value))
        self.send(meta['surface'],6);self.pump(.2)

    def unmap(self,meta):
        if meta.get('kind')=='toplevel':meta['suspended']=True
        self.send(meta['surface'],1,u(0,0,0));self.send(meta['surface'],6);self.roundtrip()

    def destroy(self,meta):
        self.send(meta['role'],7);self.send(meta['surface'],0);self.roundtrip()

    def toplevel(self,title='protocol-root',parent=None,decorate=True,geometry=(0,0),color=0xff305090):
        meta={'color':color,'geometry':geometry,'kind':'toplevel'}
        surface=self.new('surface',meta);meta['surface']=surface
        xdg=self.new('xdg_surface',meta);meta['xdg']=xdg
        role=self.new('toplevel',meta);meta['role']=role
        self.send(self.compositor,0,u(surface));self.send(self.xdg,2,u(xdg,surface));self.send(xdg,1,u(role))
        if self.fractional:
            fraction=self.new('fractional',meta);meta['fractional']=fraction
            viewport=self.new('viewport',meta);meta['viewport']=viewport
            self.send(self.fractional,1,u(fraction,surface));self.send(self.viewporter,1,u(viewport,surface))
        self.send(role,2,string(title));self.send(role,3,string(title))
        if parent:self.send(role,1,u(parent['role']))
        if decorate and self.decorations:
            deco=self.new('decoration',meta);meta['decoration']=deco
            self.send(self.decorations,1,u(deco,role));self.send(deco,1,u(1))
        self.send(surface,6);self.surfaces.append(meta);self.pump(.3)
        return meta

    def token(self,serial=None,surface=None,app_id=None):
        assert self.activation
        result=[];obj=self.new('activation_token',result)
        self.send(self.activation,1,u(obj))
        if serial is not None:self.send(obj,0,u(serial,self.seat))
        if app_id is not None:self.send(obj,1,string(app_id))
        if surface is not None:self.send(obj,2,u(surface['surface']))
        self.send(obj,3);self.roundtrip();assert result
        self.send(obj,4)
        return result[0]

    def activate(self,token,surface):
        self.records.append({'activate':token,'surface':surface['surface']})
        self.send(self.activation,2,string(token)+u(surface['surface']));self.roundtrip()

    def data_device(self,primary=False):
        key='primary' if primary else 'data'
        if key not in self.devices:
            manager=self.bind('zwp_primary_selection_device_manager_v1' if primary else 'wl_data_device_manager',1 if primary else 3)
            meta={'manager':manager};device=self.new(key+'_device',meta)
            self.send(manager,1,u(device,self.seat));self.devices[key]=(device,meta);self.roundtrip()
        return self.devices[key]

    def data_source(self,payloads,primary=False,actions=None):
        device,meta=self.data_device(primary)
        source=self.new('primary_source' if primary else 'data_source',{'payloads':payloads})
        self.send(meta['manager'],0,u(source))
        for mime in payloads:self.send(source,0,string(mime))
        if actions is not None:self.send(source,2,u(actions))
        return source

    def selection(self,source,serial,primary=False):
        device,_=self.data_device(primary)
        self.send(device,0 if primary else 1,u(source,serial));self.roundtrip()

    def receive(self,offer,mime,source,slow=False):
        primary=self.objects[offer][0]=='primary_offer'
        r,w=os.pipe2(os.O_CLOEXEC|os.O_NONBLOCK)
        try:
            self.send(offer,0 if primary else 1,string(mime),(w,));os.close(w);w=-1
            self.roundtrip()
            result=b'';deadline=time.monotonic()+20
            while True:
                assert time.monotonic()<deadline,'selection receive timeout'
                source.pump(.002);self.pump(.002)
                try:chunk=os.read(r,4096 if slow else 65536)
                except BlockingIOError:continue
                if not chunk:break
                result+=chunk
                if slow:time.sleep(.001)
            import hashlib
            self.records.append({'received':offer,'mime':mime,'bytes':len(result),'sha256':hashlib.sha256(result).hexdigest(),**({'hex':result.hex()} if len(result)<4096 else {})})
            return result
        finally:
            os.close(r)
            if w>=0:os.close(w)

    def start_drag(self,source,origin,serial,icon=True):
        device,_=self.data_device()
        meta=None
        if icon:
            meta={'color':0xffff8020};meta['surface']=self.new('surface',meta)
            self.send(self.compositor,0,u(meta['surface']))
        self.send(device,0,u(source,origin['surface'],meta['surface'] if meta else 0,serial))
        if meta:self.paint(meta,40,40)
        self.roundtrip()
        return meta

    def relative_pointer(self):
        manager=self.bind('zwp_relative_pointer_manager_v1',1)
        obj=self.new('relative');self.send(manager,1,u(obj,self.pointer));self.roundtrip();return obj

    def region(self,box):
        obj=self.new('region');self.send(self.compositor,1,u(obj));self.send(obj,1,u(*box));return obj

    def constrain(self,surface,locked=True,box=None,persistent=True):
        manager=self.bind('zwp_pointer_constraints_v1',1)
        region=self.region(box) if box else 0
        obj=self.new('constraint',{'active':False,'events':[]})
        self.send(manager,1 if locked else 2,u(obj,surface['surface'],self.pointer,region,2 if persistent else 1))
        if region:self.send(region,0)
        self.roundtrip();return obj

    def shape_device(self):
        manager=self.bind('wp_cursor_shape_manager_v1',1)
        obj=self.new('shape');self.send(manager,1,u(obj,self.pointer));self.roundtrip();return obj

    def set_shape(self,device,shape,serial=None):
        if serial is None:serial=[r for r in self.records if r.get('input')=='pointer' and r['op']==0][-1]['words'][0]
        self.records.append({'set_shape':shape,'serial':serial})
        self.send(device,1,u(serial,shape));self.roundtrip()

    def positioner(self,size=(180,100),anchor=(0,0,1,1),adjust=15,reactive=True):
        obj=self.new('positioner')
        self.send(self.xdg,1,u(obj));self.send(obj,1,u(*size));self.send(obj,2,u(*anchor))
        self.send(obj,3,u(8));self.send(obj,4,u(8));self.send(obj,5,u(adjust))
        if reactive:self.send(obj,7)
        return obj

    def popup(self,parent,anchor=(0,0,1,1),size=(180,100),token=None,grab=None,color=0xffd09020):
        positioner=self.positioner(size,anchor)
        meta={'color':color,'kind':'popup'}
        surface=self.new('surface',meta);meta['surface']=surface
        xdg=self.new('xdg_surface',meta);meta['xdg']=xdg
        role=self.new('popup',meta);meta['role']=role
        self.send(self.compositor,0,u(surface));self.send(self.xdg,2,u(xdg,surface))
        layer=self.objects[parent['role']][0]=='layer'
        self.send(xdg,2,u(role,0 if layer else parent['xdg'],positioner))
        if layer:self.send(parent['role'],5,u(role))
        if grab is not None:self.send(role,1,u(self.seat,grab))
        self.send(positioner,0);self.send(surface,6);self.surfaces.append(meta);self.pump(.3)
        return meta

    def reposition(self,meta,token,anchor,size=(180,100)):
        positioner=self.positioner(size,anchor)
        self.send(meta['role'],2,u(positioner,token));self.send(positioner,0);self.pump(.2)

    def destroy_xdg(self,meta,role_first=False):
        if 'decoration' in meta:
            decoration=meta.pop('decoration')
            if not role_first:self.send(decoration,0)
        self.send(meta['role'],0);self.send(meta['xdg'],0);self.send(meta['surface'],0);self.roundtrip()

    def flush_batch(self):
        messages=self.batch;self.batch=None;self.sock.sendall(b''.join(messages))

    def subsurface(self,parent,width=50,height=40,x=20,y=10):
        subcompositor=self.bind('wl_subcompositor',1)
        meta={'width':width,'height':height,'color':0xffb030b0}
        surface=self.new('surface',meta);meta['surface']=surface
        self.send(self.compositor,0,u(surface))
        role=self.new('subsurface',meta);meta['role']=role
        self.send(subcompositor,1,u(role,surface,parent['surface']))
        self.send(role,1,u(x,y));self.paint(meta,width,height)
        self.send(parent['surface'],6);self.pump(.2)
        return meta

    def close(self):
        self.sock.close()
        for fd in self.fds:os.close(fd)
        self.fds=[]
        for fd in self.writes:os.close(fd)
        self.writes.clear()
