"""Native stock desktop interaction and real scheduled updates on owned displays."""
import c_baseline
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
from declaration_checks import check, wait, settle, capture
from policy_checks import private_x11
from window_state_checks import launch, stop, counts
from stock_checks import ROOT, STOCK, HELPERS, private_data, entry


def native(h):
    data,system,cache=private_data(h.out/'native-data')
    entry(data/'applications/fixture.desktop','Native Foot',"foot --app-id=native-launch sh -c 'sleep 1000'")
    config=STOCK+HELPERS+'''
VALUE=.25;TOGGLE=false;FIRED=0
K.on_declare(function(s)
 ui.row({id='forms',w=260,h=30,color='#444444',float={to='root',offset={x=50,y=40},band='above'}},function()
  W.slider{id='slider',w=200,value=VALUE,changed=function(v)VALUE=v;core.dirty(s.name)end}
  W.toggle{id='switch',on=TOGGLE,press=function()TOGGLE=not TOGGLE;core.dirty()end}
 end)
end)
K.key{key='F5',press=function()FIRED=FIRED+1 end}
'''
    with private_x11(h.out) as display:
        with h.boot(config,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None,
                'LC_ALL':'en_US.UTF-8','XDG_DATA_HOME':data,'XDG_DATA_DIRS':system,'XDG_CACHE_HOME':cache}) as (server,env,work,log):
            processes=[];files=[]
            def ev(s):check(h,env,'do '+s+' end',b'\n')
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            with (work/'wev.log').open('w') as stream:
                observer=subprocess.Popen(['stdbuf','-oL','wev'],env=env,stdout=stream,stderr=stream);processes.append(observer)
                try:
                    yes('#client.all()==1');ev('c=client.all()[1];s=c.screen');yes('core.client.focused()==c.handle')
                    win=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1]
                    def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);time.sleep(.07)
                    def point(x,y):xdo('mousemove','--window',win,x,y)
                    def at(id):
                        q=h.ev(env,'''local id='''+id+''';local b=assert(core.box(id))
                        local name=type(id)=='table' and id[1] or id;local index=type(id)=='table' and id[2] or 0
                        for _,k in ipairs{.5,.1,.9,.01,.99}do
                         local x,y=b.x+b.width*k,b.y+b.height/2
                         for _,hit in ipairs(core.hits(s.name,s.x+x,s.y+y))do
                          if hit.name==name and hit.index==index then return x,y end
                         end
                        end;error('no visible hit for '..name)''').split()
                        point(int(float(q[0])),int(float(q[1])))
                    def seen():return (work/'wev.log').read_text()
                    def no_keys(start):assert not re.search(r'wl_keyboard\] key:',seen()[start:]),seen()[start:]
                    xdo('windowfocus',win);point(400,400)
                    # Form drag owns only its initiating button, clamps, and resumes input.
                    at("'slider'");xdo('mousedown',1);yes('VALUE>.49 and VALUE<.51')
                    point(260,50);xdo('mousedown',3);xdo('mouseup',3);yes("require('kiln.grab').pointer_active()")
                    point(20,50);yes('VALUE==0');point(300,50);yes('VALUE==1');xdo('mouseup',1)
                    yes("not require('kiln.grab').pointer_active()");at("'switch'");xdo('click',1);yes('TOGGLE')
                    # Prompt editing consumes actual composed UTF-8 and all claimed edges.
                    ev("K.input.keymap={layout='us',variant='intl'};P=K.prompt.run{label='Run: ',done=function(t)DONE=t end}")
                    start=len(seen());xdo('key','F5','apostrophe');yes("P.text=='' and FIRED==0")
                    xdo('key','e','t');yes("P.text=='ét'");xdo('key','BackSpace','BackSpace');yes("P.text==''")
                    xdo('key','c','a','f','apostrophe','e');yes("P.text=='café'")
                    xdo('key','shift+Left');yes('P:selection()~=nil');settle(log);capture(env,work/'native-prompt-selection.png')
                    xdo('key','End','Return');yes("DONE=='café' and not K.prompt.active");no_keys(start)
                    start=len(seen());xdo('key','b');assert 'sym: b' in seen()[start:]
                    ev("P=K.prompt.run{text='foo',completion=K.prompt.completion(function()return {'foobar','foobaz'}end)}")
                    xdo('key','Tab');yes("P.text=='foobar'");xdo('key','Tab');yes("P.text=='foobaz'");xdo('key','Escape')
                    ev("K.input.keymap={layout='us'};K.menu.show{x=100,y=100,items={{'One',function()ACTION='one'end},{'Sub',{{'Deep',function()ACTION='deep'end}}}}}")
                    start=len(seen());xdo('key','Down','Down','Right');yes('#K.menu.open.levels==2')
                    settle(log);capture(env,work/'native-submenu.png');xdo('key','Escape','F5','Up','Return')
                    yes("ACTION=='one' and not K.menu.open and FIRED==0");no_keys(start)
                    xdo('key','F5');yes('FIRED==1')
                    # Hover opens a submenu through real pointer delivery.
                    ev("K.menu.show{x=100,y=100,items={{'Sub',{{'Deep',function()end}}}}}")
                    settle(log);at("'menu:/1'");yes('#K.menu.open.levels==2');ev('K.menu.close()')
                    # Outside dismissal and its release cannot reach the client underneath.
                    point(400,400);ev("PP=K.ui.popup{id='native-popup',w=100,h=60,color='#aa3030',scrim=true,keys={Escape='close'}};PP:show()")
                    settle(log);start=len(seen());xdo('click',1);yes('PP.open==nil')
                    assert 'wl_pointer] button:' not in seen()[start:],seen()[start:]
                    start=len(seen());xdo('click',1);assert seen()[start:].count('wl_pointer] button:')==2,seen()[start:]
                    ev("PP:show();K.hotkeys.show();assert(not PP.open and K.hotkeys.open)")
                    settle(log);capture(env,work/'native-hotkeys.png');start=len(seen());xdo('key','a');no_keys(start);yes('not K.hotkeys.open')
                    # Native hover/leave; unchanged motion must not cause solves.
                    at("'clock'");yes('K.tooltip.open~=nil');settle(log);capture(env,work/'native-tooltip.png')
                    before=counts(log);at("'clock'");time.sleep(.1);assert counts(log)==before
                    point(400,400);yes('not K.tooltip.open')
                    # Real task focus/minimize/restoration, titlebar controls and tag gestures.
                    p,f=launch(env,work,'NATIVE-FOOT');processes.append(p);files.append(f);yes('#client.all()==2')
                    ev("f=client.all()[2];f:focus()");settle(log)
                    at("'task:'..f.handle");xdo('click',1);yes('f.minimized')
                    at("'task:'..f.handle");xdo('click',1);yes('not f.minimized and client.focus==f and core.client.focused()==f.handle')
                    at("{'maximize',f.handle}");xdo('click',1);yes('f.maximized');settle(log)
                    at("{'maximize',f.handle}");xdo('click',1);yes('not f.maximized');settle(log)
                    at("{'float',f.handle}");xdo('click',1);yes('f.floating');settle(log)
                    at("{'float',f.handle}");xdo('click',1);yes('not f.floating');settle(log)
                    at("{'tag',2}");xdo('click',1);yes('s.selected_tag==s.tags[2]');at("{'tag',1}");xdo('click',1)
                    at("{'tag',1}");xdo('click',5);yes('s.selected_tag==s.tags[2]');xdo('click',4);yes('s.selected_tag==s.tags[1]')
                    settle(log);old=h.ev(env,'return K.layout.name(s.selected_tag.layout)');at("'layoutbox:'..s.name");xdo('click',1)
                    assert h.ev(env,'return K.layout.name(s.selected_tag.layout)')!=old
                    old=h.ev(env,'return K.layout.name(s.selected_tag.layout)');xdo('click',5)
                    assert h.ev(env,'return K.layout.name(s.selected_tag.layout)')!=old
                    ev('f:focus()');settle(log);at("'task:'..c.handle");xdo('click',5);yes('client.focus==c')
                    # Launcher owns the prompt's claim and launches a real mapped client.
                    ev('K.launcher.open()');start=len(seen());xdo('type','--delay','40','Native');yes('#K.launcher.matches()==1')
                    settle(log);capture(env,work/'native-launcher.png');xdo('key','Return');no_keys(start);yes('#client.all()==3')
                    ev("for _,x in ipairs(client.all())do if x.app_id=='native-launch' then app=x end end;assert(app and client.focus==app)")
                    settle(log);at("{'close',app.handle}");xdo('click',1)
                    yes('#client.all()==2');ev('c:focus()');point(300,300)
                    # Reload while a prompt owns a held key; released edge stays consumed.
                    ev('P=K.prompt.run{}');xdo('keydown','a');start=len(seen());ev('K.reload()');time.sleep(.25);settle(log)
                    xdo('keyup','a');no_keys(start);ev("for _,x in ipairs(client.all())do if x.app_id=='wev' then c=x end end;c:focus()")
                    start=len(seen());xdo('key','b');assert 'sym: b' in seen()[start:]
                    settle(log);capture(env,work/'native-reloaded.png')
                    xdo('windowsize',win,420,300);yes('screen.all()[1].width==420');settle(log)
                    capture(env,work/'native-narrow.png')
                    ev("local b=core.box('clock');assert(b.x>=0 and b.x+b.width<=420)")
                    ev('K.hotkeys.show()');h.quit(server,env,log)
                finally:
                    for p in processes:stop(p)
                    for f in files:f.close()
    print('PASS: native sliders/buttons/tasks/tags/layouts/chrome, prompt compose/selection/completion, menu/hover/popups/help/tooltip/launcher/reload and real client nonleak/recovery:',work.resolve())

TRACE='''
if not TRACE then
 TRACE={ids={},clock=0,widget=0}
 local timer,cancel,reset=core.timer,core.timer_cancel,core._timers_reset
 core.timer=function(ms,fn)
  local id;id=timer(ms,function()
   TRACE.ids[id]=nil
   if ms~=500 then TRACE.clock=TRACE.clock+1 else TRACE.widget=TRACE.widget+1 end
   fn()
  end);TRACE.ids[id]=ms;return id
 end
 core.timer_cancel=function(id)TRACE.ids[id]=nil;return cancel(id)end
 core._timers_reset=function()TRACE.ids={};return reset()end
end
'''
def timers(h):
    config=TRACE+'''
K=require('kiln');ui=K.ui;W=K.widgets
COUNTS=COUNTS or {};local fn=ui.widget{every=.5,watch={'client::property::title'},fn=function()ui.text('interval')end}
local same=ui.widget{watch={'client::property::title'},fn=function()end}
screen.on('added',function(s)
 tag.new{name='clock',screen=s}
 ui.bar(s,{},function()W.clock();fn();same()end)
end)
'''
    with h.boot(config) as (server,env,work,log):
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        def timer_counts():return h.ev(env,"local a,b=0,0;for _,ms in pairs(TRACE.ids)do if ms~=500 then a=a+1 else b=b+1 end end;return a,b").strip()
        time.sleep(.5);assert timer_counts()==b'1\t1'
        start=int(h.ev(env,'return TRACE.widget'));time.sleep(1.2);n=int(h.ev(env,'return TRACE.widget'))-start;assert 2<=n<=3,n
        records=[]
        for epoch in range(2):
            if epoch:
                for _ in range(3):ev('K.reload()');time.sleep(.25)
                assert timer_counts()==b'1\t1'
            before=int(h.ev(env,'return TRACE.clock'))
            deadline=time.monotonic()+62
            while int(h.ev(env,'return TRACE.clock'))==before and time.monotonic()<deadline:time.sleep(.5)
            assert int(h.ev(env,'return TRACE.clock'))==before+1
            assert timer_counts()==b'1\t1'
            records.append({'epoch':epoch,'clock':before+1,'timers':timer_counts().decode()})
        (work/'rollover.json').write_text(json.dumps(records,indent=2)+'\n')
        ev("local bus=client._bus or client.bus")
        # Stop interval work to measure idle strictly between minute updates.
        ev("require('kiln.ui')._reset();core.dirty()")
        settle(log);before=counts(log);time.sleep(.4);assert counts(log)==before
        ev('core.dirty()');time.sleep(.1)
        last=[l for l in log.read_text().splitlines() if l.startswith('Paint ')][-1]
        assert 'mutations 0, rasters 0' in last,last
        capture(env,work/'clock-after-reload.png');h.quit(server,env,log)
    print('PASS: real minute rollover and seconds-based widgets before/after repeated reload, one timer each, idle and zero-mutation redraw:',work.resolve())


def run(h):native(h);timers(h)
if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py');compat=importlib.util.module_from_spec(spec);spec.loader.exec_module(compat)
    out=Path(tempfile.mkdtemp(prefix='stock-native-',dir=ROOT/'build/verification'));print('Native stock artifacts:',out,flush=True)
    with tempfile.TemporaryDirectory(prefix='ko-stock-native-') as short:
        alias=Path(short)/'e';alias.symlink_to(out,target_is_directory=True)
        run(compat.Harness(ROOT/'build/kiln',c_baseline.source(),alias))
