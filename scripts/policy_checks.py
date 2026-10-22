"""Focused model/stdlib/rc assertions plus real input on an owned Xvfb display."""
import contextlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import time

from declaration_checks import capture, check, wait, geometry_config, settle
from model_checks import CAPTURE, AFTER, spawn, cleanup

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = geometry_config()


def rules_and_actions(h):
    config = CAPTURE + DEFAULT + AFTER + '''
GRANTS={};ACTIVATIONS={};ERRORS=0
local focus,activate=core.client.focus,core.client.set_activated
core.client.focus=function(id) if id then GRANTS[#GRANTS+1]=id end;return focus(id) end
core.client.set_activated=function(id,on) if on then ACTIVATIONS[#ACTIVATIONS+1]=id end;return activate(id,on) end
require('kiln').on('error',function() ERRORS=ERRORS+1 end)
'''
    with h.boot(config, overrides={'WLR_HEADLESS_OUTPUTS': '2'}) as (server, env, work, log):
        fds = []
        try:
            wait(h, env, 'return ADDED', b'2\n', server)
            settle(log)
            check(h, env, "k=require('kiln');s1,s2=unpack(screen.all());screen.focused=s1", b'\n')
            fd, _ = spawn(h, env, work, 'BASE'); fds.append(fd)
            wait(h, env, 'return #client.all()', b'1\n', server)
            wait(h, env, 'return core.client.focused()==client.all()[1].handle', b'true\n', server)
            check(h, env, '''base=client.all()[1];ORDER={}
k.rule{props={wrong=true}}
k.rule{match={app={'^absent$','^model%-QUIET$'},title='MODEL%-QUIET'},props={focus=false,screen=s2.name,tag='2',custom=1},on=function(c)
 assert(c.app_id=='model-QUIET' and c.title=='MODEL-QUIET' and c.tag==s2.tags[2] and c.no_focus)
 ORDER[#ORDER+1]='first';c:focus()
end}
k.rule{match_any={app='QUIET'},except={title='QUIET'},props={wrong=true}}
k.rule{match={app='QUIET'},except_any={title={'absent','QUIET'}},props={wrong=true}}
k.rule{match={fn=function(c) return c.app_id=='model-QUIET' end},props={custom=2},on=function(c) ORDER[#ORDER+1]='second';assert(c.custom==2) end}
k.rule{match={app='QUIET'},on=function() error('rule callback failure') end}
k.rule{match={fn=function() error('rule predicate failure') end}}
k.rule{match={app='QUIET'},props={after_error=true,floating=true,fullscreen=true}}''', b'\n')
            fd, _ = spawn(h, env, work, 'QUIET'); fds.append(fd)
            wait(h, env, 'return #client.all()', b'2\n', server)
            check(h, env, '''for _,c in ipairs(client.all()) do if c.app_id=='model-QUIET' then quiet=c end end
assert(quiet and quiet.tag==s2.tags[2] and quiet.custom==2 and quiet.after_error and not quiet.wrong)
assert(quiet.floating and quiet.fullscreen and quiet.no_focus)
for _,id in ipairs(GRANTS) do assert(id~=quiet.handle) end
for _,id in ipairs(ACTIVATIONS) do assert(id~=quiet.handle) end
for _,e in ipairs(FACTS) do if e.class=='input' and e.name=='focus' then assert(e.handle~=quiet.handle) end end
return table.concat(ORDER,','),ERRORS,client.focus==base,core.client.focused()==base.handle''', b'first,second\t2\ttrue\ttrue\n')
            check(h, env, "k.rule.clear();screen.focused=s1;k.rule{match={app='model%-VISIBLE'},props={focus=false}}", b'\n')
            fd, _ = spawn(h, env, work, 'VISIBLE'); fds.append(fd)
            wait(h, env, 'return #client.all()', b'3\n', server)
            check(h, env, "for _,c in ipairs(client.all()) do if c.app_id=='model-VISIBLE' then unfocused=c end end;return unfocused.no_focus,unfocused.tag==base.tag", b'true\ttrue\n')
            wait(h, env, 'return unfocused.width', b'616\n', server)
            check(h, env, "for _,id in ipairs(GRANTS) do assert(id~=unfocused.handle) end;for _,id in ipairs(ACTIVATIONS) do assert(id~=unfocused.handle) end;for _,e in ipairs(FACTS) do if e.class=='input' and e.name=='focus' then assert(e.handle~=unfocused.handle) end end;return client.focus==base,core.client.focused()==base.handle", b'true\ttrue\n')
            check(h, env, 'unfocused:close();k.rule.clear()', b'\n')
            wait(h, env, 'return #client.all()', b'2\n', server)
            fd, _ = spawn(h, env, work, 'NEXT'); fds.append(fd)
            wait(h, env, 'return #client.all()', b'3\n', server)
            check(h, env, "for _,c in ipairs(client.all()) do if c.app_id=='model-NEXT' then nextc=c end end;return client.focus==nextc,client.history.previous()==base", b'true\ttrue\n')
            wait(h, env, 'return base.width,nextc.width', b'616\t616\n', server)
            check(h, env, "BX=core.box({'core.surface',base.handle}).x;NX=core.box({'core.surface',nextc.handle}).x;assert(BX~=NX);base:swap(nextc)", b'\n')
            wait(h, env, "return core.box({'core.surface',base.handle}).x==NX,core.box({'core.surface',nextc.handle}).x==BX", b'true\ttrue\n', server)
            check(h, env, 'base:focus();return s1.selected_tag.clients[2]==base,client.history()[1]==base', b'true\ttrue\n')
            check(h, env, 'base:lower()', b'\n')
            wait(h, env, "return core.box({'core.surface',base.handle}).x==BX", b'true\n', server)
            check(h, env, 'base:raise()', b'\n')
            wait(h, env, "return core.box({'core.surface',base.handle}).x==NX", b'true\n', server)
            # Only the affected output should solve for an ordering operation.
            time.sleep(.15)
            unaffected = h.ev(env, 'return s2.name').decode().strip()
            count = lambda: sum(l.startswith('Layout '+unaffected+':') for l in log.read_text().splitlines())
            before = count()
            check(h, env, 'base:lower()', b'\n');time.sleep(.15)
            assert count() == before
            check(h, env, '''base.tags={s1.tags[1],s1.tags[2]};nextc.tags={s1.tags[1],s1.tags[2]};base:swap(nextc)
return s1.tags[1].clients[1]==nextc,s1.tags[2].clients[1]==nextc,#base.tags,#nextc.tags''', b'true\ttrue\t2\t2\n')
            check(h, env, 'base:move_to(s2);return #base.tags,base.tag==s2.selected_tag', b'1\ttrue\n')
            wait(h, env, 'return core.client.focused()==base.handle,screen.focused==s2', b'true\ttrue\n', server)
            check(h, env, '''k.defaults.successor=function(gone) assert(gone==base);return nextc end;base:close()''', b'\n')
            wait(h, env, 'return #client.all()', b'2\n', server)
            wait(h, env, 'return core.client.focused()==nextc.handle,client.focus==nextc', b'true\ttrue\n', server)
            check(h, env, '''base:close();base:kill();base:raise();base:lower();base:swap(nextc);base:move_to(s1)
core.client.close(base.handle);core.client.kill(base.handle)
return #base.tags,#client.all()''', b'0\t2\n')
            check(h, env, 'k.defaults.successor=function() return nil end;nextc:kill()', b'\n')
            wait(h, env, 'return #client.all()', b'1\n', server)
            wait(h, env, 'return core.client.focused(),client.focus', b'nil\tnil\n', server)
            check(h, env, 'quiet:close()', b'\n')
            wait(h, env, 'return #client.all()', b'0\n', server)
            h.quit(server, env, log)
        finally:
            cleanup(fds)
    print('PASS: real rules/metadata/no transient focus/errors, MRU, ordering/boxes, multi-tag swap, move, replaced successor, close/owned kill/stale verbs')


@contextlib.contextmanager
def private_x11(work):
    read, write = os.pipe()
    with (work / 'xvfb.log').open('w') as log:
        process = subprocess.Popen(['Xvfb', '-displayfd', str(write), '-screen', '0', '1280x800x24', '-nolisten', 'tcp'],
                                   pass_fds=(write,), stdout=log, stderr=log)
        os.close(write)
        try:
            assert select.select([read], [], [], 5)[0], 'Xvfb failed to allocate display'
            display = ':' + os.read(read, 32).decode().strip()
            yield display
        finally:
            os.close(read)
            if process.poll() is None: process.terminate()
            process.wait(timeout=5)


def native_input(h):
    missing = [name for name in ('Xvfb', 'xdotool', 'wev', 'stdbuf') if not shutil.which(name)]
    if missing:
        print('UNAVAILABLE: real keyboard test requires ' + ', '.join(missing))
        return
    with private_x11(h.out) as display:
        config = CAPTURE + DEFAULT + AFTER + '''
K=require('kiln');KEYS={};ERRORS=0
K.on('error',function() ERRORS=ERRORS+1 end)
K.on('input::key',function(e) KEYS[#KEYS+1]=e end)
D,SD,R,PAD,SPACE=0,0,0,0,0
K.key{mods={'mod','shift'},key='space',press=function() SPACE=SPACE+1 end}
K.key{mods={'mod'},key='d',press=function() D=D+1 end}
K.key{mods={'mod','shift'},key='d',press=function() SD=SD+1 end}
K.key{mods={'mod'},key='F5',release=function() R=R+1 end}
K.key{mods={'mod'},key='KP_1',press=function() PAD=PAD+1 end}
K.key{mods={'mod'},key='F7',press=function() error('native key callback') end}
'''
        with h.boot(config, overrides={'WLR_BACKENDS': 'x11', 'DISPLAY': display, 'WAYLAND_DISPLAY': None}) as (server, env, work, log):
            fds = []
            try:
                check(h, env, 'core.spawn(' + json.dumps(f'echo $$ > {work}/wev.pid; exec stdbuf -oL wev > {work}/wev.log 2>&1') + ')', b'\n')
                wait(h, env, 'return #client.all()', b'1\n', server)
                fds.append(os.pidfd_open(int((work / 'wev.pid').read_text())))
                wait(h, env, 'return core.client.focused()==client.all()[1].handle', b'true\n', server)
                check(h, env, 'observer=client.all()[1];s=screen.all()[1]', b'\n')
                windows = subprocess.check_output(['xdotool', 'search', '--name', ''], env=env).decode().splitlines()
                window = windows[-1]
                def xdo(*args):
                    subprocess.run(['xdotool', *args], env=env, check=True, timeout=5)
                    time.sleep(.06)
                xdo('windowfocus', window)
                observer_log = work / 'wev.log'
                def seen(): return observer_log.read_text()
                def edges(text, code):
                    return [int(n) for n in re.findall(r'wl_keyboard\] key:.*?key: '+str(code)+r'; state: (\d)', text)]
                start = len(seen())
                xdo('key', 'a', 'shift+b')
                assert edges(seen()[start:], 38) == [1,0] and edges(seen()[start:],56) == [1,0]
                assert "utf8: 'B'" in seen()[start:]
                start = len(seen())
                xdo('key', 'super+d', 'super+shift+d')
                check(h, env, 'return D,SD', b'1\t1\n')
                assert edges(seen()[start:],40) == [], seen()[start:]
                check(h, env, '''local found=false;for _,e in ipairs(KEYS) do if e.pressed and e.key=='d' and e.mods.shift then assert(e.utf8=='D');found=true end end;return found''', b'true\n')
                # An additional modifier makes the chord unbound and reaches the client.
                start = len(seen());xdo('key', 'ctrl+super+d')
                assert edges(seen()[start:],40)==[1,0]
                check(h,env,'return D,SD',b'1\t1\n')
                start=len(seen());xdo('key', 'Caps_Lock', 'super+d', 'Caps_Lock')
                assert edges(seen()[start:],40)==[]
                check(h,env,'return D',b'2\n')
                xdo('key','super+KP_1');check(h,env,'return PAD',b'1\n')
                xdo('key','super+shift+space');check(h,env,'return SPACE',b'1\n')
                # Hold the modifier across both edges to exercise the release handler.
                start=len(seen());xdo('keydown','Super_L');xdo('keydown','F5')
                check(h,env,'return R',b'0\n')
                xdo('keyup','F5');xdo('keyup','Super_L')
                check(h,env,'return R',b'1\n');assert edges(seen()[start:],71)==[]
                # Releasing modifiers first still cannot leak the consumed key-up.
                start=len(seen());xdo('keydown','Super_L');xdo('keydown','d');xdo('keyup','Super_L');xdo('keyup','d')
                assert edges(seen()[start:],40)==[]
                check(h,env,'return D',b'3\n')
                xdo('key','super+F7');check(h,env,'return ERRORS',b'1\n')
                check(h,env,"N=0;K.key{mods={'mod'},key='F8',press=function() N=N+1 end};K.key{mods={'mod'},key='F8',press=function() N=N+10 end}",b'\n')
                xdo('key','super+F8');check(h,env,'return N',b'10\n')
                # Button handlers observe native pointer forwarding, on both edges.
                check(h,env,"BP,BR=0,0;K.button{button=1,press=function(c) assert(c==observer);BP=BP+1;error('button observer') end,release=function(c) assert(c==observer);BR=BR+1;K.button.clear() end}",b'\n')
                xdo('mousemove','--window',window,'300','300');start=len(seen());xdo('click','1')
                check(h,env,'return BP,BR,ERRORS',b'1\t1\t2\n')
                assert len(re.findall(r'wl_pointer\] button:',seen()[start:]))==2,seen()[start:]
                # Default config bindings move a real client to tag 2 and select it.
                xdo('key','super+shift+2')
                wait(h,env,'return observer.tag==s.tags[2],core.client.focused()',b'true\tnil\n',server)
                xdo('key','super+2')
                wait(h,env,'return s.selected_tag==s.tags[2],core.client.focused()==observer.handle',b'true\ttrue\n',server)
                check(h,env,"local found=false;for _,e in ipairs(KEYS) do if e.pressed and e.key=='2' and e.mods.shift then assert(e.utf8=='@');found=true end end;return found",b'true\n')
                fd,_=spawn(h,env,work,'KEYBOARD');fds.append(fd)
                wait(h,env,'return #client.all()',b'2\n',server)
                check(h,env,"K.key{mods={'mod'},key='r',press=K.focused(function(c) c:lower() end)}",b'\n')
                xdo('key','super+r');time.sleep(.15)
                capture(env,work/'binding-order.png')
                check(h,env,'return s.selected_tag.clients[1].app_id',b'model-KEYBOARD\n')
                xdo('mousemove','--window',window,'750','300');xdo('click','1')
                check(h,env,'return client.focus==observer,core.client.focused()==observer.handle',b'true\ttrue\n')
                xdo('mousemove','--window',window,'300','300');xdo('click','1')
                check(h,env,'return client.focus.app_id',b'model-KEYBOARD\n')
                check(h,env,"ROOTS=0;K.button{button=1,on='root',press=function(c) assert(c==nil);ROOTS=ROOTS+1 end}",b'\n')
                xdo('mousemove','--window',window,'300','10');xdo('click','1')
                check(h,env,'return ROOTS,client.focus.app_id',b'1\tmodel-KEYBOARD\n')
                xdo('key','super+Tab')
                check(h,env,'return client.focus==observer',b'true\n')
                xdo('key','super+Tab')
                check(h,env,'return client.focus.app_id',b'model-KEYBOARD\n')
                check(h,env,"K.key{mods={'mod'},key='F9',press=function() observer:focus() end}",b'\n')
                start=len(seen());xdo('keydown','Super_L');xdo('keydown','F9')
                check(h,env,'return client.focus==observer,core.client.focused()==observer.handle',b'true\ttrue\n')
                held_enter=seen()[start:]
                (work/'held-focus-enter.log').write_text(held_enter)
                assert 'wl_keyboard] enter:' in held_enter and not re.search(r'sym:\s+F9\b', held_enter)
                xdo('keyup','Super_L');xdo('keyup','F9')
                assert edges(seen()[start:],75)==[]
                xdo('key','super+Tab','super+q')
                wait(h,env,'return #client.all(),client.focus==observer',b'1\ttrue\n',server)
                # A registry clear during a held key does not release native ownership.
                check(h,env,"K.key{mods={'mod'},key='F6',press=function() K.key.clear() end}",b'\n')
                start=len(seen());xdo('keydown','Super_L');xdo('keydown','F6')
                check(h,env,'return #K.key.all()',b'0\n')
                xdo('keyup','Super_L');xdo('keyup','F6')
                assert edges(seen()[start:],72)==[]
                start=len(seen());xdo('key','F6');assert edges(seen()[start:],72)==[1,0]
                # Deferred quit safely tears down pending input and client facts.
                check(h,env,"K.key{mods={'mod','shift'},key='q',press=function() core.replay();core.quit() end}",b'\n')
                xdo('key','super+shift+q')
                assert server.wait(timeout=5)==0,log.read_text()
                assert not Path(env['KILN_SOCK']).exists()
            finally:
                cleanup(fds)
        print('PASS: private X11 real keyboard/seat, shifted text/chords, exact/locked mods, release ownership, clear, errors, observed native buttons, default tag bindings and quit')
        print('Binding screenshot:',work.resolve()/'binding-order.png')


def run(h):
    rules_and_actions(h)
    native_input(h)
