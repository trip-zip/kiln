"""Focused pipe/poll/animation assertions over private event loops and real children."""
import c_baseline
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import tempfile
import time

from declaration_checks import check, wait, capture
from model_checks import spawn, cleanup

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = (ROOT/'scripts/fixtures/strip.lua').read_text()


def settles(log, timeout=5):
    end=time.monotonic()+timeout
    previous=None; since=time.monotonic()
    while time.monotonic()<end:
        current=solves(log)
        if current!=previous: previous=current;since=time.monotonic()
        if time.monotonic()-since>.25:return current
        time.sleep(.025)
    raise AssertionError('layout did not settle: '+str(log))


def solves(log):
    counts={}
    for name,n in re.findall(r'Layout (\S+):.*?solve (\d+)',log.read_text()):counts[name]=int(n)
    return counts


def processes(pid):
    result=subprocess.run(['ps','--ppid',str(pid),'-o','pid=,stat='],capture_output=True,text=True)
    return result.stdout.strip()


def timers_and_pipes(h):
    config="""K=require('kiln');EVENTS={};K.on('spawn::out',function(e) EVENTS[#EVENTS+1]=e end)
K.on('spawn::exit',function(e) EVENTS[#EVENTS+1]=e end)
function raw(cmd) EVENTS={};ID=core.spawn_pipe(cmd) end
function result()
 local out,err,exits,code='','',0,nil
 for _,e in ipairs(EVENTS) do if e.id==ID then
  if e.name=='out' then assert(exits==0);if e.fd==1 then out=out..e.data else err=err..e.data end
  else exits=exits+1;code=e.code end
 end end
 return out,err,exits,code
end
"""
    with h.boot(config) as (server,env,work,log):
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        ev("N=0;local id=core.timer(20,function() N=100 end);core.timer_cancel(id);core.timer_cancel(999999);core.timer(15,function() N=N+1;core.timer(0,function() N=N+1 end);error('expected timer') end);core.timer(-1,function() N=N+1 end);collectgarbage()")
        wait(h,env,'return N',b'3\n',server)
        # An existing IPC peer lets us exhaust new descriptors without blocking acceptance.
        # Three free slots fail the second pipe; four reach post-fork setup failure.
        for spare in (3,4):
            with h.connect(env,eof=False) as peer:
                time.sleep(.04)
                fds={int(p.name) for p in Path(f'/proc/{server.pid}/fd').iterdir()}
                soft=0
                while soft-sum(fd<soft for fd in fds)<spare:soft+=1
                original_limit=resource.prlimit(server.pid,resource.RLIMIT_NOFILE)
                try:
                    resource.prlimit(server.pid,resource.RLIMIT_NOFILE,(soft,original_limit[1]))
                    peer.sendall(b'return pcall(core.spawn_pipe,{"sh","-c","sleep 1"})')
                    peer.shutdown(1)
                    answer=b''
                    while chunk:=peer.recv(4096):answer+=chunk
                    assert answer.startswith(b'false\tspawn_pipe setup failed'),answer
                finally:
                    resource.prlimit(server.pid,resource.RLIMIT_NOFILE,original_limit)
            h.healthy(env)
            assert not processes(server.pid),processes(server.pid)
        cases=[('{"printf","a\\nb"}',b'a\nb\t\t1\t0\n'),
               ('"true"',b'\t\t1\t0\n'),('"exit 23"',b'\t\t1\t23\n'),
               ('{"/no/such/kiln-executable"}',b'\t\t1\t127\n'),
               ('"kill -9 $$"',b'\t\t1\t137\n'),
               ('"kill -TERM $$"',b'\t\t1\t143\n'),
               ('{"printf",123}',b'123\t\t1\t0\n'),
               ('"printf out;printf err >&2"',b'out\terr\t1\t0\n')]
        for arg,expected in cases:
            ev('raw('+arg+')')
            wait(h,env,'local _,_,n=result();return n',b'1\n',server)
            check(h,env,'return result()',expected)
        ev('raw({"sh","-c","printf \'%s|%s\' \\"$WAYLAND_DISPLAY\\" \\"$KILN_SOCK\\""})')
        wait(h,env,'local _,_,n=result();return n',b'1\n',server)
        check(h,env,'local o=result();return o',(env['WAYLAND_DISPLAY']+'|'+env['KILN_SOCK']+'\n').encode())
        # A real child checks its blocking flags and emits split bytes on both streams.
        child=work/'bytes.py'
        child.write_text('''import os,sys,time,fcntl
assert not fcntl.fcntl(1,fcntl.F_GETFL)&os.O_NONBLOCK
assert not fcntl.fcntl(2,fcntl.F_GETFL)&os.O_NONBLOCK
for a,b in [(b"\\nA\\0",b"e1\\0"),(b"B\\n\\xc3",b"e2"),(b"\\xa9\\ntail",b"e3")]:
 os.write(1,a);os.write(2,b);time.sleep(.03)
''')
        ev('raw({"python3",'+json.dumps(str(child))+'})')
        wait(h,env,'local _,_,n=result();return n',b'1\n',server)
        check(h,env,'return result()',b'\nA\0B\n\xc3\xa9\ntail\te1\0e2e3\t1\t0\n')
        ev('LINES={};ERR="";EXIT=nil;K.spawn.pipe({"python3",'+json.dumps(str(child))+'},{on_line=function(l) LINES[#LINES+1]=l end,on_err=function(s) ERR=ERR..s end,on_exit=function(c) EXIT=c end})')
        wait(h,env,'return EXIT',b'0\n',server)
        check(h,env,'return #LINES,table.concat(LINES,"|"),ERR',b'4\t|A\0B|\xc3\xa9|tail\te1\0e2e3\n')
        # Burst exceeds pipe capacity many times; compare exact byte counts and stream order.
        child.write_text('import os\nfor i in range(128):\n os.write(1,bytes([i])*8192);os.write(2,bytes([255-i])*8192)\n')
        ev('raw({"python3",'+json.dumps(str(child))+'})')
        start=time.monotonic();h.healthy(env);assert time.monotonic()-start<2
        wait(h,env,'local _,_,n=result();return n',b'1\n',server)
        check(h,env,"local a,b,n,c=result();for i=0,127 do assert(a:sub(i*8192+1,(i+1)*8192)==string.rep(string.char(i),8192));assert(b:sub(i*8192+1,(i+1)*8192)==string.rep(string.char(255-i),8192)) end;return #a,#b,n,c",b'1048576\t1048576\t1\t0\n')
        ev("raw('exec 1>&- 2>&-;sleep .3;exit 7')")
        h.healthy(env);time.sleep(.08);check(h,env,'local _,_,n=result();return n',b'0\n')
        wait(h,env,'local _,_,n,c=result();return n,c',b'1\t7\n',server)
        ev("raw('(sleep .4;printf descendant)& printf parent;exit 0')")
        time.sleep(.1);h.healthy(env);check(h,env,'local _,_,n=result();return n',b'0\n')
        wait(h,env,'local _,_,n=result();return n',b'1\n',server)
        check(h,env,'return result()',b'parentdescendant\t\t1\t0\n')
        ev("raw('sleep .35;printf slow');FAST=0;for i=1,20 do K.spawn.pipe({'true'},{on_exit=function() FAST=FAST+1 end});core.spawn('true') end")
        wait(h,env,'return FAST',b'20\n',server)
        wait(h,env,'local _,_,n=result();return n',b'1\n',server)
        # Callback failures still flush every line, deliver exit, and retire registrations.
        ev("ERRS=0;K.on('error',function() ERRS=ERRS+1 end);DONE=0;K.spawn.pipe(\"printf 'a\\nb';printf err >&2\",{on_line=function() error('line') end,on_err=function() error('err') end,on_exit=function() DONE=DONE+1;error('exit') end})")
        wait(h,env,'return DONE,ERRS',b'1\t4\n',server)
        baseline=len(list(Path(f'/proc/{server.pid}/fd').iterdir()))
        ev("EVENTS={};BEATS=0;BEAT=K.spawn.watch({'true'},.02,{done=function() BEATS=BEATS+1 end})")
        time.sleep(3);early=int(h.ev(env,'return BEATS'));time.sleep(3);late=int(h.ev(env,'return BEATS'))
        assert early>50 and late>early+50,(early,late)
        ev('BEAT:stop()');time.sleep(.15)
        assert 'Z' not in processes(server.pid),processes(server.pid)
        ev("BADRUNS=0;W=K.spawn.watch('echo x;sleep .02',.01,{line=function() error('watch line') end,done=function() BADRUNS=BADRUNS+1;error('watch done') end})")
        wait(h,env,'return BADRUNS>=20',b'true\n',server);ev('W:stop()');time.sleep(.1)
        assert not processes(server.pid),processes(server.pid)
        # Repeated create/cancel/reset cycles must return descriptor and child counts to rest.
        for _ in range(4):
            ev("for i=1,40 do local t=core.timer(10000,function() end);core.timer_cancel(t);K.spawn.pipe({'true'},{}) end")
            time.sleep(.3)
        assert len(list(Path(f'/proc/{server.pid}/fd').iterdir()))==baseline
        assert not processes(server.pid),processes(server.pid)
        ev("LATE=0;W=K.spawn.watch('sleep .15;echo late',.01,{line=function() LATE=LATE+1 end,done=function() LATE=LATE+100 end});W:stop()")
        wait(h,env,'return LATE',b'1\n',server);time.sleep(.15);check(h,env,'return LATE',b'1\n')
        ev("W=K.spawn.watch('sleep .15;echo late',.01,function() LATE=1000 end);K.spawn.reset()")
        time.sleep(.25);check(h,env,'return LATE',b'1\n')
        ev("W=K.spawn.watch('true',10,function() end)")
        time.sleep(.1);ev('K.spawn.reset();core._timers_reset()')
        assert len(list(Path(f'/proc/{server.pid}/fd').iterdir()))==baseline
        # Preserve already launched applications across reset, then quit without waiting for pipes.
        receipt=work/'survived-reset'
        ev('K.spawn.pipe('+json.dumps('sleep .2;touch '+str(receipt))+',{});K.spawn.reset()')
        time.sleep(.3);assert receipt.exists()
        ev("core.timer(10000,function() error('late') end);K.spawn.pipe('sleep .7',{});core.timer(0,function() core.quit() end)")
        assert server.wait(timeout=2)==0
        assert not Path(env['KILN_SOCK']).exists()
        assert 'Async cleanup: timers 0, pipes 0' in log.read_text()
        (work/'endurance.json').write_text(json.dumps(dict(early=early,late=late,fd_baseline=baseline,children=processes(server.pid)),indent=2))
    print('PASS: actual timers, byte-exact pipes, EOF/reap ordering, callback recovery, watch endurance and resource retirement',flush=True)


def polls_and_animation(h):
    config=DEFAULT.replace("ui.text('Kiln',", "ui.text('Polled: '..(P and P.value or ''),")+'''
K=require('kiln');A=screen.all()[1];B=screen.all()[2];TICKS={};DTS={}
K.on('frame::tick',function(e) TICKS[e.screen]=(TICKS[e.screen] or 0)+1;DTS[#DTS+1]=e.dt end)
'''
    with h.boot(config,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        fds=[]
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        try:
            an,bn=h.ev(env,'return A.name,B.name').decode().strip().split('\t')
            settles(log)
            baseline=solves(log);ev('core.timer(10,function() TIMER=true end)');time.sleep(.15)
            check(h,env,'return TIMER',b'true\n');assert solves(log)==baseline
            ev('TICKS={};core.tick(A.name,true);core.tick(A.name,true)');time.sleep(.12)
            check(h,env,'return (TICKS[A.name] or 0)>3,TICKS[B.name]',b'true\tnil\n')
            assert solves(log)==baseline
            ev('core.tick(A.name,false);core.tick(A.name,false);core.tick("missing",true)')
            answers=work/'answer';answers.write_text('first\n')
            ev('RUNS=0;P=K.poll{cmd={"cat",'+json.dumps(str(answers))+'},every=.04,screen=A.name,parse=function(ls) RUNS=RUNS+1;return ls[1] end}')
            wait(h,env,'return P.value',b'first\n',server);baseline=settles(log)
            capture(env,work/'poll-first.png')
            time.sleep(.3);assert solves(log)==baseline
            answers.write_text('moved\nsecond\nthird\n')
            wait(h,env,'return table.concat(P.lines,"|")',b'moved|second|third\n',server)
            after=settles(log);assert after[an]>baseline[an] and after[bn]==baseline[bn],(baseline,after)
            ev("P:stop();L=K.poll{'printf early; sleep .2;printf late',every=.01,screen=A.name};L:stop()")
            time.sleep(.3);check(h,env,'return L.value,#L.lines',b'nil\t0\n')
            # Parse errors preserve both previous fields, then the next run recovers.
            ev("PARSES=0;E=K.poll{'printf \\\"a\\\\nb\\\\n\\\"',every=.03,screen=A.name,parse=function(ls) PARSES=PARSES+1;if PARSES==1 then error('parse') end;return #ls end}")
            wait(h,env,'return E.value',b'2\n',server);ev('E:stop()')
            for name in ('ANIM-MASTER','ANIM-STACK'):
                fd,_=spawn(h,env,work,name);fds.append(fd)
            wait(h,env,'return #client.all()',b'2\n',server)
            ev('C1,C2=unpack(client.all());t=A.selected_tag')
            baseline=settles(log)
            ev('TICKS={};t.master_width_factor=.8')
            # Capture while a slowed Lua policy animation is between endpoints.
            ev("K.animation.start(A.name,'mwf:'..tostring(t),.8,1,.5)")
            time.sleep(.12)
            value=float(h.ev(env,"return K.animation.get('mwf:'..tostring(t),t.master_width_factor)"))
            assert .5<value<.8,value
            capture(env,work/'animation-middle.png')
            middle=h.ev(env,"local b=core.box({'client',C1.handle});return b.x,b.y,b.width,b.height,K.animation.get('mwf:'..tostring(t),t.master_width_factor)").decode().strip()
            final=settles(log)
            capture(env,work/'animation-final.png')
            check(h,env,"return K.animation.get('mwf:'..tostring(t),t.master_width_factor)",b'0.8\n')
            assert final[an]>baseline[an]+3 and final[bn]==baseline[bn],(baseline,final)
            ticks=h.ev(env,'return TICKS[A.name],TICKS[B.name]').decode().strip();assert ticks.endswith('nil')
            time.sleep(.3);assert solves(log)==final
            # Retarget keeps the current interpolated value; transfer releases the old clock.
            ev("K.animation.start(A.name,'transfer',1,1,0)");time.sleep(.06)
            ev("local a=K.animation.get('transfer',0);K.animation.start(B.name,'transfer',2,.12);assert(a==K.animation.get('transfer',0));K.animation.start(B.name,'second',1,.2,0)")
            settles(log);baseline=solves(log);time.sleep(.3);assert solves(log)==baseline
            # A synchronous stall reaches native dt unmodified but policy advances <= .05.
            ev("DTS={};K.animation.start(A.name,'stall',1,1,0);local until_time=os.clock()+.2;while os.clock()<until_time do end")
            wait(h,env,'return #DTS>0',b'true\n',server)
            check(h,env,'return DTS[1]>.15',b'true\n')
            v=float(h.ev(env,"return K.animation.get('stall',0)"));assert v<.5,v
            ev('K.animation.reset()');settles(log)
            # Tag reveal changes only transient tiled padding, retaining placement workarea.
            ev('C2.tag=A.tags[2];A.tags[2]:view()')
            time.sleep(.035)
            reveal=h.ev(env,"local b=core.box({'client',C2.handle});local w=A.workarea;return b.x,b.y,b.width,b.height,w.x,w.y,w.width,w.height").decode().strip()
            capture(env,work/'tag-middle.png');settles(log);capture(env,work/'tag-final.png')
            settled=h.ev(env,"local b=core.box({'client',C2.handle});local w=A.workarea;return b.x,b.y,b.width,b.height,w.x,w.y,w.width,w.height").decode().strip()
            assert reveal.split()[4:]==settled.split()[4:]
            assert int(float(reveal.split()[0]))>int(float(settled.split()[0])),(reveal,settled)
            # Paint a small label driven by a changing poll, using the existing frame.
            settles(log);capture(env,work/'polled-label.png')
            (work/'animation.json').write_text(json.dumps(dict(middle=middle,ticks=ticks,reveal=reveal,settled=settled,final_solves=solves(log)),indent=2))
            h.quit(server,env,log)
        finally:cleanup(fds)
    print('PASS: two-output polls, atomic answers, isolated ticks, retarget, true dt, reveal geometry and settled idle',flush=True)


def native_responsiveness(h):
    from policy_checks import private_x11
    from window_state_checks import stop
    with private_x11(h.out) as display:
        config=DEFAULT+"""
K=require('kiln');TEXT='';FINISHED=false
K.key{key='F6',press=function()
 G=K.keygrabber{key=function(e)
  if e.pressed then if e.key=='Escape' then G:stop() else TEXT=TEXT..e.utf8 end end
 end}
end}
"""
        with h.boot(config,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            with (work/'wev.log').open('w') as output:
                observer=subprocess.Popen(['stdbuf','-oL','wev'],env=env,stdout=output,stderr=output)
                try:
                    wait(h,env,'return #client.all()',b'1\n',server)
                    settles(log)
                    window=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1]
                    child=work/'busy.py'
                    child.write_text('import os,time\nfor i in range(300):\n os.write(1,b"x"*8192);time.sleep(.005)\n')
                    check(h,env,'K.spawn.pipe({"python3",'+json.dumps(str(child))+'},{on_exit=function() FINISHED=true end});K.animation.start(screen.all()[1].name,"busy",1,2,0)',b'\n')
                    subprocess.run(['xdotool','windowfocus',window,'key','F6','a','Escape','b'],env=env,check=True,timeout=5)
                    wait(h,env,'return TEXT,G.active',b'a\tfalse\n',server)
                    deadline=time.monotonic()+3
                    while not re.search(r'key: 56; state: 0', (work/'wev.log').read_text()):
                        assert time.monotonic()<deadline
                        time.sleep(.02)
                    seen=(work/'wev.log').read_text()
                    assert not re.search(r'wl_keyboard\] key:.*?key: 38;',seen),seen
                    assert re.search(r'wl_keyboard\] key:.*?key: 56; state: 1',seen),seen
                    h.healthy(env)
                    wait(h,env,'return FINISHED',b'true\n',server)
                    settles(log)
                    capture(env,work/'responsive-after-work.png')
                    h.quit(server,env,log)
                finally:stop(observer)
    print('PASS: native grab, consumed text, release and client recovery during pipe traffic and animation',flush=True)


def run(h):
    timers_and_pipes(h)
    polls_and_animation(h)
    native_responsiveness(h)


if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    out=Path(tempfile.mkdtemp(prefix='async-',dir=ROOT/'build/verification'))
    print('Artifacts:',out,flush=True)
    with tempfile.TemporaryDirectory(prefix='ka-') as short:
        alias=Path(short)/'e';alias.symlink_to(out,target_is_directory=True)
        run(module.Harness(ROOT/'build/kiln',c_baseline.source(),alias))
