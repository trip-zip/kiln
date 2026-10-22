"""Focused model-test membership assertions and signal/error contracts."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time

from declaration_checks import capture, check, wait, geometry_config

ROOT = Path(__file__).resolve().parents[1]
CAPTURE = '''
FACTS={};ADDED=0;MAPS=0;SIZES=0;METADATA=0
local event_set=core.set_event_handler
core.set_event_handler=function(fn)
 event_set(function(e)
  FACTS[#FACTS+1]=e
  if e.class=='client' then
   if e.name=='commit_size' then SIZES=SIZES+1 end
   if e.name=='metadata' then METADATA=METADATA+1 end
  end
  fn(e)
 end)
end
'''
AFTER = '''
screen.on('added',function(s) ADDED=ADDED+1 end)
client.on('map',function(c) MAPS=MAPS+1 end)
function visible(name)
 local ids={}
 for y=60,700,200 do for x=30,1270,200 do
  for _,hit in ipairs(core.hits(name,x,y)) do
   if hit.name=='core.surface' then ids[hit.index]=true end
  end
 end end
 local out={};for id in pairs(ids) do out[#out+1]=id end;table.sort(out)
 return table.concat(out,',')
end
function focused()
 local c=client.focus
 return c and c.handle,core.client.focused(),screen.focused and screen.focused.name
end
'''


def spawn(h, env, work, label, fullscreen=False):
    pidfile = work / f'{label}.pid'
    trigger = work / f'{label}.rename'
    command = (f"echo $$ > {pidfile}; exec foot --app-id=model-{label} --title=MODEL-{label} "
               + ('--fullscreen ' if fullscreen else '')
               + "--font=monospace:size=14 sh -c "
               + "'printf \"\\n  Model " + label + "\\n\\n\"; "
               + f"while :; do if [ -f {trigger} ]; then printf \"\\033]2;RENAMED-{label}\\007\"; "
               + "else printf \"\\r  repaint %s\" \"$(date +%s)\"; fi; sleep .1; done'")
    check(h, env, 'core.spawn(' + json.dumps(command) + ')', b'\n')
    end = time.monotonic() + 5
    while not pidfile.exists():
        assert time.monotonic() < end
        time.sleep(.02)
    return os.pidfd_open(int(pidfile.read_text())), trigger


def cleanup(fds):
    for fd in fds:
        try:
            signal.pidfd_send_signal(fd, signal.SIGTERM)
        except ProcessLookupError:
            pass
        os.close(fd)


def clients(h):
    config = CAPTURE + geometry_config() + AFTER
    with h.boot(config) as (server, env, work, log):
        fds = []
        try:
            wait(h, env, 'return ADDED', b'1\n', server)
            check(h, env, 'return #screen.all(),#screen.all()[1].tags', b'1\t2\n')
            for label in ('LEFT', 'RIGHT'):
                fd, trigger = spawn(h, env, work, label, fullscreen=label=='RIGHT')
                fds.append(fd)
                wait(h, env, 'return #client.all()', f'{len(fds)}\n'.encode(), server)
            check(h, env, 'a,b=unpack(client.all());s=screen.all()[1];t1,t2=unpack(s.tags);return a.app_id,b.app_id,a.title,b.title',
                  b'model-LEFT\tmodel-RIGHT\tMODEL-LEFT\tMODEL-RIGHT\n')
            wait(h, env, 'return visible(s.name)', b'1,2\n', server)
            wait(h, env, 'return focused()', b'2\t2\tHEADLESS-1\n', server)
            check(h, env, '''local request,map=false,false;for _,e in ipairs(FACTS) do
if e.handle==b.handle then if e.name=='request::fullscreen' and e.on then request=true end
if e.name=='map' and e.fullscreen then map=true end end end;return request,map''', b'true\ttrue\n')
            check(h, env, 'core.replay();core.replay();collectgarbage("collect")', b'\n')
            time.sleep(.1)
            check(h, env, 'return MAPS,#client.all(),#t1.clients,require("kiln.object").lookup(a.handle)==a', b'2\t2\t2\ttrue\n')
            wait(h, env, 'return a.width,a.height,b.width,b.height', b'616\t652\t616\t652\n', server)
            check(h, env, 'return SIZES>=2', b'true\n')
            trigger.touch()
            wait(h, env, 'return b.title', b'RENAMED-RIGHT\n', server)
            check(h, env, 'return METADATA>0', b'true\n')
            time.sleep(.3)
            baseline = [line for line in log.read_text().splitlines() if line.startswith('Layout ')]
            sizes = h.ev(env, 'return SIZES')
            time.sleep(.6)
            assert baseline == [line for line in log.read_text().splitlines() if line.startswith('Layout ')]
            assert h.ev(env, 'return SIZES') == sizes
            check(h, env, 'a.custom="quiet";a.width=a.width;return a.custom', b'quiet\n')
            time.sleep(.1)
            assert baseline == [line for line in log.read_text().splitlines() if line.startswith('Layout ')]
            capture(env, work / 'tags-before.png')
            check(h, env, 'b.tag=t2;return b.screen==s,#t1.clients,#t2.clients', b'true\t1\t1\n')
            wait(h, env, 'return visible(s.name)', b'1\n', server)
            wait(h, env, 'return focused()', b'1\t1\tHEADLESS-1\n', server)
            check(h, env, 'b:focus();return client.focus==a', b'true\n')
            check(h, env, 't2:view()', b'\n')
            wait(h, env, 'return visible(s.name)', b'2\n', server)
            wait(h, env, 'return focused()', b'2\t2\tHEADLESS-1\n', server)
            wait(h, env, 'return core.box({"core.surface",b.handle}).width', b'1248\n', server)
            wait(h, env, 'return b.width,b.height', b'1248\t652\n', server)
            time.sleep(.15)
            capture(env, work / 'tags-after.png')
            check(h, env, 'a.tags={t1,t2,t2};t1:toggle();return #s.selected_tags,#a.tags,#t2.clients,s.selected_tag.name,t1.selected,t2.selected', b'2\t2\t2\t1\ttrue\ttrue\n')
            wait(h, env, 'return visible(s.name)', b'1,2\n', server)
            wait(h, env, 'return core.box({"core.surface",a.handle}).width', b'616\n', server)
            check(h, env, 't1:view();tag.history.restore(s);return #s.selected_tags', b'2\n')
            check(h, env, 'a.tag=t1;t2:delete();return #s.tags,b.tag==t1,#t1.clients', b'1\ttrue\t2\n')
            wait(h, env, 'return visible(s.name)', b'1,2\n', server)
            check(h, env, 'empty=tag.new{name="empty",screen=s};empty:view()', b'\n')
            wait(h, env, 'return visible(s.name)', b'\n', server)
            wait(h, env, 'return focused()', b'nil\tnil\tHEADLESS-1\n', server)
            capture(env, work / 'tags-empty.png')
            check(h, env, 'empty:toggle();return empty.selected', b'true\n')
            check(h, env, 't1:view();b:focus()', b'\n')
            wait(h, env, 'return focused()', b'2\t2\tHEADLESS-1\n', server)
            signal.pidfd_send_signal(fds[1], signal.SIGTERM)
            wait(h, env, 'return #client.all()', b'1\n', server)
            wait(h, env, 'return focused()', b'1\t1\tHEADLESS-1\n', server)
            check(h, env, 'return b.mapped,require("kiln.object").lookup(b.handle),#b.tags', b'false\tnil\t0\n')
            check(h, env, 'b.tag=t1;b:focus();return #client.all(),client.focus==a', b'1\ttrue\n')
            wait(h, env, 'return core.box({"core.surface",a.handle}).width', b'1248\n', server)
            wait(h, env, 'return a.width,a.height', b'1248\t652\n', server)
            time.sleep(.15)
            capture(env, work / 'tags-survivor.png')
            signal.pidfd_send_signal(fds[0], signal.SIGTERM)
            wait(h, env, 'return #client.all()', b'0\n', server)
            wait(h, env, 'return focused()', b'nil\tnil\tHEADLESS-1\n', server)
            check(h, env, 'core._discover();core.quit()', b'\n')
            assert server.wait(timeout=5)==0, log.read_text()
            assert not Path(env['KILN_SOCK']).exists()
        finally:
            cleanup(fds)
    print('PASS: real client metadata/size/initial fullscreen facts, replay, tags, union, native focus, empty and survivor cases')
    print('Model screenshots:', work.resolve())


def outputs(h):
    config = CAPTURE + geometry_config() + AFTER
    with h.boot(config, overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server, env, work, log):
        fds=[]
        try:
            wait(h, env, 'return ADDED', b'2\n', server)
            check(h, env, 'local ss=screen.all();local os=core.output.list();assert(ss[1].name==os[2].name and ss[2].name==os[1].name);for _,s in ipairs(ss) do if s.name=="HEADLESS-1" then s1=s else s2=s end end;return s1.name,s2.name,#s1.tags,#s2.tags', b'HEADLESS-1\tHEADLESS-2\t2\t2\n')
            for i,label in enumerate(('ONE','TWO')):
                check(h, env, f'screen.focused=s{i+1}', b'\n')
                fd,_=spawn(h,env,work,label);fds.append(fd)
                wait(h,env,'return #client.all()',f'{i+1}\n'.encode(),server)
            check(h,env,"for _,c in ipairs(client.all()) do if c.app_id=='model-ONE' then a=c else b=c end end;return a.screen==s1,b.screen==s2",b'true\ttrue\n')
            time.sleep(.2)
            check(h,env,'''local x=core.hits(s1.name,s1.x+100,s1.y+100)[1];local y=core.hits(s2.name,s2.x+100,s2.y+100)[1]
return x.name,x.index==a.handle,y.name,y.index==b.handle''',b'core.surface\ttrue\tcore.surface\ttrue\n')
            counts=lambda: {name: len([l for l in log.read_text().splitlines() if l.startswith('Layout '+name+':')]) for name in ('HEADLESS-1','HEADLESS-2')}
            before=counts()
            check(h,env,'s1.tags[2]:view()',b'\n')
            time.sleep(.2)
            after=counts()
            assert after['HEADLESS-1']>before['HEADLESS-1'] and after['HEADLESS-2']==before['HEADLESS-2'],(before,after)
            check(h,env,'return #require("kiln").visible_clients(s1),#require("kiln").visible_clients(s2)',b'0\t1\n')
            check(h,env,'a.tags={s1.tags[1],s2.tags[1]};return a.screen==s1',b'true\n')
            wait(h,env,'return core.box({"core.surface",a.handle}).width',b'616\n',server)
            check(h,env,'return #require("kiln").visible_clients(s1),#require("kiln").visible_clients(s2)',b'0\t2\n')
            check(h,env,'''local x=core.hits(s2.name,s2.x+100,s2.y+100)[1];local y=core.hits(s2.name,s2.x+1000,s2.y+100)[1]
return x.name,x.index==b.handle,y.name,y.index==a.handle''',b'core.surface\ttrue\tcore.surface\ttrue\n')
            check(h,env,'s1.tags[1]:view()',b'\n')
            time.sleep(.2)
            check(h,env,'return #require("kiln").visible_clients(s1),#require("kiln").visible_clients(s2)',b'1\t1\n')
            check(h,env,'a.tag=s2.tags[1];a:focus()',b'\n')
            wait(h,env,'return focused()',b'1\t1\tHEADLESS-2\n',server)
            check(h,env,'local ok=pcall(function() s1.selected_tags={s2.tags[1]} end);return ok,s1.selected_tag==s1.tags[1]',b'false\ttrue\n')
            h.quit(server,env,log)
        finally:
            cleanup(fds)
    print('PASS: two real headless outputs, independent tags/dirtying, cross-screen membership and focus')


def late_require(h):
    with h.boot() as (server, env, work, log):
        fds=[]
        try:
            fd,_=spawn(h,env,work,'LATE');fds.append(fd)
            time.sleep(.3)
            check(h,env,"require('kiln');N=0;screen.on('added',function(s) N=N+1;tag.new{name='late',screen=s} end);return #screen.all()",b'1\n')
            wait(h,env,'return #client.all()',b'1\n',server)
            check(h,env,'core.replay();core._discover()',b'\n')
            time.sleep(.1)
            check(h,env,'return N,#screen.all(),#client.all(),#screen.all()[1].tags',b'1\t1\t1\t1\n')
            h.quit(server,env,log)
        finally:
            cleanup(fds)
    print('PASS: late require seeds real screens and replays an already mapped client once')


def run(h):
    clients(h)
    outputs(h)
    late_require(h)
