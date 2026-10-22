"""Public Clay inspector state, persistence, recovery and private native input."""
import c_baseline
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import time
from declaration_checks import settle,wait
from paint_checks import screenshot
from policy_checks import private_x11
from protocol_client import Client
ROOT=Path(__file__).resolve().parents[1]
CONFIG='''K=require('kiln');ui=K.ui
screen.on('added',function(s) tag.new{name='one',screen=s} end)
ROOTCLICKS=0
K.button{button=1,on='root',press=function() ROOTCLICKS=ROOTCLICKS+1 end}
function draw(sn,w,h)
 ui.column({id='desktop',w='grow',h='grow',color='#123456'},function()
  for _,c in ipairs(client.all()) do if c.screen.name==sn then ui.surface(c,{w=200,h=100}) end end
  for i=1,35 do ui.box({id={'row',i},w=180,h=20,color=i%2==0 and '#304050' or '#506070'},function() ui.text('Inspector row '..i,{size=14}) end) end
 end)
 if BAD then error('inspector declaration failure') end
 if HUGE then ui.box{w=100000,h=100000,radius=4,color='#ffffff'} end
end
core.set_frame_handler(draw)
'''
def run(h):
    headless(h)
    fractional(h)
    with private_x11(h.out) as display:
      with h.boot(CONFIG,overrides={'WLR_BACKENDS':'x11','DISPLAY':display}) as (server,env,work,log):
        def ev(code):return h.ev(env,code).decode().strip()
        def change(code):
            result=ev(code+';core.dirty()');assert not result.startswith('ERROR'),result
            time.sleep(.12);settle(log)
        windows=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines();window=windows[-1]
        def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5)
        def point(x,y):xdo('mousemove','--window',window,x,y);time.sleep(.08)
        xdo('windowfocus',window)
        w,hgt=map(int,ev('local o=core.output.list()[1];return o.width,o.height').split())
        assert ev('return core.inspector("X11-1")')=='false'
        change('core.inspector("X11-1",true)')
        assert ev('return core.box("Clay__RootContainer").width')==str(w-400)
        def names(x,y):return ev(f'local a={{}};for _,v in ipairs(core.hits("X11-1",{x},{y})) do a[#a+1]=v.name end;return table.concat(a,",")')
        assert 'Clay__DebugView' in names(w-100,100)
        assert 'Clay__DebugViewWarnings' in names(w-100,hgt-150)
        screenshot(env,work/'open.png','X11-1')
        # A click whose press and release arrive together must still select.
        point(w-150,75);xdo('mousedown',1,'mouseup',1);time.sleep(.2);settle(log)
        assert 'Clay__DebugViewWarnings' not in names(w-100,hgt-150)
        assert ev('return ROOTCLICKS')=='0'
        selected=screenshot(env,work/'selected.png','X11-1')
        point(w-358,75);xdo('mousedown',1,'mouseup',1);time.sleep(.2);settle(log)
        collapsed=screenshot(env,work/'collapsed.png','X11-1')
        assert collapsed.tobytes()!=selected.tobytes()
        change('K.reload()')
        assert screenshot(env,work/'collapsed-reloaded.png','X11-1').tobytes()==collapsed.tobytes()
        point(w-358,75);xdo('mousedown',1,'mouseup',1);time.sleep(.2);settle(log)
        point(w-150,75);settle(log)
        assert screenshot(env,work/'expanded.png','X11-1').tobytes()==selected.tobytes()
        for i in range(4):
            change('core.dirty()')
            assert screenshot(env,work/f'persistent-{i}.png','X11-1').tobytes()==selected.tobytes()
        change('K.reload()')
        assert screenshot(env,work/'reloaded-selection.png','X11-1').tobytes()==selected.tobytes()
        for flag in ['BAD','HUGE']:
            change(flag+'=true')
            assert screenshot(env,work/(flag+'-failed.png'),'X11-1').tobytes()==selected.tobytes()
            assert 'Clay__DebugViewWarnings' not in names(w-100,hgt-150)
            change(flag+'=false')
            assert screenshot(env,work/(flag+'-repaired.png'),'X11-1').tobytes()==selected.tobytes()
        # Queries over the close button cannot change the seat or close state.
        for i in range(8):names(w-16,15)
        change('core.dirty()')
        assert ev('return core.inspector("X11-1")')=='true'
        assert screenshot(env,work/'after-queries.png','X11-1').tobytes()==selected.tobytes()
        # An input edge during raster rejection can update Clay's private selection.
        # Published pixels stay atomic; public APIs cannot snapshot that selection.
        change('HUGE=true')
        point(w-150,103);xdo('mousedown',1,'mouseup',1);time.sleep(.2)
        assert screenshot(env,work/'input-rejected.png','X11-1').tobytes()==selected.tobytes()
        change('HUGE=false')
        repaired=screenshot(env,work/'input-repaired.png','X11-1')
        (work/'recovery-tradeoff.json').write_text(json.dumps({'private_selection_advanced':repaired.tobytes()!=selected.tobytes()})+'\n')
        assert ev('return ROOTCLICKS')=='0'
        point(w-150,150);xdo('click',5);time.sleep(.15)
        assert float(ev('return core.inspector_scroll("X11-1")'))<0
        screenshot(env,work/'scrolled.png','X11-1')
        offset=ev('return core.inspector_scroll("X11-1")')
        for i in range(4):change('core.dirty()');assert ev('return core.inspector_scroll("X11-1")')==offset
        point(w-150,hgt-100)
        detail=screenshot(env,work/'details-before.png','X11-1')
        xdo('click',5);time.sleep(.15);settle(log)
        details=screenshot(env,work/'details-scrolled.png','X11-1')
        assert details.tobytes()!=detail.tobytes()
        assert ev('return core.inspector_scroll("X11-1")')==offset
        change('core.dirty()')
        assert screenshot(env,work/'details-persistent.png','X11-1').tobytes()==details.tobytes()
        # Unknown/palette fields fail atomically before even changing enabled.
        assert ev('return pcall(core.inspector,"X11-1",{enabled=false,color1={}})').startswith('false')
        assert ev('return core.inspector("X11-1")')=='true'
        change('core.inspector("X11-1",{width=300})')
        assert ev('return core.box("Clay__RootContainer").width')==str(w-300)
        change('core.inspector("X11-1",{width=400})')
        point(300,300);xdo('click',1);time.sleep(.15)
        assert ev('return ROOTCLICKS')=='1'
        point(w-16,15);xdo('mousedown',1,'mouseup',1);time.sleep(.2);settle(log)
        assert ev('return core.inspector("X11-1")')=='false'
        assert ev('return core.box("Clay__RootContainer").width')==str(w)
        screenshot(env,work/'closed.png','X11-1')
        h.quit(server,env,log)
    print('PASS: inspector public toggle/width, row selection/persistence, wheel, fast click, query isolation, failed-frame recovery, root consumption and self-close:',work)


def fractional(h):
    config=(ROOT/'kilnrc.lua').read_text()+'\n'+CONFIG[CONFIG.index('function draw'):]
    with private_x11(h.out) as display:
      with h.boot(config,overrides={'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2','DISPLAY':display}) as (server,env,work,log):
        peer=Client(env)
        def ev(code):return h.ev(env,code).decode().strip()
        def change(code):
            assert not ev(code+';core.dirty()').startswith('ERROR')
            peer.pump(.2);settle(log)
        def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);peer.pump(.12)
        try:
            change('for _,s in ipairs(screen.all())do if s.name=="X11-2" then S=s end end;S.scale=1.3;core.output.set_position(S.name,-901,47);screen.focused=S')
            peer.toplevel('fractional-inspector');peer.pump(.2)
            change('client.all()[1]:move_to(S)')
            windows=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines();window=windows[-1]
            w,hh=map(float,ev('return S.width,S.height').split())
            def point(x,y):xdo('mousemove','--window',window,round(x*1024/w),round(y*768/hh))
            xdo('windowraise',window);xdo('windowfocus',window);point(50,50)
            xdo('key','super+shift+i');settle(log)
            assert ev('return core.inspector("X11-2"),core.inspector("X11-1")')=='true\tfalse'
            point(w-150,75);xdo('mousedown',1,'mouseup',1);settle(log)
            names=ev(f'local a={{}};for _,v in ipairs(core.hits(S.name,S.x+{w-100},S.y+{hh-100}))do a[#a+1]=v.name end;return table.concat(a,",")')
            assert 'Clay__DebugViewWarnings' not in names,names
            screenshot(env,work/'fractional-selected.png','X11-2')
            # Hover-highlight over the native surface must not intercept its click.
            point(50,50);start=len(peer.records);xdo('mousedown',1,'mouseup',1)
            assert len([r for r in peer.records[start:] if r.get('input')=='pointer' and r['op']==3])==2,peer.records[start:]
            point(w-150,150);xdo('click',5);settle(log)
            assert float(ev('return core.inspector_scroll("X11-2")'))<0
            screenshot(env,work/'fractional-scrolled.png','X11-2')
            point(w-16,15);xdo('mousedown',1,'mouseup',1);settle(log)
            assert ev('return core.inspector("X11-2")')=='false'
            screenshot(env,work/'fractional-closed.png','X11-2')
            h.quit(server,env,log)
        finally:peer.close()
    print('PASS: stock inspector chord, fractional negative-origin native row/wheel/close input and highlighted client input passthrough:',work)


def headless(h):
    with h.boot((ROOT/'kilnrc.lua').read_text(),overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        def ev(code):return h.ev(env,code).decode().strip()
        def change(code):
            assert not ev(code+';core.dirty()').startswith('ERROR')
            time.sleep(.15);settle(log)
        def root(name):
            return float(ev(f'core.hits("{name}",0,0);return core.box("Clay__RootContainer").width'))
        peers=[Client(env),Client(env)]
        try:
            for i,c in enumerate(peers):c.toplevel('inspector-'+str(i));c.pump(.15)
            wait(h,env,'return #client.all()',b'2\n',server);settle(log)
            change('for _,s in ipairs(screen.all())do if s.name=="HEADLESS-1" then S1=s else S2=s end end;for _,c in ipairs(client.all())do c:move_to(S1) end')
            before=root('HEADLESS-1')
            change('core.inspector("HEADLESS-1",true)')
            assert root('HEADLESS-1')==before-400 and root('HEADLESS-2')==before
            change('core.output.set_position("HEADLESS-2",-401,99);core.output.set_scale("HEADLESS-2",1.3);core.inspector("HEADLESS-2",{enabled=true})')
            assert root('HEADLESS-2')==float(ev('return S2.width'))-400
            for name in ['HEADLESS-1','HEADLESS-2']:
                image=screenshot(env,work/(name+'-open.png'),name)
                assert image.getbbox() is not None
            change('core.inspector("HEADLESS-1",{width=300})')
            assert root('HEADLESS-1')==before-300
            assert root('HEADLESS-2')==float(ev('return S2.width'))-300
            change('core.inspector("HEADLESS-1",{width=400})')
            # Width changes still flow through the stock workarea and tiled cells.
            assert ev('local s=S1;core.hits(s.name,0,0);return s.workarea.width')==str(int(before-400))
            change('K=require("kiln");K.reload()')
            assert ev('return core.inspector("HEADLESS-1"),core.inspector("HEADLESS-2")')=='true\ttrue'
            # Lock coverage owns the entire output, with no debug context enabled there.
            path=work/'locked-inspector.png'
            key=ev('assert(core.lock());return core.screenshot("HEADLESS-1",'+json.dumps(str(path))+')')
            from PIL import Image
            assert key.startswith('screenshot:') and Image.open(path).convert('RGB').getbbox() is None
            h.quit(server,env,log)
        finally:
            for c in peers:c.close()
    print('PASS: two-client/two-output stock inspector reflow, global width, fractional negative origin, reload and immediate lock coverage:',work)

if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    out=Path(tempfile.mkdtemp(prefix='kiln-inspector-check-',dir='/tmp'));print(out,flush=True)
    run(m.Harness(ROOT/'build/kiln',c_baseline.source(),out))
