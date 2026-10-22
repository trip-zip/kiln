"""Small real X11 wire client; layouts checked against installed xcb/xproto.xml.

Connections require an explicit owned display. Input is observed, never injected.
"""
import os
import select
import socket
import struct
import time


def u(*v):return struct.pack('<'+'I'*len(v),*(n & 0xffffffff for n in v))
def pad(b):return b+b'\0'*((-len(b))%4)


class XClient:
    def __init__(self, display):
        assert display.startswith(':') and display[1:].isdigit(),display
        self.display=display;self.sock=socket.socket(socket.AF_UNIX);self.sock.settimeout(5)
        self.sock.connect('/tmp/.X11-unix/X'+display[1:])
        self.sock.sendall(struct.pack('<BBHHHHH',ord('l'),0,11,0,0,0,0))
        head=self.read(8);assert head[0]==1,head
        setup=head+self.read(struct.unpack_from('<H',head,6)[0]*4)
        self.base,self.mask=struct.unpack_from('<II',setup,12)
        vendor=struct.unpack_from('<H',setup,24)[0]
        screen=40+(vendor+3)//4*4+setup[29]*8
        self.root=struct.unpack_from('<I',setup,screen)[0]
        self.next_id=1;self.seq=0;self.atoms={};self.replies={};self.records=[];self.closed=False
        self.windows={}

    def read(self,n):
        out=b''
        while len(out)<n:
            part=self.sock.recv(n-len(out))
            if not part:raise EOFError('X connection closed')
            out+=part
        return out

    def send(self,op,payload=b'',detail=0):
        payload=pad(payload);self.seq+=1
        self.sock.sendall(struct.pack('<BBH',op,detail,1+len(payload)//4)+payload)
        return self.seq & 65535

    def packet(self):
        b=self.read(32);kind=b[0]&127;seq=struct.unpack_from('<H',b,2)[0]
        if kind==1:
            b+=self.read(struct.unpack_from('<I',b,4)[0]*4);self.replies[seq]=b;return
        assert kind!=0,('X error',list(b),self.seq)
        if kind==35:b+=self.read(struct.unpack_from('<I',b,4)[0]*4)
        row={'event':kind,'detail':b[1],'synthetic':bool(b[0]&128),'sequence':seq}
        if kind in (2,3,4,5,6,7,8):
            row.update(window=struct.unpack_from('<I',b,12)[0],root=list(struct.unpack_from('<hh',b,20)),local=list(struct.unpack_from('<hh',b,24)))
        elif kind==33:
            row.update(window=struct.unpack_from('<I',b,4)[0],type=struct.unpack_from('<I',b,8)[0],data=list(struct.unpack_from('<5I',b,12)))
        elif kind==30:
            row.update(zip(('time','owner','requestor','selection','target','property'),struct.unpack_from('<6I',b,4)))
        elif kind==31:
            row.update(zip(('time','requestor','selection','target','property'),struct.unpack_from('<5I',b,4)))
        elif kind==28:
            row.update(window=struct.unpack_from('<I',b,4)[0],property=struct.unpack_from('<I',b,8)[0],state=b[16])
        elif kind==17:row.update(window=struct.unpack_from('<I',b,8)[0])
        elif kind==22:row.update(window=struct.unpack_from('<I',b,8)[0],geometry=list(struct.unpack_from('<hhHH',b,16)))
        self.records.append(row)
        if kind==30 and hasattr(self,'selection_request'):self.selection_request(row)
        if kind==28 and hasattr(self,'property_notify'):self.property_notify(row)
        if kind==17 and hasattr(self,'window_destroyed'):self.window_destroyed(row)

    def reply(self,seq):
        end=time.monotonic()+5
        while seq not in self.replies:
            assert time.monotonic()<end,'X reply timeout'
            self.packet()
        return self.replies.pop(seq)

    def pump(self,seconds=.1):
        end=time.monotonic()+seconds
        while not self.closed and time.monotonic()<end:
            if not select.select([self.sock],[],[],max(0,end-time.monotonic()))[0]:break
            try:self.packet()
            except (EOFError,ConnectionResetError):self.closed=True

    def new(self):
        n=self.base|(self.next_id & self.mask);self.next_id+=1;return n

    def atom(self,name):
        if name not in self.atoms:
            b=name.encode();r=self.reply(self.send(16,struct.pack('<H2x',len(b))+b));self.atoms[name]=struct.unpack_from('<I',r,8)[0]
        return self.atoms[name]

    def prop(self,window,name,kind,value,bits=8):
        if isinstance(value,str):value=value.encode()
        self.send(18,u(window,self.atom(name),self.atom(kind))+struct.pack('<B3xI',bits,len(value)//(bits//8))+value)

    def create(self,title='X11 Fixture',instance='wire-x11',cls='WireX11',box=(50,60,320,240),override=False,parent=None,window_type=None,map_now=True,color=0x285c98):
        window=self.new();x,y,w,h=box
        event_mask=1|2|4|8|16|32|64|(1<<15)|(1<<17)|(1<<21)
        self.send(1,u(window,self.root)+struct.pack('<hhHHHHII',x,y,w,h,0,1,0,(1<<1)|(1<<9)|(1<<11))+u(color,int(override),event_mask))
        self.prop(window,'WM_CLASS','STRING',instance+'\0'+cls+'\0')
        self.prop(window,'WM_NAME','STRING',title)
        self.prop(window,'_NET_WM_PID','CARDINAL',u(os.getpid()),32)
        self.prop(window,'WM_PROTOCOLS','ATOM',u(self.atom('WM_DELETE_WINDOW')),32)
        if parent:self.prop(window,'WM_TRANSIENT_FOR','WINDOW',u(parent),32)
        if window_type:self.prop(window,'_NET_WM_WINDOW_TYPE','ATOM',u(self.atom('_NET_WM_WINDOW_TYPE_'+window_type)),32)
        self.windows[window]={'box':box}
        if map_now:self.map(window)
        return window

    def map(self,window):self.send(8,u(window));self.sync()
    def unmap(self,window):self.send(10,u(window));self.sync()
    def destroy(self,window):self.send(4,u(window));self.sync();self.windows.pop(window,None)
    def configure(self,window,**values):
        fields=['x','y','width','height'];mask=sum(1<<fields.index(k) for k in values)
        self.send(12,u(window)+struct.pack('<H2x',mask)+u(*(values[k] for k in fields if k in values)));self.sync()
    def geometry(self,window):
        r=self.reply(self.send(14,u(window)));return list(struct.unpack_from('<hhHH',r,12))
    def focus(self):return struct.unpack_from('<I',self.reply(self.send(43)),8)[0]
    def sync(self):self.focus()
    def activate(self,window):
        event=struct.pack('<BBHII5I',33,32,0,window,self.atom('_NET_ACTIVE_WINDOW'),1,0,0,0,0)
        self.send(25,u(self.root,(1<<19)|(1<<20))+event);self.sync()
    def paint(self,window,color=0xf8d468):
        gc=self.new();self.send(55,u(gc,window,4,color))
        self.send(70,u(window,gc)+b''.join(struct.pack('<hhHH',x,12,1,100) for x in range(12,150,3)))
        self.send(60,u(gc));self.sync()
    def cursor(self,window):
        font=self.new();self.send(45,u(font)+struct.pack('<H2x',6)+b'cursor')
        cursor=self.new()
        self.send(94,u(cursor,font,font)+struct.pack('<8H',68,69,65535,0,0,65535,65535,65535))
        self.send(2,u(window,1<<14,cursor));self.send(46,u(font));self.sync()
    def close(self):self.sock.close();self.closed=True

    def delete_property(self,window,name):
        self.send(19,u(window,self.atom(name)));self.sync()

    def get_property(self,window,name,delete=False,words=0x1000000):
        r=self.reply(self.send(20,u(window,self.atom(name),0,0,words),int(delete)))
        kind,after,count=struct.unpack_from('<III',r,8)
        return kind,r[1],after,r[32:32+count*(r[1]//8)]

    def message(self,window,name,data,destination=None,mask=(1<<19)|(1<<20)):
        event=struct.pack('<BBHII5I',33,32,0,window,self.atom(name),*(list(data)+[0]*5)[:5])
        self.send(25,u(self.root if destination is None else destination,mask)+event);self.sync()

    def state(self,window,action,*names):
        atoms=[self.atom('_NET_WM_STATE_'+n) for n in names]
        self.message(window,'_NET_WM_STATE',[action]+(atoms+[0,0])[:2]+[2])

    def take_focus(self,window):
        self.send(42,u(window,0),1);self.sync()

    def grab_pointer(self,window,confine=0,cursor=0):
        r=self.reply(self.send(26,u(window)+struct.pack('<HBB',4|8|64,1,1)+u(confine,cursor,0)))
        assert r[1]==0,('GrabPointer',r[1])

    def grab_keyboard(self,window):
        r=self.reply(self.send(31,u(window,0)+bytes([1,1,0,0])))
        assert r[1]==0,('GrabKeyboard',r[1])

    def ungrab(self):
        self.send(27,u(0));self.send(32,u(0));self.sync()

    def children(self,window=None):
        r=self.reply(self.send(15,u(self.root if window is None else window)))
        count=struct.unpack_from('<H',r,16)[0]
        return list(struct.unpack_from('<'+'I'*count,r,32))

    def hidden_cursor(self,window):
        bitmap=self.new();gc=self.new();cursor=self.new()
        self.send(53,u(bitmap,self.root)+struct.pack('<HH',1,1),1)
        self.send(55,u(gc,bitmap,4|8,0,0))
        self.send(70,u(bitmap,gc)+struct.pack('<hhHH',0,0,1,1))
        self.send(93,u(cursor,bitmap,bitmap)+struct.pack('<8H',0,0,0,0,0,0,0,0))
        self.send(2,u(window,1<<14,cursor));self.send(60,u(gc));self.send(54,u(bitmap));self.sync()
        return cursor

    def warp(self,window,x,y):
        self.send(41,u(0,window)+struct.pack('<hhHHhh',0,0,0,0,x,y));self.sync()

    def pointer_position(self,window):
        reply=self.reply(self.send(38,u(window)))
        assert reply[1], 'pointer is on a different X screen'
        return dict(root=list(struct.unpack_from('<hh',reply,16)),local=list(struct.unpack_from('<hh',reply,20)))
