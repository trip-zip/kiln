"""X11 metadata and state assertions over the inner wire and public Lua model."""
import c_baseline
import json
from pathlib import Path
import struct
from PIL import Image
from declaration_checks import check,wait,settle,capture
from xwayland_checks import until,dependencies,xcommand
from x11_client import XClient,u

CONFIG='''
K=require('kiln');MAPS=0;URGENT={}
K.rule{match={role='^pop%-up$'},props={role_rule=true,no_focus=true}}
screen.on('added',function(s)
 tag.new{name='one',screen=s,layout=K.layout.tile};s.tags[1]:view()
 K.ui.bar(s,{h=32,color='#202020'},function()K.widgets.tasklist(s)end)
end)
client.on('map',function(c)MAPS=MAPS+1 end)
client.on('request::urgent',function(c,on)URGENT[#URGENT+1]=on end)
'''


def metadata(h):
    dependencies()
    with h.boot(CONFIG,overrides={'DISPLAY':None,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
        inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip()
        x=XClient(inner)
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        def yes(s):wait(h,env,'return '+s,b'true\n',server)
        def icon(words):x.prop(w,'_NET_WM_ICON','CARDINAL',u(*words),32);x.sync()
        def pixel(label,color):
            settle(log);path=work/(label+'.png');capture(env,path)
            xy=list(map(float,h.ev(env,"local b=core.box({'taskicon',A.handle});assert(b);return b.x+b.width/2,b.y+b.height/2").split()))
            actual=Image.open(path).convert('RGB').getpixel(tuple(map(int,xy)))
            assert actual==color,(label,actual,color)
            yes("(function()local b=core.box({'taskicon',A.handle});for _,v in ipairs(core.hits(A.screen.name,b.x+b.width/2,b.y+b.height/2))do if v.name=='taskicon' and v.index==A.handle then return true end end return false end)()")
        try:
            w=x.create(map_now=False)
            x.prop(w,'WM_WINDOW_ROLE','STRING','pop-up')
            types=['DIALOG','UNKNOWN_FIXTURE','UTILITY','NORMAL']
            x.prop(w,'_NET_WM_WINDOW_TYPE','ATOM',u(*(x.atom('_NET_WM_WINDOW_TYPE_'+n) for n in types)),32)
            x.prop(w,'WM_HINTS','WM_HINTS',u(1|256,1,1,0,0,0,0,0,0),32)
            icon([8,8]+[0xffff0000]*64+[16,16]+[0xff00ff00]*256)
            x.map(w);yes('#client.all()==1');ev('A=client.all()[1];AH=A.handle')
            print(h.ev(env,"return A.role,A.role_rule,A.icon,A.urgent,A.window_type and table.concat(A.window_type,',')"),flush=True)
            yes("A.role=='pop-up' and A.role_rule and A.icon=='xwl-icon:'..A.handle and A.urgent and table.concat(A.window_type,',')=='dialog,utility,normal'")
            pixel('largest-icon',(0,255,0))
            # Replacing pixels retains the key but must invalidate the visible raster.
            icon([16,16]+[0xff3070d0]*256);pixel('replaced-icon',(48,112,208))
            x.prop(w,'WM_WINDOW_ROLE','STRING','replacement');x.sync();yes("A.role=='replacement'")
            x.prop(w,'_NET_WM_WINDOW_TYPE','ATOM',u(x.atom('_NET_WM_WINDOW_TYPE_NORMAL'),x.atom('_NET_WM_WINDOW_TYPE_DIALOG')),32)
            yes("table.concat(A.window_type,',')=='normal,dialog'")
            x.prop(w,'WM_HINTS','WM_HINTS',u(1,1,1,0,0,0,0,0,0),32);x.sync();yes('A.urgent==false and URGENT[#URGENT]==false')
            x.prop(w,'WM_HINTS','WM_HINTS',u(257,1,1,0,0,0,0,0,0),32);x.sync();yes('A.urgent==true')
            x.delete_property(w,'WM_HINTS');yes('A.urgent==false')
            before=log.read_text().count('X11 icon handle=')
            ev('K.reload()');yes('#client.all()==1');ev("A=require('kiln.object').lookup(AH)")
            yes("A.role=='replacement' and A.icon=='xwl-icon:'..AH and table.concat(A.window_type,',')=='normal,dialog'")
            assert log.read_text().count('X11 icon handle=')==before,'replay fetched icon'
            pixel('replayed-icon',(48,112,208))
            for label,words in [('empty',[]),('truncated',[16,16,1]),('overflow',[0xffffffff,0xffffffff]),('odd',[1]),('zero',[0,0])]:
                icon(words);yes('A.icon==nil');h.healthy(env)
                icon([1,1,0xff3070d0]);yes('A.icon~=nil')
            for name in ['WM_WINDOW_ROLE','_NET_WM_WINDOW_TYPE','_NET_WM_ICON','WM_CLASS']:
                x.delete_property(w,name)
            yes('A.role==nil and A.window_type==nil and A.icon==nil and A.class==nil and A.instance==nil')
            x.unmap(w);yes('not A.mapped')
            x.prop(w,'WM_WINDOW_ROLE','STRING','remapped');icon([16,16]+[0xffa04060]*256);x.map(w)
            yes("A.mapped and A.handle==AH and A.role=='remapped' and A.icon=='xwl-icon:'..AH")
            pixel('remapped-icon',(160,64,96))
            # Normal hints are read by wlroots, but do not constrain Clay geometry.
            normal=[(1<<4)|(1<<5)|(1<<6)|(1<<7)|(1<<8),0,0,0,0,77,63,77,63,13,17,1,1,1,1,77,63,1]
            x.prop(w,'WM_NORMAL_HINTS','WM_SIZE_HINTS',u(*normal),32);x.sync();settle(log)
            assert x.geometry(w)[2:]!=[77,63]
            (work/'independent-x-properties.txt').write_bytes(xcommand(dict(env,DISPLAY=inner),'xprop','-id',w,'WM_WINDOW_ROLE','WM_NORMAL_HINTS','_NET_WM_ICON'))
            # Repeated forced declarations retain image pixels and scene owners.
            ev('core.dirty()');settle(log);ev('core.dirty()');settle(log)
            assert 'rasters 0' in log.read_text().split('Paint ')[-1],log.read_text()[-1000:]
            (work/'metadata-wire.json').write_text(json.dumps({'inner':inner,'window':w,'events':x.records},indent=2)+'\n')
            h.quit(server,env,log)
        finally:x.close()
    print('PASS: real X11 pre-map/live role, ordered types, urgency, largest/replaced/deleted/malformed icons, remap, replay and ignored size hints',flush=True)


def states(h):
    from layout_checks import DEFAULT
    with h.boot("""RAW={};local set=core.set_event_handler;core.set_event_handler=function(fn)set(function(e)if e.class=='client' then RAW[#RAW+1]=e end;fn(e)end)end
"""+DEFAULT+"\nK=require('kiln')",overrides={'DISPLAY':None,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
        inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip();x=XClient(inner)
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        def yes(s):wait(h,env,'return '+s,b'true\n',server)
        def atoms():
            data=x.get_property(w,'_NET_WM_STATE')[3]
            return set(struct.unpack('<'+'I'*(len(data)//4),data))
        def has(name):return x.atom('_NET_WM_STATE_'+name) in atoms()
        rows=[]
        try:
            w=x.create(map_now=False)
            x.prop(w,'_NET_WM_STATE','ATOM',u(x.atom('_NET_WM_STATE_FULLSCREEN')),32);x.sync()
            print('before-map',x.get_property(w,'_NET_WM_STATE'),flush=True);x.map(w)
            yes('#client.all()==1');ev('A=client.all()[1]');print(h.ev(env,"local t={} for _,e in ipairs(RAW)do t[#t+1]=e.name..':'..tostring(e.fullscreen)..':'..tostring(e.on)end return A.fullscreen,table.concat(t,',')"),flush=True);yes('A.fullscreen==true');settle(log)
            assert x.geometry(w)==[0,0,1280,720]
            for action,on in [(0,False),(1,True),(2,False),(2,True),(0,False)]:
                x.state(w,action,'FULLSCREEN');yes('A.fullscreen=='+str(on).lower());settle(log)
                assert has('FULLSCREEN')==on
                assert (x.geometry(w)==[0,0,1280,720])==on
                rows.append(dict(state='fullscreen',action=action,on=on,box=x.geometry(w),atoms=list(atoms())))
            for action,on in [(1,True),(0,False),(2,True),(2,False)]:
                x.state(w,action,'MAXIMIZED_VERT','MAXIMIZED_HORZ');yes('A.maximized=='+str(on).lower());settle(log)
                assert has('MAXIMIZED_VERT')==on and has('MAXIMIZED_HORZ')==on
            ev("ASK=nil;A:on('request::maximize',function(c,on)ASK=on end)")
            x.state(w,1,'MAXIMIZED_VERT');yes('ASK==false and not A.maximized');settle(log)
            assert not has('MAXIMIZED_VERT') and not has('MAXIMIZED_HORZ'),'partial maximize escaped both-axes policy'
            for action,on in [(1,True),(0,False),(2,True),(2,False)]:
                x.state(w,action,'HIDDEN');yes('A.minimized=='+str(on).lower());settle(log)
                assert has('HIDDEN')==on
                state=x.get_property(w,'WM_STATE')[3];assert struct.unpack_from('<I',state)[0]==(3 if on else 1)
            for on in [True,False]:
                x.message(w,'WM_CHANGE_STATE',[3 if on else 1]);yes('A.minimized=='+str(on).lower())
            for name,prop,handler in [('FULLSCREEN','fullscreen','fullscreen'),('MAXIMIZED_VERT','maximized','maximize'),('HIDDEN','minimized','minimize')]:
                ev('ASK=nil;K.defaults.'+handler+'=function(c,on)ASK=on end')
                old=x.geometry(w)
                x.state(w,1,*([name,'MAXIMIZED_HORZ'] if handler=='maximize' else [name]))
                yes('ASK==true and not A.'+prop);settle(log)
                assert not has(name),(handler,'refused request still advertised',atoms())
                assert x.geometry(w)==old
            ev('K.defaults.fullscreen=function(c,on)c.maximized=on end')
            x.state(w,1,'FULLSCREEN');yes('A.maximized and not A.fullscreen');settle(log)
            assert has('MAXIMIZED_VERT') and has('MAXIMIZED_HORZ') and not has('FULLSCREEN')
            (work/'state-wire.json').write_text(json.dumps(rows,indent=2)+'\n')
            h.quit(server,env,log)
        finally:x.close()
    print('PASS: initial/fullscreen/maximize/minimize add/remove/toggle, both-axis policy, refused/altered handlers with independent X state and geometry',flush=True)


def negotiation(h):
    from layout_checks import DEFAULT
    with h.boot(DEFAULT+"\nK=require('kiln')",overrides={'DISPLAY':None,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
        inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip();x=XClient(inner);other=XClient(inner)
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        def yes(s):wait(h,env,'return '+s,b'true\n',server)
        def protocol(window,name):
            x.pump(.2)
            return [r for r in x.records if r['event']==33 and r['window']==window and r['type']==x.atom('WM_PROTOCOLS') and r['data'][0]==x.atom(name)]
        try:
            a=x.create(instance='focus-passive');yes('#client.all()==1');ev('A=client.all()[1]')
            until(lambda:x.focus()==a,'passive X focus')
            b=x.create(instance='focus-global',map_now=False)
            x.prop(b,'WM_HINTS','WM_HINTS',u(1,0,1,0,0,0,0,0,0),32)
            x.prop(b,'WM_PROTOCOLS','ATOM',u(x.atom('WM_TAKE_FOCUS'),x.atom('WM_DELETE_WINDOW')),32)
            x.map(b);yes('#client.all()==2');ev("for _,c in ipairs(client.all())do if c.instance=='focus-global' then B=c end end")
            until(lambda:bool(protocol(b,'WM_TAKE_FOCUS')),'globally active focus offer')
            assert x.focus()!=b,'input=false was focused without its acceptance'
            x.take_focus(b);until(lambda:x.focus()==b,'client accepted focus')
            ev('B:close()');until(lambda:bool(protocol(b,'WM_DELETE_WINDOW')),'polite close message')
            yes('B.mapped');x.destroy(b);yes('#client.all()==1')
            # Without WM_DELETE_WINDOW, wlroots disconnects the owning X connection.
            c=other.create(instance='no-delete');yes('#client.all()==2')
            other.delete_property(c,'WM_PROTOCOLS')
            ev("for _,c in ipairs(client.all())do if c.instance=='no-delete' then C=c end end")
            ev('C:close()');other.pump(.2);assert other.closed
            yes('#client.all()==1');assert x.geometry(a)[2]>0
            (work/'focus-close-wire.json').write_text(json.dumps(x.records,indent=2)+'\n')
            h.quit(server,env,log)
        finally:x.close();other.close()
    print('PASS: WM_HINTS input, passive/globally-active focus negotiation, WM_TAKE_FOCUS acceptance and polite/fallback close',flush=True)


def run(h):metadata(h);states(h);negotiation(h)



if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-xmetadata-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
