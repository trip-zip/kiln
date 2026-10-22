"""Focused model/prompt/shift-chord/cursor assertions using private native input."""
import json
import os
from pathlib import Path
import re
import subprocess
import time

from PIL import Image

from declaration_checks import check, wait, capture
from layout_checks import DEFAULT
from policy_checks import private_x11
from window_state_checks import launch


def geometry_evidence(h,env,work,label,names):
    rows=[]
    for name in names:
        source="""local c="""+name+""";local s=c.screen;local f=c.float
local b=require('kiln.state').client_boxes[s.name][c.handle]
local p=require('kiln.state').pointer or {x=s.x+f.x+f.width/2,y=s.y+f.y+f.height/2}
local hx,hy=s.x+b.x+b.width/2,s.y+b.y+b.height/2
local hits={};for _,v in ipairs(core.hits(s.name,hx,hy)) do hits[#hits+1]=v.name..'#'..v.index end
return c.handle,s.name,s.x,s.y,f.x,f.y,f.width,f.height,b.x,b.y,b.width,b.height,p.x,p.y,hx,hy,table.concat(hits,',')"""
        fields=h.ev(env,source).decode().strip().split('\t')
        assert len(fields)>=17,fields
        assert "core.surface#"+fields[0] in fields[16],fields
        rows.append(dict(client=int(fields[0]),output=fields[1],origin=list(map(float,fields[2:4])),
                         requested=list(map(float,fields[4:8])),solved=list(map(float,fields[8:12])),
                         pointer=list(map(float,fields[12:14])),hit_sample=list(map(float,fields[14:16])),hits=fields[16:]))
    (work/(label+'.json')).write_text(json.dumps(rows,indent=2)+'\n')


def native(h):
    with private_x11(h.out) as display:
        config = DEFAULT.replace("ui.text('  '", "ui.text((TEXT or '')..'  '") + '''
K=require('kiln');ERR=0;BIND=0;TEXT='';KEYS={};POINTERS={}
K.on('error',function() ERR=ERR+1 end)
K.on('input::key',function(e) KEYS[#KEYS+1]=e end)
K.on('input::motion',function(e) POINTERS[#POINTERS+1]=e end)
K.key{key='F5',press=function() BIND=BIND+1 end}
function textgrab()
 G=K.keygrabber{key=function(e)
  if e.pressed then
   if e.key=='Escape' then G:stop() else TEXT=TEXT..e.utf8;core.dirty() end
  else assert(e.utf8=='') end
 end}
end
K.key{key='F6',press=textgrab}
K.input.repeat_rate=31;K.input.repeat_delay=440
'''
        with h.boot(config,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None,
                                     'LC_ALL':'en_US.UTF-8'}) as (server,env,work,log):
            processes=[];files=[]
            def ev(src): check(h,env,'do '+src+' end',b'\n')
            def yes(src): wait(h,env,'return '+src,b'true\n',server)
            with (work/'wev.log').open('w') as output:
                observer=subprocess.Popen(['stdbuf','-oL','wev'],env=env,stdout=output,stderr=output)
                processes.append(observer)
                try:
                    wait(h,env,'return #client.all()',b'1\n',server)
                    ev("c=client.all()[1];s=c.screen")
                    yes('core.client.focused()==c.handle')
                    window=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1]
                    def xdo(*args):
                        subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);time.sleep(.06)
                    def point(x,y):xdo('mousemove','--window',window,x,y)
                    def seen():return (work/'wev.log').read_text()
                    def edges(text,code):return [int(n) for n in re.findall(r'wl_keyboard\] key:.*?key: '+str(code)+r'; state: (\d)',text)]
                    def no_pointer(text):assert not re.search(r'wl_pointer\] (motion|button|axis):',text),text
                    def geom():return list(map(int,h.ev(env,'return c.float.x,c.float.y,c.float.width,c.float.height').split()))
                    xdo('windowfocus',window);point(300,300)
                    assert 'rate: 31 keys/sec; delay: 440 ms' in seen(),seen()
                    ev("K.input.tap_to_click=true;K.input.natural_scrolling=true;K.input.left_handed=false;K.input.accel_speed=.2;K.input.accel_profile='flat';K.input.scroll_method='two_finger';K.input.click_method='clickfinger';core.input.set_pointer{natural_scrolling=false};core.input.set_pointer{};assert(K.input.tap_to_click and K.input.natural_scrolling and K.input.left_handed==false)")
                    ev('K.input.repeat_delay=390;K.input.repeat_rate=29')
                    time.sleep(.1);assert 'rate: 29 keys/sec; delay: 390 ms' in seen()
                    ev("K.input.keymap={layout='de'}")
                    start=len(seen());xdo('key','y');assert "sym: z" in seen()[start:],seen()[start:]
                    ev("core.input.set_keymap{layout='not-a-real-kiln-map'};assert(not pcall(core.input.set_keymap,{layout={}}));assert(not pcall(core.input.set_cursor_theme,'default',{}));core.input.set_cursor_theme(nil,24)")
                    start=len(seen());xdo('key','y');assert "sym: z" in seen()[start:]
                    ev("K.input.keymap={layout='us',variant='intl'};textgrab()")
                    start=len(seen());xdo('key','F5','apostrophe')
                    check(h,env,'return BIND,TEXT',b'0\t\n')
                    # Replacing the map cannot reset the locale compose sequence.
                    ev("core.input.set_keymap{layout='us',variant='intl'}")
                    xdo('key','e','t');check(h,env,'return TEXT', 'ét\n'.encode())
                    xdo('key','apostrophe','F1','a');check(h,env,'return TEXT','éta\n'.encode())
                    assert not re.search(r'wl_keyboard\] key:',seen()[start:]),seen()[start:]
                    capture(env,work/'composed-grab.png')
                    xdo('key','Escape');yes('not G.active')
                    start=len(seen());xdo('key','b','F5');assert edges(seen()[start:],56)==[1,0]
                    check(h,env,'return BIND',b'1\n')
                    xdo('key','apostrophe','e')
                    ev("local found=false;for i=#KEYS-3,#KEYS do if KEYS[i] and KEYS[i].pressed and KEYS[i].utf8=='é' then found=true end end;assert(found)")
                    # One native command submits a binding that claims, text, and its stop.
                    ev("TEXT='';core.input.set_keymap{layout='us'}")
                    start=len(seen());xdo('key','F6','a','Escape')
                    check(h,env,'return TEXT,G.active','a\tfalse\n'.encode())
                    assert edges(seen()[start:],38)==[] and edges(seen()[start:],9)==[]
                    # Held presses are cancelled on claim, and their releases stay quarantined.
                    xdo('keydown','a');ev('G=K.keygrabber{}');start=len(seen())
                    xdo('keydown','b');ev('G:stop();G:stop()');xdo('keyup','a','b')
                    assert edges(seen()[start:],38)==[] and edges(seen()[start:],56)==[],seen()[start:]
                    assert not re.search(r'key: (38|56); sym:',seen()[start:]),seen()[start:]
                    ev("A=K.keygrabber{stopped=function() N=K.keygrabber{} end};Z=K.keygrabber{};assert(not A.active and not Z.active and N.active);Z:stop()")
                    start=len(seen());xdo('key','a','F5');assert edges(seen()[start:],38)==[]
                    ev('N:stop();G=K.keygrabber{key=function() error("native key grab") end}')
                    xdo('key','a');yes('not G.active and ERR==1')
                    start=len(seen());xdo('key','a');assert edges(seen()[start:],38)==[1,0]
                    # Registering a binding after an ordinary press cannot steal its release.
                    start=len(seen());xdo('keydown','F8')
                    ev("K.key{key='F8',press=function() end}");xdo('keyup','F8')
                    assert edges(seen()[start:],74)==[1,0],seen()[start:]
                    # Modifiers and focus can change under the claim without held keys entering.
                    ev('G=K.keygrabber{}');start=len(seen());xdo('keydown','Shift_L','b')
                    p,f=launch(env,work,'GRAB-FOOT');processes.append(p);files.append(f)
                    wait(h,env,'return #client.all()',b'2\n',server)
                    ev('c:focus()');assert 'wl_keyboard] enter:' not in seen()[start:]
                    ev('G:stop()');xdo('keyup','b','Shift_L')
                    assert not re.search(r'key: 56; sym:',seen()[start:]),seen()[start:]
                    ev("core.input.set_numlock(true)");xdo('key','Caps_Lock')
                    ev('core.input.set_numlock(false)');start=len(seen());xdo('key','a')
                    assert "utf8: 'A'" in seen()[start:];xdo('key','Caps_Lock')
                    ev('core.input.set_numlock(true)');start=len(seen());xdo('key','KP_1')
                    assert 'sym: KP_1' in seen()[start:]
                    # Isolate the observer as a float for pointer protocol evidence.
                    ev('c.floating=true;c.float={x=100,y=100,width=420,height=320};c:focus();c:raise()')
                    yes('c.width==416')
                    ev("K.key{key='F10',press=K.focused(K.placement.centered)}")
                    xdo('key','F10');assert geom()==[302,242,420,320],geom()
                    ev('c.float={x=100,y=100,width=420,height=320}');time.sleep(.1);point(250,250)
                    # Cursor-inclusive captures prove replacement, retention on bad args, and recovery.
                    def cursor_shot(name):
                        subprocess.run(['grim','-c',str(work/(name+'.png'))],env=env,check=True,timeout=5)
                        return Image.open(work/(name+'.png')).convert('RGBA').crop((220,220,310,310)).tobytes()
                    ev("core.input.set_cursor('default')");normal=cursor_shot('cursor-default')
                    ev("M=K.mousegrabber{};core.input.set_cursor('grabbing')");grabbing=cursor_shot('cursor-grab')
                    assert normal!=grabbing,'grab cursor did not change pixels'
                    ev("assert(not pcall(core.input.set_cursor_theme,'default',{}));core.dirty()")
                    time.sleep(.1);assert cursor_shot('cursor-retained')==grabbing
                    ev('M:stop()');time.sleep(.1)
                    assert cursor_shot('cursor-restored')==normal
                    ev('M=K.mousegrabber{}');start=len(seen())
                    point(270,260);xdo('click',1);xdo('click',5);no_pointer(seen()[start:])
                    ev("A=K.mousegrabber{stopped=function() N=K.mousegrabber{} end};Z=K.mousegrabber{};Z:stop();assert(N.active and not Z.active)")
                    start=len(seen());point(280,270);xdo('click',1);no_pointer(seen()[start:])
                    ev('N:stop();N:stop()');start=len(seen());xdo('click',1)
                    assert seen()[start:].count('wl_pointer] button:')==2,seen()[start:]
                    ev('M=K.mousegrabber{button=function() error("native pointer grab") end}')
                    start=len(seen());xdo('click',1);yes('not M.active and ERR==2')
                    assert 'wl_pointer] button:' not in seen()[start:]
                    start=len(seen());xdo('click',1);assert seen()[start:].count('wl_pointer] button:')==2
                    # A claim crossing a client-held button finishes that press once.
                    xdo('mousedown',1);start=len(seen());ev('M=K.mousegrabber{}');time.sleep(.1)
                    assert seen()[start:].count('wl_pointer] button:')==1,seen()[start:]
                    start=len(seen());ev('M:stop()');xdo('mouseup',1);assert 'wl_pointer] button:' not in seen()[start:]
                    # Native modifier move uses a snapshot even while foot/wev commits resize.
                    point(250,250);before=geom();start=len(seen())
                    xdo('keydown','Super_L');xdo('mousedown',1);point(310,285)
                    yes('c.float.x==160 and c.float.y==135')
                    xdo('click',5);xdo('click',2);point(320,295)
                    yes('c.float.x==170 and c.float.y==145')
                    xdo('mouseup',1);xdo('keyup','Super_L');after=geom()
                    assert after==[before[0]+70,before[1]+45,*before[2:]],after
                    assert 'wl_pointer] button:' not in seen()[start:]
                    point(350,300);assert geom()==after
                    capture(env,work/'native-moved.png');geometry_evidence(h,env,work,'native-moved',['c'])
                    # Titlebar also scopes the initiating press, including no-motion tile-to-float.
                    ev('c.floating=false');time.sleep(.15)
                    b=list(map(int,h.ev(env,"local b=require('kiln.state').client_boxes[s.name][c.handle];return b.x,b.y,b.width,b.height").split()))
                    point(b[0]+40,b[1]+12);xdo('mousedown',1);xdo('mouseup',1)
                    yes('c.floating');assert geom()==b,(geom(),b)
                    point(b[0]+40,b[1]+12);xdo('mousedown',1);point(b[0]+70,b[1]+32);xdo('mouseup',1)
                    assert geom()==[b[0]+30,b[1]+20,*b[2:]],geom()
                    ev('c.float={x=100,y=100,width=420,height=320}');time.sleep(.1)
                    point(450,350);xdo('keydown','Super_L');xdo('mousedown',3);point(470,365);xdo('mouseup',3);xdo('keyup','Super_L')
                    assert geom()==[100,100,440,335],geom()
                    # All compass edges use a fresh, fixed snapshot and whole-table updates.
                    ev("K.button.clear();K.button{mods={'super'},button=3,press=function(w) w:grab_resize(EDGE) end}")
                    for edge in ('n','s','e','w','ne','nw','se','sw'):
                        ev("c.float={x=100,y=100,width=420,height=320};EDGE="+json.dumps(edge));time.sleep(.1)
                        point(250,250);xdo('keydown','Super_L');xdo('mousedown',3);point(275,265)
                        xdo('mouseup',3);xdo('keyup','Super_L')
                        expected=[100+(25 if 'w' in edge else 0),100+(15 if 'n' in edge else 0),420+(25 if 'e' in edge else -25 if 'w' in edge else 0),320+(15 if 's' in edge else -15 if 'n' in edge else 0)]
                        assert geom()==expected,(edge,geom(),expected)
                    ev("c.float={x=100,y=100,width=420,height=320};EDGE='nw'");time.sleep(.1)
                    point(250,250);xdo('keydown','Super_L');xdo('mousedown',3);point(850,700)
                    assert geom()==[460,360,60,60],geom()
                    point(275,265);assert geom()==[125,115,395,305],geom()
                    xdo('mouseup',3);xdo('keyup','Super_L');capture(env,work/'native-resized.png');geometry_evidence(h,env,work,'native-resized',['c'])
                    # Hit the actual southeast handle through the published Clay handler.
                    ev('c.float={x=100,y=100,width=420,height=320}');time.sleep(.1)
                    point(517,417);ev("local hit=false;for _,h in ipairs(core.hits(s.name,517,417)) do if h.name=='resize_se' then hit=true end end;assert(hit)")
                    xdo('mousedown',1);point(547,437);xdo('mouseup',1)
                    assert geom()==[100,100,450,340],geom()
                    # Replacement ends the drag; teardown of its client ends another.
                    point(547,437);xdo('mousedown',1);ev('M=K.mousegrabber{}');frozen=geom();point(560,450);assert geom()==frozen
                    ev('M:stop()');xdo('mouseup',1)
                    ev("EDGE='se'");point(250,250);xdo('keydown','Super_L');xdo('mousedown',3)
                    ev('c:close()');wait(h,env,'return #client.all()',b'1\n',server)
                    ev("assert(not require('kiln.grab').pointer_active())")
                    xdo('mouseup',3);xdo('keyup','Super_L')
                    ev('K.keygrabber{};K.mousegrabber{}')
                    h.quit(server,env,log)
                    assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
                    assert 'Input cleanup: keyboards 0, pointers 0, keyboard claim false, pointer claim false' in log.read_text()
                finally:
                    for p in processes:
                        if p.poll() is None:p.terminate()
                        p.wait(timeout=5)
                    for f in files:f.close()
    print('PASS: native input settings/compose, exclusive claims and recovery, held input, all resize edges, titlebar/handle/modifier drags:',work.resolve(),flush=True)


def run(h):
    native(h)
    placement(h)


def placement(h):
    prefix="""
local set=core.set_event_handler
core.set_event_handler=function(fn) DISPATCH=fn;set(fn) end
"""
    config="H=36\n"+prefix+DEFAULT.replace("h=36","h=H")+'''
K=require('kiln');s1,s2=unpack(screen.all())
K.rule{match={app='B'},props={screen=s2,floating=true},on=K.placement.bottom_right}
'''
    with h.boot(config,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        processes=[];files=[]
        def ev(src):check(h,env,'do '+src+' end',b'\n')
        def yes(src):wait(h,env,'return '+src,b'true\n',server)
        def geom():return list(map(int,h.ev(env,'return b.float.x,b.float.y,b.float.width,b.float.height').split()))
        try:
            for name in ('A','B','C'):
                p,f=launch(env,work,name);processes.append(p);files.append(f)
                wait(h,env,'return #client.all()',f'{len(processes)}\n'.encode(),server)
            ev("for _,c in ipairs(client.all()) do if c.app_id=='A' then a=c elseif c.app_id=='B' then b=c else other=c end end;assert(s2.x~=0 and b.screen==s2);P=K.placement;state=require('kiln.state')")
            yes('b.width==b.float.width-4')
            ev('assert(b.float.x+b.float.width==s2.width and b.float.y+b.float.height==s2.height)')
            # Every helper uses the target output even when the other solved last.
            ev("b.float={x=17,y=23,width=240,height=180};core.hits(s1.name,20,50)")
            for name,at in {'centered':(.5,.5),'center_horizontal':(.5,None),'center_vertical':(None,.5),
                            'left':(0,.5),'right':(1,.5),'top':(.5,0),'bottom':(.5,1),'top_left':(0,0),
                            'top_right':(1,0),'bottom_left':(0,1),'bottom_right':(1,1)}.items():
                ev('b.float={x=17,y=23,width=240,height=180};assert(P.'+name+'(b)==b)')
                wa=list(map(int,h.ev(env,'local w=s2.workarea;return w.x,w.y,w.width,w.height').split()))
                expected=[17 if at[0] is None else wa[0]+int(at[0]*(wa[2]-240)),23 if at[1] is None else wa[1]+int(at[1]*(wa[3]-180)),240,180]
                assert geom()==expected,(name,geom(),expected)
            ev('b.float={x=-20,y=900,width=1800,height=900};P.no_offscreen(b)')
            assert geom()[:2]==[0,36]
            ev('b.float={x=17,y=23,width=240};P.top_left(b);assert(b.float.height==b.height)')
            ev('b.float={width=240,height=180};state.pointer=nil;P.under_mouse(b)')
            assert geom()==[520,288,240,180],geom()
            # Coordinates in these headless legs are explicitly synthetic facts.
            ev("DISPATCH{class='input',name='motion',screen=s2.name,x=s2.x+400,y=s2.y+300};P.under_mouse(b)")
            assert geom()==[280,210,240,180],geom()
            ev('state.pointer={x=s2.x+9000,y=-500};P.under_mouse(b)');assert geom()==[1040,36,240,180]
            ev('a.floating=true;a.float={x=120,y=100,width=380,height=280};P.centered(a);P.bottom_right(b)')
            time.sleep(.2);capture(env,work/'placement-both-outputs.png');geometry_evidence(h,env,work,'placement-both-outputs',['a','b'])
            ev('other.tag=s2.selected_tag;other.floating=true;other.float={x=0,y=36,width=240,height=180};b.float={x=99,y=99,width=240,height=180};P.no_overlap(b)')
            assert geom()==[240,36,240,180],geom()
            ev('other.tags={s2.tags[1],s2.tags[2]};P.no_overlap(b)');assert geom()==[240,36,240,180]
            ev('other.tag=s2.tags[2];other.sticky=true;P.no_overlap(b)');assert geom()==[240,36,240,180]
            ev('other.minimized=true;P.no_overlap(b)');assert geom()==[0,36,240,180]
            ev('other.minimized=false;other.sticky=false;P.no_overlap(b)');assert geom()==[0,36,240,180]
            ev('other.sticky=true;other.float={x=0,y=36,width=s2.width,height=s2.height-36};b.float={x=9000,y=-9,width=240,height=180};P.no_overlap(b)')
            assert geom()==[1040,36,240,180]
            ev('other.minimized=true;b.float={x=100,y=100,width=420,height=320};b:focus()')
            yes('b.width==416')
            # Use live Clay hits and a global-coordinate button fact on output two.
            ev("K.button.clear();K.button{button=3,press=function(c) c:grab_resize_nearest() end};DISPATCH{class='input',name='button',client=b.handle,screen=s2.name,x=s2.x+120,y=s2.y+140,button=3,pressed=true,mods={}}")
            ev("DISPATCH{class='input',name='motion',screen=s2.name,x=s2.x+145,y=s2.y+155}")
            assert geom()==[125,115,395,305],geom()
            ev("DISPATCH{class='input',name='button',button=3,pressed=false,screen=s2.name,x=s2.x+145,y=s2.y+155}")
            time.sleep(.15);capture(env,work/'nonorigin-resized.png');geometry_evidence(h,env,work,'nonorigin-resized',['b'])
            ev("K.button.clear();K.button{button=1,press=function(c) c:grab_move() end};DISPATCH{class='input',name='button',client=b.handle,screen=s2.name,x=s2.x+200,y=200,button=1,pressed=true,mods={}}")
            ev("DISPATCH{class='input',name='motion',screen=s1.name,x=100,y=220};assert(b.screen==s2 and #b.tags==1)")
            ev("DISPATCH{class='input',name='button',button=1,pressed=false,screen=s1.name,x=100,y=220};assert(not require('kiln.grab').pointer_active());P.centered(b)")
            yes('b.width==391')
            remembered=geom()
            for _ in range(3):
                ev('b.floating=false');time.sleep(.1);ev('b.floating=true');time.sleep(.1)
                assert geom()==remembered
            # Changing chrome/workarea and placement settles without configure drift.
            ev('K.theme.titlebar_height=28;core.dirty(s2.name);P.top_right(b)')
            yes('b.height==b.float.height-32')
            ev('H=64;core.dirty(s2.name)');yes('s2.workarea.y==64');ev('P.top_right(b)');assert geom()[1]==64
            time.sleep(.2);capture(env,work/'nonorigin-placed.png');geometry_evidence(h,env,work,'nonorigin-placed',['b'])
            before=log.read_text().count('Layout ')
            time.sleep(.3);assert log.read_text().count('Layout ')==before
            ev("DISPATCH{class='input',name='button',client=b.handle,screen=s2.name,x=s2.x+200,y=200,button=1,pressed=true,mods={}};DISPATCH{class='output',name='remove',output=s2.name};assert(not require('kiln.grab').pointer_active())")
            h.quit(server,env,log)
            assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
        finally:
            for p in processes:
                if p.poll() is None:p.terminate()
                p.wait(timeout=5)
            for f in files:f.close()
    print('PASS: all placements, occupancy/fallbacks, two real outputs, synthetic nonorigin drag/crossing/output-loss legs:',work.resolve(),flush=True)
