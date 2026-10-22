"""Supported stock-widget/service assertions with isolated data and native input."""
import c_baseline
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from PIL import Image
from declaration_checks import check, wait, settle, capture
from policy_checks import private_x11
from window_state_checks import launch, stop, counts

ROOT=Path(__file__).resolve().parents[1]
STOCK=(ROOT/'kilnrc.lua').read_text()
HELPERS='''
K=require('kiln');ui=K.ui;_G.ui=K.ui;W=K.widgets;S=require('kiln.state');ERRORS=0
K.on('error',function() ERRORS=ERRORS+1 end)
function live(id,s)
 s=s or screen.all()[1];core.hits(s.name,s.x,s.y)
 local b=core.box(id);if not b then return false end
 local name=type(id)=='table' and id[1] or id
 local index=type(id)=='table' and id[2] or 0
 for _,h in ipairs(core.hits(s.name,s.x+b.x+b.width/2,s.y+b.y+b.height/2)) do
  if h.name==name and h.index==index then return true end
 end
 return false
end
function press(id,s,button)
 s=s or screen.all()[1];core.hits(s.name,s.x,s.y)
 local b=assert(core.box(id));return require('kiln.ui_input'){
 name='button',pressed=true,button=button or 1,screen=s.name,x=s.x+b.x+b.width/2,y=s.y+b.y+b.height/2,mods={}}
end
'''

def private_data(base):
    data=base/"data ' $(false)";system=base/'system';cache=base/'cache'
    for p in [data,system]: (p/'applications').mkdir(parents=True)
    # Decoder configuration is a dependency, not an installed app collection.
    loaders=Path('/usr/share/glycin-loaders')
    if loaders.exists(): (system/'glycin-loaders').symlink_to(loaders)
    (system/'mime').symlink_to('/usr/share/mime')
    return data,system,cache

def entry(path,name,command,extra=''):
    path.write_text('[Desktop Entry]\nType=Application\nName='+name+'\nExec='+command+'\n'+extra)

def data_checks(h):
    data,system,cache=private_data(h.out/'private-data')
    entry(system/'applications/shadow.desktop','Wrong system','wrong')
    entry(data/'applications/shadow.desktop','Hidden','hidden','Hidden=true\n')
    entry(system/'applications/quiet.desktop','Wrong quiet','wrong')
    entry(data/'applications/quiet.desktop','No display','hidden','NoDisplay=true\n')
    entry(data/'applications/a.desktop','Alpha','run-alpha %U %% %f')
    entry(system/'applications/b.desktop','Beta Alpha','run-beta')
    entry(system/'applications/c.desktop','Gamma','alpha-command')
    entry(data/'applications/foot.desktop','Fixture Foot',"foot --app-id=stock-launch --title=STOCK-LAUNCH sh -c 'echo launched; sleep 1000'")
    icon=data/'icons/hicolor/128x128/apps/fixture.png';icon.parent.mkdir(parents=True)
    Image.new('RGBA',(16,16),(240,80,40,255)).save(icon)
    entry(data/'applications/fixture.desktop','Fixture','true','Icon=fixture\nNoDisplay=true\n')
    entry(system/'applications/fixture.desktop','Wrong','true','Icon=wrong\n')
    with h.boot(STOCK+HELPERS,overrides={'XDG_DATA_HOME':data,'XDG_DATA_DIRS':system,'XDG_CACHE_HOME':cache}) as (server,env,work,log):
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        ev('''local a=K.launcher.apps();assert(#a==4 and a[1].name=='Alpha' and a[2].name=='Beta Alpha' and a[4].name=='Gamma')
        assert(a[1].exec=='run-alpha  %');local m=K.launcher.default_filter('ALPHA')
        assert(#m==3 and m[1].name=='Alpha' and m[2].name=='Beta Alpha' and m[3].name=='Gamma')
        assert(K.launcher.apps()==a);assert(K.icon.path('missing-fixture')==nil)
        assert(K.icon.path('fixture')==K.icon.client{app_id='fixture'})
        assert(K.icon.path('fixture')==K.icon.client{class='Fixture'})
        assert(K.icon.path(K.icon.path('fixture'))==K.icon.path('fixture'))
        assert(K.icon.client{icon='native-cache-key',app_id='fixture'}=='native-cache-key')''')
        resolved=h.ev(env,"return K.icon.path('fixture')").decode().strip();assert resolved==str(icon)
        miss=data/'pixmaps/missing-fixture.png';miss.parent.mkdir();Image.new('RGBA',(4,4),'blue').save(miss)
        entry(data/'applications/new.desktop','New after reload','new-command')
        ev("assert(K.icon.path('missing-fixture')==nil and #K.launcher.apps()==4);K.launcher.open()")
        settle(log);ev("assert(live('launcher-list') and K.prompt.active)")
        capture(env,work/'launcher-first.png')
        ev("K.launcher.close();K.launcher.filter=function()local rows={};for i=1,100 do rows[i]={name='Overflow '..i,exec='true'}end;return rows end;K.launcher.open();for i=1,99 do K.prompt.active:on_key{pressed=true,key='Tab'}end")
        settle(log);ev("local b=core.box('launcher-list');local s=screen.all()[1];assert(b.y>=s.workarea.y and b.y+b.height<=s.height);assert(live('launcher-row:100'))")
        capture(env,work/'launcher-overflow.png')
        ev('K.launcher.close();K.launcher.filter=K.launcher.default_filter')
        ev("SPAWN=K.launcher.spawn;K.launcher.spawn=function(cmd)assert(not K.prompt.active);LAUNCHED=cmd end;K.launcher.open()")
        settle(log);ev("press('launcher-row:2');assert(LAUNCHED=='run-beta' and not K.prompt.active);K.launcher.spawn=SPAWN")
        ev("K.launcher.close();P=K.prompt.run{text='café hello',history={'one','two'}};P:move(5,true)")
        settle(log);capture(env,work/'prompt-selection.png')
        ev('''P:on_key{pressed=true,key='BackSpace'};assert(P.text=='café');P:on_key{pressed=true,key='BackSpace'};assert(P.text=='caf')
        P:on_key{pressed=true,key='Up'};assert(P.text=='two');P:on_key{pressed=true,key='Down'};assert(P.text=='caf')
        P:stop();local complete=K.prompt.completion(function()return {'foobar','foobaz'} end)
        assert(complete('foo',3)=='foobar');assert(complete('foobar',6)=='foobaz');assert(complete('foobaz',6)=='foobar')
        P=K.prompt.run{completion=function()return 'é',1 end};P:on_key{pressed=true,key='Tab'};assert(P.cursor==0);P:stop()
        P=K.prompt.run{text='café two'};P:on_key{pressed=true,key='Left',mods={ctrl=true}};assert(P.cursor==6)
        P:on_key{pressed=true,key='BackSpace',mods={ctrl=true}};assert(P.text=='two' and P.cursor==0);P:stop()
        Q=K.prompt.run{changed=function() error('changed fixture') end};require('kiln.grab').route_key{pressed=true,key='a',utf8='a'}
        assert(not K.prompt.active and ERRORS==1)
        K.launcher.filter=K.launcher.default_filter;K.launcher.open();K.prompt.active.text='Fixture Foot';K.prompt.active:changed()
        assert(#K.launcher.matches()==1);K.prompt.active:finish()''')
        wait(h,env,'return #client.all()',b'1\n',server)
        wait(h,env,"return core.client.focused()==client.all()[1].handle",b'true\n',server)
        ev("assert(client.all()[1].app_id=='stock-launch' and type(core.spawn_with_token)=='function' and K.launcher.spawn==core.spawn_with_token);assert(live('task:'..client.all()[1].handle))")
        settle(log);capture(env,work/'launcher-foot.png')
        (work/'launcher-spawn.txt').write_bytes(h.ev(env,"return client.all()[1].app_id,core.client.focused(),type(core.spawn_with_token)"))
        ev("K.reload()")
        wait(h,env,"return #K.launcher.apps()==5 and #client.all()==1",b'true\n',server)
        ev("assert(K.icon.path('missing-fixture')==nil);client.all()[1]:close()")
        wait(h,env,'return #client.all()',b'0\n',server)
        h.quit(server,env,log)
    print('PASS: private XDG precedence/shadowing/ranking/field codes/icon misses/cache/reload, prompt UTF-8/history/completion/errors, real launcher foot:',work.resolve())

FORM='''
K=require('kiln');ui=K.ui;W=K.widgets
V=.5;ON=false;SEEN={};ITEMS={{id='a'},{id='b'}}
local function key(x)return x.id end
screen.on('added',function(s)
 tag.new{name='one',screen=s};tag.new{name='two',screen=s}
 ui.bar(s,{h=40},function()
  W.progress{id='prog',fill_id='fill',w=200,value=V}
  W.separator{id='sep',vertical=true,length=20}
  W.toggle{id='toggle',on=ON,press=function()ON=not ON;core.dirty()end}
  W.slider{id='slide',w=100,value=V,changed=function(v)V=v end}
  W.taglist(s);W.layoutbox(s)
  ui.each(ITEMS,key,function(x,id,st)st.id=st.id or x.id;SEEN[s.name..id]=st;ui.box{id=id,w=2,h=2}end)
 end)
end)
'''

def widgets(h):
    with h.boot(FORM+HELPERS,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        settle(log)
        for value,expected in [(.5,100),(.25,50),(0,0),(1,200),(1.7,200),(-.5,0)]:
            ev(f'V={value};core.dirty()');settle(log)
            check(h,env,"return core.box('fill').width",f'{expected}\n'.encode())
        ev("local b,k=core.box('toggle'),core.box('toggle:knob');assert(k.x<b.x+b.width/2);press('toggle')")
        settle(log);ev("local b,k=core.box('toggle'),core.box('toggle:knob');assert(k.x>b.x+b.width/2 and ON)")
        ev('''a,b=unpack(screen.all());assert(SEEN[a.name..'a']~=SEEN[b.name..'a']);OLD=SEEN[a.name..'a'];ITEMS={ITEMS[2],ITEMS[1]};core.dirty()''')
        settle(log);ev("assert(SEEN[a.name..'a']==OLD);ITEMS={ITEMS[1]};core.dirty()")
        settle(log);ev("ITEMS[#ITEMS+1]={id='a'};core.dirty()")
        settle(log);ev("assert(SEEN[a.name..'a']~=OLD)")
        # Explicitly synthetic pointer facts on a non-origin real output.
        ev('''assert(b.x~=0);core.hits(b.name,b.x,b.y);local q=core.box('slide');B=q
        require('kiln.ui_input'){name='button',pressed=true,button=1,screen=b.name,x=b.x+q.x+q.width*.75,y=b.y+q.y+q.height/2}
        assert(V==.75);local g=require('kiln.grab');g.route_pointer{name='button',pressed=false,button=3};assert(g.pointer_active())
        g.route_pointer{name='motion',x=b.x+q.x-100,y=0,screen=b.name};assert(V==0)
        g.route_pointer{name='motion',x=b.x+q.x+1000,y=0,screen=b.name};assert(V==1)
        g.route_pointer{name='button',pressed=false,button=1};assert(not g.pointer_active())''')
        ev("press({'tag',2},b);assert(b.selected_tag==b.tags[2]);local old=b.selected_tag.layout;press('layoutbox:'..b.name,b);assert(old~=b.selected_tag.layout)")
        # Failed hook candidates preserve pixels, hits and published action closures.
        ev("H=K.on_declare(function()ui.box{id='hook-button',w=40,h=40,color='#00ff00',float={to='root'},on_press=function()FIRED='old'end}end);core.dirty()")
        settle(log);capture(env,work/'before-failed.png')
        ev("BAD=K.on_declare(function()ui.box({id='bad',w=30,h=30},function()error('failed hook fixture')end)end);core.dirty()")
        time.sleep(.2);capture(env,work/'failed-hook.png')
        assert Image.open(work/'before-failed.png').tobytes()==Image.open(work/'failed-hook.png').tobytes()
        ev("assert(live('hook-button',a));press('hook-button',a);assert(FIRED=='old');K.off_declare(BAD);core.dirty()")
        settle(log);ev("assert(not live('bad',a))")
        ev("press('slide',b);assert(require('kiln.grab').pointer_active());b:emit('removed');assert(not require('kiln.grab').pointer_active())")
        h.quit(server,env,log)
    print('PASS: controlled form geometry, keyed state isolation/reorder/retirement, synthetic nonorigin slider/button ownership, hooks retain pixels/hits/actions:',work.resolve())


def services(h):
    config=FORM+HELPERS+'''
PP=ui.popup{id='pp',under='slide',w=120,h=60,color='#cc3344',scrim=true,keys={Escape='close'},on_close=function()CLOSED=(CLOSED or 0)+1 end}
QQ=ui.popup{id='qq',w=80,h=50,color='#33cc44',keys={Escape='close'}}
'''
    with h.boot(config,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        ev("s=screen.all()[1];PP:show();assert(PP.claim.active)")
        settle(log);ev("assert(live('pp'));local p,b=core.box('pp'),core.box('slide');assert(p.y>=b.y+b.height)")
        capture(env,work/'popup.png')
        ev("QQ:show();assert(PP.open==nil and QQ.claim.active and CLOSED==1);PP:close();assert(QQ.claim.active);QQ:close()")
        ev("OLD=PP;PP:destroy();PP=ui.popup{id='pp',w=40,h=40,color='#cc3344'};OLD:destroy();OLD:show();assert(not OLD.open);PP:show()")
        settle(log);ev("assert(live('pp'));PP:destroy();PP=ui.popup{id='pp',under='never-declared',w=40,h=40,keys={Escape='close'}};PP:show()")
        settle(log);ev("assert(PP.open==nil and not require('kiln.grab').route_key{key='x',pressed=true})")
        ev("PP:destroy();PP=ui.popup{id='pp',under='slide',w=40,h=40,keys={Escape='close'}};PP:show()")
        settle(log);ev("s.bars={};core.dirty(s.name)")
        settle(log);ev("assert(PP.open==nil and core.box('slide')~=nil)")
        ev("K.menu.show{x=s.width-20,y=s.height-30,items={{'One',function()ACTION='one'end},{'Sub',{{'Deep',function()ACTION='deep'end}}}}};K.menu.nav('up');K.menu.nav('enter')")
        settle(log);ev("assert(#K.menu.open.levels==2);local b=core.box('menu:box/2');assert(b.x>=0 and b.y>=0 and b.x+b.width<=s.width and b.y+b.height<=s.height)")
        capture(env,work/'submenu-fit.png')
        ev("K.menu.nav('enter');assert(ACTION=='deep' and K.menu.open==nil);K.menu.show{items={{'again',function()K.menu.show{items={{'new',function()end}}}end}}};K.menu.nav('down');K.menu.nav('enter');assert(K.menu.open.levels[1].items[1][1]=='new');K.menu.close()")
        ev("K.menu.keys.F9='down';K.menu.show{items={{'custom',function()ACTION='custom'end}}};require('kiln.grab').route_key{key='F9',pressed=true};K.menu.nav('enter');assert(ACTION=='custom');K.menu.keys.F9=nil")
        ev("tip=ui.tooltip('tip');tip(true,{screen=screen.all()[2].name,name='slide',index=0})")
        settle(log);ev("assert(K.tooltip.open.screen==screen.all()[2]);tip(true,{screen=s.name,name='slide',index=0})")
        settle(log);ev("assert(K.tooltip.open==nil)")
        # Repeated reset restores library hooks and invalidates config popup handles.
        for i in range(4):
            ev("K.hotkeys.show();K.reload()")
            wait(h,env,"return #screen.all()[1].bars==1 and K.hotkeys.open==nil and PP~=OLD",b'true\n',server)
            settle(log)
            ev("assert(#screen.all()[1].tags==2);OLD:destroy();PP:show();assert(PP.open)")
        ev("K.reload()")
        time.sleep(.2);settle(log)
        ev("K.launcher.open();K.reload()")
        time.sleep(.2);settle(log)
        ev("assert(not K.prompt.active);PP:show()")
        h.quit(server,env,log)
        assert 'keyboard claim false, pointer claim false' in log.read_text()
    print('PASS: popup claims/replacement/stale IDs/live anchors/omission, menu nesting/fit/reopen, output tooltip identity, repeated transient reload/owned shutdown:',work.resolve())


def run(h):
    widgets(h);services(h);data_checks(h)

if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py')
    compat=importlib.util.module_from_spec(spec);spec.loader.exec_module(compat)
    out=Path(tempfile.mkdtemp(prefix='stock-',dir=ROOT/'build/verification'))
    print('Stock artifacts:',out,flush=True)
    with tempfile.TemporaryDirectory(prefix='ko-stock-') as short:
        alias=Path(short)/'e';alias.symlink_to(out,target_is_directory=True)
        run(compat.Harness(ROOT/'build/kiln',c_baseline.source(),alias))
