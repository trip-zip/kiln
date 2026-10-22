"""XWayland checks always separate the owned outer and inner X displays."""
import c_baseline
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

from declaration_checks import check, wait, settle, capture
from layout_checks import DEFAULT
from policy_checks import private_x11
from window_state_checks import launch


def until(predicate, message, seconds=10):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        if predicate(): return
        time.sleep(.025)
    raise AssertionError(message)


def server_pids(display):
    result=[]
    for p in Path('/proc').iterdir():
        if not p.name.isdigit():continue
        try:args=(p/'cmdline').read_bytes().split(b'\0')
        except (FileNotFoundError,PermissionError,ProcessLookupError):continue
        if args and args[0].split(b'/')[-1]==b'Xwayland' and display.encode() in args:
            result.append(int(p.name))
    return result


def dependencies():
    for name in ('Xwayland','Xvfb','xterm','xprop','xwininfo','xdotool','foot','grim'):
        assert shutil.which(name),f'required XWayland dependency missing: {name}'


def startup(h):
    dependencies()
    with private_x11(h.out) as outer:
        for backend in ('headless','x11'):
            overrides={'DISPLAY':outer,'WAYLAND_DISPLAY':None,'WLR_BACKENDS':backend,
                       'XDG_DATA_HOME':h.out/'data','XDG_CACHE_HOME':h.out/'cache'}
            with h.boot(DEFAULT,overrides=overrides,startup='printf "%s" "$DISPLAY" > "$XDG_RUNTIME_DIR/startup-display"') as (server,env,work,log):
                inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip()
                assert inner.startswith(':') and inner!=outer,(outer,inner)
                assert 'XWayland reserved DISPLAY='+inner in log.read_text()
                assert 'XWayland ready' not in log.read_text() and not server_pids(inner)
                until(lambda:(work/'runtime/startup-display').exists(),'startup child receipt')
                assert (work/'runtime/startup-display').read_text()==inner
                check(h,env,"K=require('kiln');PIPE_ENV=nil;PIPE_EXIT=nil;K.spawn.pipe({'sh','-c','printf \"%s\\\\n\" \"$DISPLAY\"'},{on_line=function(s)PIPE_ENV=s end,on_exit=function(c)PIPE_EXIT=c end})",b'\n')
                wait(h,env,'return PIPE_ENV,PIPE_EXIT',(inner+'\t0\n').encode(),server)
                for label,verb in [('spawn','core.spawn'),('launcher',"require('kiln.launcher').spawn")]:
                    target=work/(label+'-display')
                    command='printf "%s" "$DISPLAY" > '+str(target)
                    check(h,env,verb+'('+json.dumps(command)+')',b'\n')
                    until(target.exists,label+' receipt');assert target.read_text()==inner
                # The harness environment stays on the outer display for backend input.
                assert env['DISPLAY']==outer
                native,f=launch(env,work,'XWL-NATIVE-ONLY')
                try:
                    wait(h,env,'return #client.all()',b'1\n',server)
                    assert not server_pids(inner),'native-only launch started XWayland'
                    if backend=='headless':
                        h.quit(server,env,log)
                        assert 'XWayland ready' not in log.read_text()
                    else:
                        inner_env=dict(env,DISPLAY=inner)
                        with (work/'root-observer.log').open('w') as receipt:
                            probe=subprocess.Popen(['xprop','-spy','-root','_NET_SUPPORTING_WM_CHECK'],env=inner_env,stdout=receipt,stderr=receipt)
                            try:
                                until(lambda:'XWayland ready' in log.read_text(),'lazy readiness')
                                assert 'seat=true' in log.read_text()
                                until(lambda:bool(server_pids(inner)),'actual XWayland process')
                                pids=server_pids(inner);assert len(pids)==1,pids
                                assert probe.poll() is None
                                launcher=int(re.search(r'launcher_pid=(\d+)',log.read_text())[1])
                                assert launcher!=pids[0] and not Path('/proc/'+str(launcher)).exists()
                                (work/'startup.json').write_text(json.dumps(dict(outer=outer,inner=inner,compositor=server.pid,launcher=launcher,xwayland=pids[0]),indent=2)+'\n')
                                h.quit(server,env,log)
                            finally:
                                if probe.poll() is None:probe.terminate()
                                probe.wait(timeout=5)
                        until(lambda:not server_pids(inner),'owned X server survived shutdown')
                finally:
                    if native.poll() is None:native.terminate()
                    native.wait(timeout=5);f.close()
                assert not Path('/tmp/.X11-unix/X'+inner[1:]).exists(),'owned X socket leaked'
                print(f'PASS: XWayland startup backend={backend} outer={outer} inner={inner}',flush=True)
        with h.boot(DEFAULT,overrides={'DISPLAY':outer,'WAYLAND_DISPLAY':None,'WLR_XWAYLAND':'/nonexistent/kiln-owned-Xwayland'}) as (server,env,work,log):
            inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip()
            assert inner.startswith(':') and inner!=outer
            result=subprocess.run(['xprop','-root'],env=dict(env,DISPLAY=inner),capture_output=True,timeout=10)
            assert result.returncode!=0
            wait(h,env,'return os.getenv("DISPLAY")',b'kiln-x11-unavailable\n',server)
            assert 'Xwayland startup failed' in log.read_text()
            native,f=launch(env,work,'XWL-MISSING-NATIVE')
            try:
                wait(h,env,'return #client.all()',b'1\n',server);h.healthy(env);h.quit(server,env,log)
            finally:
                if native.poll() is None:native.terminate()
                native.wait(timeout=5);f.close()
            assert not server_pids(inner) and not Path('/tmp/.X11-unix/X'+inner[1:]).exists()
            print(f'PASS: missing XWayland keeps native clients/IPC alive outer={outer} failed inner={inner}',flush=True)


def xcommand(env,*args):
    return subprocess.check_output(list(map(str,args)),env=env,stderr=subprocess.STDOUT,timeout=5)


def model(h):
    from protocol_client import Client
    from model_checks import CAPTURE
    config=CAPTURE+DEFAULT+"""
K=require('kiln');RULES=0
K.rule{match={class='^KilnX11$',instance='^kiln%-x11%-a$'},props={test_match=true},on=function(c) RULES=RULES+1;assert(c.app_id==nil and c.title=='X11 Alpha') end}
"""
    with h.boot(config,overrides={'DISPLAY':None,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
        inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip()
        xenv=dict(env,DISPLAY=inner);processes=[];files=[];observer=Client(env)
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        def yes(s):wait(h,env,'return '+s,b'true\n',server)
        def handles():return {o:m for o,(k,m) in observer.objects.items() if k=='foreign' and not m.get('closed')}
        try:
            observer.bind('zwlr_foreign_toplevel_manager_v1',3)
            f=(work/'xterm.log').open('w');files.append(f)
            xterm=subprocess.Popen(['xterm','-name','kiln-x11-a','-class','KilnX11','-title','X11 Alpha','-e','sh','-c','printf "X11 Alpha\\n"; exec sleep 1000'],env=xenv,stdout=f,stderr=f);processes.append(xterm)
            yes('#client.all()==1');ev('A=client.all()[1];AH=A.handle;assert(A.test_match and RULES==1 and A.instance=="kiln-x11-a" and A.pid=='+str(xterm.pid)+')')
            wid=int(xcommand(xenv,'xdotool','search','--classname','^kiln-x11-a$').splitlines()[0])
            props=xcommand(xenv,'xprop','-id',wid,'WM_CLASS','_NET_WM_PID','WM_NAME').decode()
            assert '"kiln-x11-a", "KilnX11"' in props and str(xterm.pid) in props and 'X11 Alpha' in props,props
            (work/'xprop-map.txt').write_text(props)
            native,f=launch(env,work,'MIXED-FOOT');processes.append(native);files.append(f)
            yes('#client.all()==2');settle(log);observer.pump(.3)
            assert {m['app_id'] for m in handles().values()}=={'KilnX11','MIXED-FOOT'},handles()
            fa=next(o for o,m in handles().items() if m['app_id']=='KilnX11')
            assert handles()[fa]['title']=='X11 Alpha' and handles()[fa]['outputs']
            capture(env,work/'mixed-xterm-foot.png')
            xcommand(xenv,'xdotool','set_window','--class','ChangedClass','--classname','changed-instance',wid)
            xcommand(xenv,'xdotool','set_window','--name','Changed title',wid)
            yes("A.class=='ChangedClass' and A.instance=='changed-instance' and A.title=='Changed title' and A.app_id==nil")
            observer.pump(.3);assert handles()[fa]['app_id']=='ChangedClass' and handles()[fa]['title']=='Changed title'
            # Real XUnmapWindow withdraws and dissociates; XMapWindow reacquires a surface.
            for n in range(3):
                ev('RULES_BEFORE=RULES')
                xcommand(xenv,'xdotool','windowunmap',wid);yes('not A.mapped');observer.pump(.15);assert fa not in handles()
                xcommand(xenv,'xdotool','windowmap',wid);yes('A.mapped and A.handle==AH and #client.all()==2 and RULES==RULES_BEFORE')
                observer.pump(.25);fa=next(o for o,m in handles().items() if m['app_id']=='ChangedClass')
                ev('K.reload()');yes('#client.all()==2');ev('A=require("kiln.object").lookup(AH)');observer.pump(.2);assert fa in handles()
            rows=re.findall(r'X11 associate window='+str(wid)+r' handle=(\d+) tree=(\S+)',log.read_text())
            assert len(rows)>=4 and len(set(rows))==1,rows
            assert log.read_text().count('X11 dissociate window='+str(wid))>=3
            (work/'model-foreign.json').write_text(json.dumps(observer.records,indent=2)+'\n')
            ev('A:close()');until(lambda:xterm.poll() is not None,'xterm close');yes('#client.all()==1');observer.pump(.2);assert fa not in handles()
            h.quit(server,env,log)
        finally:
            observer.close()
            for p in processes:
                if p.poll() is None:p.terminate()
                p.wait(timeout=5)
            for f in files:f.close()
        until(lambda:not server_pids(inner),'XWayland survived model shutdown')
        print('PASS: X11/foot metadata, WM_CLASS rules, foreign mirror, real dissociate/remap identity and reload; inner='+inner,flush=True)


def geometry(h):
    from x11_client import XClient
    config=DEFAULT+"\nK=require('kiln')\n"
    with h.boot(config,overrides={'DISPLAY':None,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
        inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip();xenv=dict(env,DISPLAY=inner)
        processes=[];files=[];query=None;rows=[]
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        def yes(s):wait(h,env,'return '+s,b'true\n',server)
        def box(c):
            return [int(float(v)) for v in h.ev(env,"core.hits("+c+".screen.name,0,0);local b=core.box({'core.surface',"+c+".handle});return math.floor(b.x)+"+c+".screen.x,math.floor(b.y)+"+c+".screen.y,math.floor(b.width),math.floor(b.height)").split()]
        def agree(label,c,wid):
            settle(log)
            def published():
                found=re.findall(r'X11 published window='+str(wid)+r' handle=\d+ box=(-?\d+),(-?\d+),(\d+),(\d+)',log.read_text())
                assert found,log.read_text()
                return list(map(int,found[-1]))
            until(lambda:query.geometry(wid)==published(),label+' X/published disagreement')
            expected=query.geometry(wid)
            yes(f'{c}.width=={expected[2]} and {c}.height=={expected[3]}')
            rounded=box(c)
            assert all(abs(a-b)<=1 for a,b in zip(expected,rounded)),(expected,rounded)
            rows.append(dict(label=label,client=c,xserver=expected,published=published(),rounded_public_box=rounded,committed=list(map(int,h.ev(env,f'return {c}.width,{c}.height').split()))))
            return expected
        try:
            for name in ('a','b'):
                f=(work/(name+'.log')).open('w');files.append(f)
                processes.append(subprocess.Popen(['xterm','-name','reposition-'+name,'-e','sleep','1000'],env=xenv,stdout=f,stderr=f))
                yes('#client.all()=='+str(len(processes)))
            query=XClient(inner)
            a,b=[int(xcommand(xenv,'xdotool','search','--classname','^reposition-'+n+'$').splitlines()[0]) for n in ('a','b')]
            ev("for _,c in ipairs(client.all())do if c.instance=='reposition-a' then A=c else B=c end end;S=A.screen;S.selected_tag.master_width_factor=.7")
            beforea=agree('unequal','A',a);beforeb=agree('unequal','B',b);assert beforea[2]!=beforeb[2]
            ev('S.selected_tag.master_width_factor=.5');a5=agree('equal','A',a);b5=agree('equal','B',b);assert a5[2:]==b5[2:]
            ev('A:swap(B)');a6=agree('pure move','A',a);b6=agree('pure move','B',b)
            assert a6==b5 and b6==a5,(a5,b5,a6,b6)
            ev('core.output.set_position(S.name,137,91)');agree('non-origin','A',a);agree('non-origin','B',b)
            ev('A.floating=true;A.float={x=80,y=110,width=430,height=310}');agree('Lua float','A',a)
            ev('A.float={x=120,y=150,width=510,height=350}');agree('Lua move resize','A',a)
            # The client's request is an owned fact, not an implicit move grant.
            ev("ASK=nil;A:on('request::configure',function(c,e) ASK=e end)")
            old=box('A');query.configure(a,x=444,width=222)
            yes('ASK and ASK.x==444 and ASK.width==222');assert query.geometry(a)==old
            ev('A:close()');until(lambda:processes[0].poll() is not None,'close A');yes('#client.all()==1')
            assert processes[1].poll() is None and server_pids(inner)
            # A pre-map partial configure preserves fields absent from the event mask.
            pre=query.create(instance='premap',map_now=False,box=(31,43,210,160))
            time.sleep(.1);query.configure(pre,width=333)
            until(lambda:query.geometry(pre)==[31,43,333,160],'pre-map configure mask')
            query.destroy(pre)
            dead=XClient(inner);dead.create(instance='disconnect-before-map',map_now=False);dead.sync();dead.close();time.sleep(.1)
            capture(env,work/'x11-reposition.png')
            (work/'geometry.json').write_text(json.dumps(rows,indent=2)+'\n')
            h.quit(server,env,log)
        finally:
            if query:query.close()
            for p in processes:
                if p.poll() is None:p.terminate()
                p.wait(timeout=5)
            for f in files:f.close()
    print('PASS: unequal/equal/pure-move X geometry agrees with commits and published boxes; pre-map masks, mapped policy, non-origin Lua moves and close',flush=True)


def input_and_kill(h):
    from x11_client import XClient
    from protocol_client import Client
    with private_x11(h.out) as outer:
        with h.boot(DEFAULT+"\nK=require('kiln')\n",overrides={'DISPLAY':outer,'WAYLAND_DISPLAY':None,'WLR_BACKENDS':'x11'}) as (server,env,work,log):
            inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip();assert inner!=outer
            xenv=dict(env,DISPLAY=inner);x=XClient(inner);other=XClient(inner);native=Client(env);processes=[];files=[]
            def ev(s):check(h,env,'do '+s+' end',b'\n')
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            def pump():x.pump(.06);other.pump(.06);native.pump(.06)
            def xdo(*args):xcommand(env,'xdotool',*args);pump()
            def local_point(c,dx,dy):
                px,py=map(float,h.ev(env,"core.hits("+c+".screen.name,0,0);local b=core.box({'core.surface',"+c+".handle});return b.x,b.y").split())
                xdo('mousemove','--window',outer_window,int(px+dx),int(py+dy))
            try:
                w=x.create(instance='input-wire');pump();yes('#client.all()==1');ev('W=client.all()[1]')
                second=other.create(instance='survivor-wire');pump();yes('#client.all()==2')
                foot,f=launch(env,work,'KILL-SURVIVOR-FOOT');processes.append(foot);files.append(f);yes('#client.all()==3')
                native_window=native.toplevel('input-native');pump();yes('#client.all()==4')
                ev("for _,c in ipairs(client.all())do if c.app_id=='input-native' then N=c elseif c.instance=='survivor-wire' then O=c end end;W.floating=true;W.float={x=80,y=90,width=440,height=330};W:raise();W:focus()")
                yes('core.client.focused()==W.handle');until(lambda:x.focus()==w,'real X focus')
                outer_window=xcommand(env,'xdotool','search','--name','').decode().splitlines()[-1]
                xdo('windowfocus',outer_window);local_point('W',55,66);before=len(x.records);xdo('click',1);xdo('key','a')
                receipts=x.records[before:]
                assert any(r['event']==4 and r['window']==w and r['local']==[55,66] and not r['synthetic'] for r in receipts),receipts
                assert any(r['event']==2 and r['window']==w and not r['synthetic'] for r in receipts),receipts
                ev('N:focus()');pump();yes('core.client.focused()==N.handle');assert x.focus()!=w
                before=len(x.records);xdo('key','b');assert not any(r['event']==2 for r in x.records[before:])
                assert any(r.get('input')=='keyboard' and r['op']==3 for r in native.records),native.records[-10:]
                ev('W:focus();G=K.keygrabber{}');before=len(x.records);xdo('key','c');assert not any(r['event']==2 for r in x.records[before:]);ev('G:stop()')
                before=len(x.records);xdo('key','d');assert any(r['event']==2 for r in x.records[before:])
                ev("BOUND=0;K.key{key='F9',press=function()BOUND=BOUND+1 end}");before=len(x.records);xdo('key','F9');yes('BOUND==1');assert not any(r['event']==2 for r in x.records[before:])
                ev("ACT=nil;client.on('request::activate',function(c,e)ACT={handle=c.handle,valid=e.valid}end);N:focus();W.urgent=false")
                x.activate(w);pump();yes('ACT and not ACT.valid and ACT.handle==W.handle and W.urgent and core.client.focused()==N.handle')
                ev('K.defaults.activate=function(c,e)c:focus()end');x.activate(w);pump();yes('core.client.focused()==W.handle')
                for prop,atom in [('fullscreen','_NET_WM_STATE_FULLSCREEN'),('maximized','_NET_WM_STATE_MAXIMIZED_VERT'),('minimized','_NET_WM_STATE_HIDDEN')]:
                    ev('W.'+prop+'=true');pump()
                    until(lambda:atom in xcommand(xenv,'xprop','-id',w,'_NET_WM_STATE').decode(),'X11 '+prop+' hint')
                    ev('W.'+prop+'=false');pump()
                    until(lambda:atom not in xcommand(xenv,'xprop','-id',w,'_NET_WM_STATE').decode(),'X11 '+prop+' clear')
                # Text is consumed by a real terminal's child, not inferred from keycodes.
                receipt=work/'typed.txt';ready=work/'text-ready';f=(work/'text-xterm.log').open('w');files.append(f)
                command=': > '+str(ready)+'; read -r line; printf "%s" "$line" > '+str(receipt)+'; exec sleep 1000'
                terminal=subprocess.Popen(['xterm','-name','text-receipt','-e','sh','-c',command],env=xenv,stdout=f,stderr=f);processes.append(terminal)
                yes('#client.all()==5');ev("for _,c in ipairs(client.all())do if c.instance=='text-receipt' then T=c end end;T:focus()")
                # Lua focus returns before the X server and terminal child have processed it.
                terminal_window=int(xcommand(xenv,'xdotool','search','--classname','^text-receipt$').strip())
                until(ready.exists,'X terminal child ready');until(lambda:x.focus()==terminal_window,'X terminal focus')
                xdo('type','--clearmodifiers','kiln X11 text');xdo('key','Return');until(receipt.exists,'X terminal text receipt');assert receipt.read_text()=='kiln X11 text',repr(receipt.read_text())
                xpid=server_pids(inner);assert len(xpid)==1
                ev('T:kill()');until(lambda:terminal.poll() is not None,'isolated terminal kill');yes('#client.all()==4')
                assert foot.poll() is None and server_pids(inner)==xpid and other.focus() is not None
                # Two windows of one connection deliberately share XKillClient fate.
                sibling=x.create(instance='same-connection');pump();yes('#client.all()==5');ev('W:kill()');pump();until(lambda:(x.pump(.03) or x.closed),'X connection kill')
                yes('#client.all()==3');assert other.geometry(second)[2]>0 and foot.poll() is None and server_pids(inner)==xpid
                (work/'input-receipts.json').write_text(json.dumps(dict(outer=outer,inner=inner,server=xpid[0],x=x.records,native=native.records,text=receipt.read_text()),indent=2)+'\n')
                capture(env,work/'isolated-kill-survivors.png');h.quit(server,env,log)
            finally:
                x.close();other.close();native.close()
                for p in processes:
                    if p.poll() is None:p.terminate()
                    p.wait(timeout=5)
                for f in files:f.close()
            until(lambda:not server_pids(inner),'input test X server shutdown')
            print(f'PASS: actual X11 pointer/key/text, native focus, grabs/consumption, untrusted activation and isolated connection kill; outer={outer} inner={inner}',flush=True)


def mixed_scale(h):
    from x11_client import XClient
    from protocol_client import Client
    from layer_checks import CONFIG
    from PIL import Image,ImageChops
    with private_x11(h.out) as outer:
        with h.boot(CONFIG,overrides={'DISPLAY':outer,'WAYLAND_DISPLAY':None,'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2'}) as (server,env,work,log):
            inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip();x=XClient(inner);native=Client(env,fractional=True);proof=[]
            def ev(s):check(h,env,'do '+s+' end',b'\n')
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            def pump():x.pump(.06);native.pump(.1)
            def xdo(*args):xcommand(env,'xdotool',*args);pump()
            def shot(name,output,cursor=True):
                path=work/(name+'.png');subprocess.run(['grim',*(['-c'] if cursor else []),'-o',output,str(path)],env=env,check=True,timeout=5)
                return Image.open(path).convert('RGB')
            def public(c):return list(map(float,h.ev(env,f"core.hits({c}.screen.name,0,0);local b=core.box({{'core.surface',{c}.handle}});return b.x,b.y,b.width,b.height").split()))
            try:
                ev("for _,s in ipairs(screen.all())do if s.name=='X11-1' then S=s else T=s end end;core.output.set_position(S.name,137,91);core.output.set_position(T.name,1500,73);screen.focused=S")
                w=x.create(instance='scaled-wire');pump();yes('#client.all()==1');ev('W=client.all()[1]')
                a=native.toplevel('density-native');pump();yes('#client.all()==2');ev("for _,c in ipairs(client.all())do if c.app_id=='density-native' then N=c end end;W.floating=true;N.floating=true;W.float={x=20,y=55,width=220,height=260};N.float={x=270,y=55,width=220,height=260}")
                windows=xcommand(env,'xdotool','search','--name','').decode().splitlines();assert len(windows)==3,windows
                x.cursor(w)
                for i,(target,scale,other_scale) in enumerate([('S',1,1.5),('S',1.5,2),('S',2,1),('T',1.5,2)]):
                    other='T' if target=='S' else 'S'
                    ev(f'{target}.scale={scale};{other}.scale={other_scale};W:move_to({target});N:move_to({target});W.float={{x=20,y=55,width=220,height=260}};N.float={{x=270,y=55,width=220,height=260}};W:focus()')
                    pump();settle(log);native.pump(.2)
                    yes(f'W.width==216 and W.height==234 and N.width==216 and N.height==234')
                    assert a['scale120']==int(scale*120),a
                    assert a['buffer_size']==(round(216*scale),round(234*scale)),a
                    ox,oy,lw,lh=map(float,h.ev(env,f'return {target}.x,{target}.y,{target}.width,{target}.height').split())
                    xb=public('W');assert x.geometry(w)==[int(ox+xb[0]),int(oy+xb[1]),216,234]
                    x.paint(w);pump()
                    win=windows[-2 if target=='S' else -1];output='X11-1' if target=='S' else 'X11-2'
                    xdo('windowraise',win);xdo('windowfocus',win)
                    def point(lx,ly):xdo('mousemove','--window',win,round(lx*1024/lw),round(ly*768/lh))
                    before=len(x.records);point(xb[0]+55,xb[1]+66);xdo('click',1)
                    buttons=[r for r in x.records[before:] if r['event']==4 and r['window']==w]
                    assert buttons and all(abs(v-e)<=1 for v,e in zip(buttons[-1]['local'],[55,66])),buttons
                    image=shot(f'mixed-{i}-{scale}',output)
                    expected=[(xb[0]+55)*scale,(xb[1]+66)*scale]
                    point(xb[0]+135,xb[1]+136)
                    moved=shot(f'cursor-moved-{i}',output)
                    difference=ImageChops.difference(image,moved)
                    def cursor_bounds(px,py):
                        region=(round(px-24*scale),round(py-24*scale),round(px+32*scale),round(py+32*scale))
                        local=difference.crop(region).getbbox();assert local,(i,scale,region)
                        return [local[0]+region[0],local[1]+region[1],local[2]+region[0],local[3]+region[1]]
                    bounds=cursor_bounds(*expected)
                    moved_bounds=cursor_bounds(expected[0]+80*scale,expected[1]+70*scale)
                    assert abs(bounds[0]-expected[0])<24*scale and abs(bounds[1]-expected[1])<24*scale,(bounds,expected)
                    assert abs((moved_bounds[0]-bounds[0])-80*scale)<=2 and abs((moved_bounds[1]-bounds[1])-70*scale)<=2,(bounds,moved_bounds,scale)
                    # A real OR tooltip has client-owned root geometry, no chrome/configure or focus grant.
                    ev('W:focus();OR_RULE=0;K.rule{match={class="WireX11"},on=function()OR_RULE=OR_RULE+1 end}')
                    tooltip=x.create(instance='tooltip-wire',override=True,parent=w,window_type='TOOLTIP',color=0xe0b040,box=(int(ox+55),int(oy+110),140,90));pump();yes('#client.all()==3')
                    ev("for _,c in ipairs(client.all())do if c.instance=='tooltip-wire' then Q=c end end;assert(Q.override_redirect and not Q.wants_focus and Q.parent==W and OR_RULE==0)")
                    yes('core.client.focused()==W.handle');settle(log)
                    assert public('Q')==[55,110,140,90],public('Q')
                    x.configure(tooltip,x=int(ox+75),y=int(oy+130),width=150);pump();yes(f'Q.x=={int(ox+75)} and Q.y=={int(oy+130)} and Q.width==150');settle(log)
                    assert public('Q')==[75,130,150,90] and x.geometry(tooltip)==[int(ox+75),int(oy+130),150,90]
                    shot(f'override-tooltip-{i}',output)
                    assert not re.search(r'X11 published window='+str(tooltip)+r' ',log.read_text()),'configured OR window'
                    x.unmap(tooltip);pump();yes('not Q.mapped and core.client.focused()==W.handle');x.destroy(tooltip);pump()
                    # A focus-wanting OR window restores its parent through the ordinary history policy.
                    menu=x.create(instance='focus-or',override=True,parent=w,box=(int(ox+60),int(oy+115),140,90));pump();yes('core.client.focused()~=W.handle')
                    ev("for _,c in ipairs(client.all())do if c.instance=='focus-or' then M=c end end;assert(M.wants_focus and M.parent==W)")
                    x.unmap(menu);pump();yes('core.client.focused()==W.handle');x.destroy(menu);pump()
                    ev('K.rule.clear()')
                    proof.append(dict(output=target,scale=scale,other_scale=other_scale,x_geometry=x.geometry(w),native_buffer=a['buffer_size'],native_scale120=a['scale120'],local=buttons[-1]['local'],cursor_bounds=bounds,moved_cursor_bounds=moved_bounds))
                (work/'mixed-scale.json').write_text(json.dumps(dict(outer=outer,inner=inner,samples=proof,x=x.records,native=native.records),indent=2)+'\n')
                h.quit(server,env,log)
            finally:x.close();native.close()
            until(lambda:not server_pids(inner),'mixed scale X shutdown')
            print(f'PASS: X11/native scales 1/1.5/2, simultaneous mixed scales and non-origin moves, client-local clicks/cursor hotspots, OR map/move/unmap and parent focus; outer={outer} inner={inner}',flush=True)


def lifecycle(h):
    from x11_client import XClient
    from protocol_client import Client
    from output_fixture import harness,LUA
    from layer_checks import CONFIG
    from paint_checks import stats
    fh=harness(h);fh.count=h.count
    config=CONFIG+LUA
    try:
        with fh.boot(config,overrides={'DISPLAY':None,'WAYLAND_DISPLAY':None,'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
            inner=fh.ev(env,'return os.getenv("DISPLAY")').decode().strip();x=XClient(inner);n=Client(env);observer=Client(env);samples=[]
            foot,f=launch(env,work,'LIFETIME-FOOT')
            def ev(s):check(fh,env,'do '+s+' end',b'\n')
            def yes(s):wait(fh,env,'return '+s,b'true\n',server)
            def pump():x.pump(.08);n.pump(.1);observer.pump(.1)
            def handles():return {o:m for o,(k,m) in observer.objects.items() if k=='foreign' and not m.get('closed')}
            def pick():ev("for _,c in ipairs(client.all())do if c.instance=='lifetime-x11' then X=c elseif c.app_id=='lifetime-native' then N=c else F=c end end;for _,s in ipairs(screen.all())do if s.name=='HEADLESS-1' then S=s else T=s end end")
            try:
                observer.bind('zwlr_foreign_toplevel_manager_v1',3)
                window=x.create(instance='lifetime-x11');a=n.toplevel('lifetime-native');pump();yes('#client.all()==3');pick()
                ev('XH=X.handle;NH=N.handle;FH=F.handle;X:move_to(S);N:move_to(T);F:move_to(T);X:focus()');pump();settle(log)
                xpid=server_pids(inner);assert len(xpid)==1
                steady_ids=set(handles());assert len(steady_ids)==3
                for cycle in range(5):
                    ev('K.reload()');pump();yes('#client.all()==3');pick();assert set(handles())==steady_ids
                    yes('X.handle==XH and N.handle==NH and F.handle==FH')
                    ev('X:move_to(S);N:move_to(T);F:move_to(T);X:focus()');pump();yes('core.client.focused()==X.handle')
                    # A failed declaration retains both the native and X scene/geometry.
                    old=x.geometry(window);snapshot=set(handles());sx,sy=map(int,fh.ev(env,'return S.x,S.y').split())
                    ev("core.set_frame_handler(function()error('X11 rejected frame')end);core.dirty()")
                    time.sleep(.15);assert x.geometry(window)==old and set(handles())==snapshot
                    yes('core.client.focused()==X.handle')
                    # Output position is committed independently of that rejected declaration.
                    ev(f'core.output.set_position(S.name,{sx+100},{sy+70})');time.sleep(.15)
                    until(lambda:x.geometry(window)[:2]==[old[0]+100,old[1]+70],'X geometry after output move with rejected declaration')
                    ev(f'core.output.set_position(S.name,{sx},{sy})');time.sleep(.1)
                    (work/'rc.lua').write_text("error('X11 broken config')\n")
                    ev('K.reload()');pump();assert set(handles())==steady_ids;fh.healthy(env)
                    (work/'rc.lua').write_text(config);ev('K.reload()');pump();yes('#client.all()==3');pick()
                    ev('X:move_to(S);N:move_to(T);F:move_to(T);X:focus()');pump()
                    for screen_name in ['S','T']:
                        ev(f'core.output.set_enabled({screen_name}.name,false)');pump()
                    yes('core.client.focused()==nil');assert set(handles())==steady_ids
                    ev('core.output.set_enabled(S.name,true);core.output.set_enabled(T.name,true)');pump();ev('X:focus()');pump();yes('core.client.focused()==X.handle')
                    ev("assert(output_fixture(1,S.name))");pump();yes('#screen.all()==1 and X.screen==T and N.screen==T and F.screen==T')
                    assert set(handles())==steady_ids
                    ev("assert(output_fixture(2,'HEADLESS-1',1280,720))");pump();pick();ev('X:move_to(S)');pump()
                    ev('for _,s in ipairs(screen.all())do assert(output_fixture(1,s.name))end');pump();yes('#screen.all()==0 and core.client.focused()==nil');fh.healthy(env)
                    assert set(handles())==steady_ids
                    assert all(not m['outputs'] for m in handles().values()),handles()
                    ev("assert(output_fixture(2,'HEADLESS-1',1280,720));assert(output_fixture(2,'HEADLESS-2',1280,720))");pump();yes('#client.all()==3');pick()
                    ev('X:move_to(S);N:move_to(T);F:move_to(T);X:focus()');pump();yes('core.client.focused()==X.handle')
                    assert set(handles())==steady_ids and all(m['outputs'] for m in handles().values())
                    # Real association recycling must keep the same outer scene owner.
                    x.unmap(window);pump();yes('not X.mapped');assert len(handles())==2
                    x.map(window);pump();yes('X.mapped and X.handle==XH and #client.all()==3')
                    steady_ids=set(handles());assert len(steady_ids)==3
                    ev('collectgarbage("collect");core.dirty()');pump();settle(log)
                    ev('core.dirty()');pump();settle(log)
                    assert stats(log,'HEADLESS-1')[:2]==(0,0) and stats(log,'HEADLESS-2')[:2]==(0,0)
                    before=log.read_text().count('Layout ');x.paint(window,color=0xf0b040+cycle);pump();time.sleep(.15)
                    assert log.read_text().count('Layout ')==before,'buffer-only X repaint solved desktop'
                    refs=int(fh.ev(env,"local n=0;for k,v in pairs(debug.getregistry())do if type(k)=='number' and type(v)=='function'then n=n+1 end end;return n"))
                    samples.append(dict(cycle=cycle,fds=len(list(Path(f'/proc/{server.pid}/fd').iterdir())),refs=refs,
                        paint1=stats(log,'HEADLESS-1')[2:],paint2=stats(log,'HEADLESS-2')[2:],xwayland=server_pids(inner)))
                    assert foot.poll() is None and server_pids(inner)==xpid
                assert len({r['fds'] for r in samples[1:]})==1,samples
                assert len({r['refs'] for r in samples})==1,samples
                assert len({tuple(r['paint1']) for r in samples[1:]})==1,samples
                assert len({tuple(r['paint2']) for r in samples[1:]})==1,samples
                identities=re.findall(r'X11 associate window='+str(window)+r' handle=(\d+) tree=(\S+)',log.read_text())
                assert len(identities)==6 and len(set(identities))==1,identities
                capture(env,work/'recovered-mixed-desktop.png')
                (work/'lifecycle.json').write_text(json.dumps(dict(inner=inner,compositor=server.pid,samples=samples,associations=identities,foreign=observer.records),indent=2)+'\n')
                # Kill only the exact process whose command line names this reserved display.
                assert server_pids(inner)==xpid
                os.kill(xpid[0],9);until(lambda:(x.pump(.05) or x.closed),'owned X server death')
                pump();yes('#client.all()==2 and N.handle==NH and F.handle==FH');fh.healthy(env)
                assert foot.poll() is None
                # wlroots owns re-arming the lazy sockets. No compositor restart loop.
                recovered=XClient(inner)
                try:
                    nw=recovered.create(instance='recovered-x11');recovered.pump(.2);pump();yes('#client.all()==3')
                    nextpid=server_pids(inner);assert len(nextpid)==1 and nextpid!=xpid
                    assert log.read_text().count('XWayland ready')==2
                    (work/'restart.json').write_text(json.dumps(dict(display=inner,old=xpid,new=nextpid,old_handle=int(fh.ev(env,'return XH'))),indent=2)+'\n')
                    # Leave clients and pending protocol traffic alive at compositor teardown.
                    recovered.configure(nw,width=330);ev('K.reload()');fh.quit(server,env,log)
                finally:recovered.close()
                assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
                until(lambda:not server_pids(inner),'restarted X server orphan')
                assert not Path('/tmp/.X11-unix/X'+inner[1:]).exists()
            finally:
                x.close();n.close();observer.close()
                if foot.poll() is None:foot.terminate()
                foot.wait(timeout=5);f.close()
            print('PASS: five mixed remap/reload/repair/disable/removal/last-output-return cycles, stable FDs/refs/paint owners, idle/buffer repaint, owned X server failure/restart and live-client teardown',flush=True)
    finally:h.count=fh.count


def run(h):
    startup(h)
    model(h)
    geometry(h)
    input_and_kill(h)
    mixed_scale(h)
    lifecycle(h)


if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-xwayland-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
