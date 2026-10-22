"""Window policy, native state requests and protocol evidence on owned displays."""
from pathlib import Path
import subprocess
import time

from PIL import Image
from declaration_checks import check, wait, capture, settle
from layout_checks import DEFAULT
from policy_checks import private_x11
from wayland_probe import probe


def stop(p):
    if p.poll() is None:
        p.terminate()
        try:p.wait(timeout=5)
        except subprocess.TimeoutExpired:p.kill();p.wait(timeout=5)


def launch(env,work,label,flags=()):
    log=(work/(label+'.log')).open('w')
    p=subprocess.Popen(['foot','--app-id='+label,'--title='+label,'-o','colors-dark.background='+('204060' if label=='A' else '604020'),
                        *flags,'sh','-c','printf "\\n  '+label+'\\n"; exec sleep 1000'],
                       env=dict(env,WAYLAND_DEBUG='client'),stdout=log,stderr=log)
    return p,log


def counts(log):
    out={}
    for line in log.read_text().splitlines():
        if line.startswith('Layout '):
            name=line.split()[1][:-1];out[name]=out.get(name,0)+1
    return out


def headless(h):
    with h.boot(DEFAULT,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        processes=[];files=[]
        def ev(src):check(h,env,'do '+src+' end',b'\n')
        def eventually(src):wait(h,env,src,b'true\n',server)
        def shot(name):
            capture(env,work/(name+'.png'));return Image.open(work/(name+'.png')).convert('RGB')
        try:
            ev("K=require('kiln');L=K.layout;s1,s2=unpack(screen.all());screen.focused=s1")
            for label in ('A','B','C'):
                p,f=launch(env,work,label);processes.append(p);files.append(f)
                wait(h,env,'return #client.all()',f'{len(processes)}\n'.encode(),server)
            ev("a,b,c=unpack(client.all());t=s1.selected_tag;assert(s1.x~=s2.x);a:focus()")
            eventually("return core.client.focused()==a.handle")
            ev("assert(t.clients[1]==a);assert(s1.workarea.x==0 and s1.workarea.y==36 and s1.workarea.width==s1.width and s1.workarea.height==s1.height-36)")
            ev("a.tags={t,s1.tags[2]};s1.tags[2].layout=L.max;s1.selected_tags={s1.tags[2],t}")
            settle(log)
            eventually("return a.width==s1.width-20 and #K.visible_clients(s1)==3")
            ev("s1.selected_tags={t,s1.tags[2]}")
            settle(log)
            eventually("return a.width==624 and b.width==624")
            ev("s1.selected_tags={t};a.tag=t")
            settle(log)
            shot('tiled')
            ev("initial={a.width,a.height};a.float={x=90,y=100,width=510};a.floating=true")
            eventually("return a.float.height==initial[2]+26 and a.width==506")
            ev("F=a.float;assert(F.x==90 and F.y==100 and F.width==510);b:focus();a:focus();assert(t.clients[#t.clients]==a)")
            for i in range(4):
                ev("a.floating=false;a.titlebar=false;K.theme.border_width=5;core.dirty(s1.name)");time.sleep(.08)
                ev("a.floating=true");time.sleep(.08)
                eventually("return a.width==F.width-10 and a.height==F.height-10")
                ev("a.titlebar=true;K.theme.border_width=2;core.dirty(s1.name)")
                eventually("return a.width==F.width-4 and a.height==F.height-26 and a.float==F")
            ev("b.floating=true;b.float={x=170,y=150,width=510,height=400};b:focus()")
            eventually("return b.width==506 and b.height==374")
            floated=shot('floated')
            # Both outputs are in one capture; sample a client-owned interior overlap.
            ox=int(h.ev(env,'return s1.x').decode());oy=int(h.ev(env,'return s1.y').decode())
            assert floated.getpixel((ox+300,oy+300))==(96,64,32)
            ev("a:focus()");time.sleep(.1)
            raised=shot('raised');assert raised.getpixel((ox+300,oy+300))==(32,64,96)
            ev("b.ontop=true");time.sleep(.1)
            assert shot('ontop').getpixel((ox+300,oy+300))==(96,64,32)
            ev("a.band='overlay'");time.sleep(.1)
            assert shot('band-override').getpixel((ox+300,oy+300))==(32,64,96)
            ev("a.band=nil;b.ontop=false;a.fullscreen=true;a.maximized=true;a:focus()")
            eventually("return a.width==s1.width and a.height==s1.height")
            ev("core.hits(s1.name,s1.x,s1.y);local q=core.box({'core.surface',a.handle});assert(q.x==0 and q.y==0 and q.width==s1.width and q.height==s1.height)")
            full=shot('fullscreen');assert full.getpixel((ox+900,oy+20))==(32,64,96)
            ev("a.band='below'");time.sleep(.1)
            overridden=shot('fullscreen-band-override')
            assert overridden.getpixel((ox+900,oy+20))==(55,131,151)
            assert overridden.getpixel((ox+300,oy+300))==(96,64,32)
            ev("a.band=nil")
            ev("b:focus()");time.sleep(.1)
            unfocused=shot('fullscreen-unfocused')
            assert unfocused.getpixel((ox+900,oy+20))==(55,131,151)
            # Source declares fullscreen after normal floats; unfocused stays normal-band above them.
            assert unfocused.getpixel((ox+300,oy+300))==(32,64,96)
            ev("b.ontop=true");time.sleep(.1)
            assert shot('fullscreen-ontop').getpixel((ox+300,oy+300))==(96,64,32)
            ev("a.fullscreen=false;a:focus()")
            eventually("return a.width==s1.workarea.width-4 and a.height==s1.workarea.height-26")
            ev("core.hits(s1.name,s1.x,s1.y);local q=core.box({'client',a.handle});local w=s1.workarea;assert(q.x==w.x and q.y==w.y and q.width==w.width and q.height==w.height and a.maximized and a.float==F)")
            shot('maximized')
            ev("K.defaults.successor=function(gone) assert(gone==a);return c end;a.minimized=true")
            eventually("return client.focus==c and core.client.focused()==c.handle")
            ev("for _,hit in ipairs(core.hits(s1.name,s1.x+300,s1.y+300)) do assert(hit.name~='core.surface' or hit.index~=a.handle) end;assert(a.float==F and a.mapped);a:focus();assert(client.focus==c)")
            ev("core.client.focus(a.handle)")
            eventually("return client.focus==c and core.client.focused()==c.handle")
            shot('minimized')
            ev("a.minimized=false;a.maximized=false;a:focus()")
            eventually("return a.width==F.width-4 and a.height==F.height-26")
            shot('restored')
            ev("a.sticky=true;s1.tags[2]:view()")
            settle(log)
            eventually("return #K.visible_clients(s1)==1 and K.visible_clients(s1)[1]==a")
            ev("a.tags={s1.tags[1],s1.tags[2],s2.tags[1]};assert(#K.visible_clients(s1)==1 and #K.visible_clients(s2)==0);a:move_to(s2)")
            eventually("return client.focus==a and core.client.focused()==a.handle and #K.visible_clients(s1)==0 and #K.visible_clients(s2)==1")
            ev("core.hits(s2.name,s2.x+300,s2.y+300);local q=core.box({'client',a.handle});assert(q.x==F.x and q.y==F.y);assert(s2.workarea.x==0 and s2.workarea.y==36)")
            shot('moved')
            ev("a.fullscreen=true;a.maximized=true")
            eventually("return a.width==s2.width and a.height==s2.height")
            ev("core.hits(s2.name,s2.x+900,s2.y+10);local q=core.box({'core.surface',a.handle});assert(q.x==0 and q.y==0 and q.width==s2.width and q.height==s2.height)")
            shot('nonorigin-fullscreen')
            ev("a.fullscreen=false")
            eventually("return a.width==s2.workarea.width-4 and a.height==s2.workarea.height-26")
            shot('nonorigin-maximized')
            ev("a.maximized=false")
            eventually("return a.width==F.width-4 and a.height==F.height-26")
            # Dirtying the old owner cannot disable the borrowed tree on the new owner.
            ev("core.dirty(s1.name)");time.sleep(.1)
            ev("assert(core.client.focused()==a.handle);local seen=false;for _,hit in ipairs(core.hits(s2.name,s2.x+300,s2.y+300)) do if hit.name=='core.surface' and hit.index==a.handle then seen=true end end;assert(seen)")
            time.sleep(.2);before=counts(log)
            ev("a.urgent=true");time.sleep(.15);after=counts(log)
            names=h.ev(env,'return s1.name,s2.name').decode().strip().split('\t')
            assert before[names[0]]==after[names[0]] and after[names[1]]>before[names[1]],(before,after)
            before=counts(log);time.sleep(.3);assert counts(log)==before
            ev("core.dirty(s2.name)");time.sleep(.1)
            last=[l for l in log.read_text().splitlines() if l.startswith('Paint '+names[1]+':')][-1]
            assert 'mutations 0, rasters 0' in last,last
            # Focus an eligible but omitted max-layout client without reordering tiled cells.
            ev("a.sticky=false;a.floating=false;s1.tags[1]:view();a:move_to(s1);b.floating=false;b.ontop=false;t.layout=L.max;c:focus()")
            settle(log)
            eventually("return core.client.focused()==c.handle")
            ev("order=table.concat((function() local o={};for _,x in ipairs(t.clients) do o[#o+1]=x.handle end;return o end)(),',');a:focus()")
            eventually("return core.client.focused()==a.handle and a.width==s1.width-20")
            ev("assert(order==table.concat((function() local o={};for _,x in ipairs(t.clients) do o[#o+1]=x.handle end;return o end)(),','))")
            # Synthetic minimize request: there is no installed xdg requester for it.
            ev("K.defaults.successor=function() return b end;a:emit('request::minimize',true)")
            eventually("return a.minimized and client.focus==b")
            ev("a.minimized=false;a.fullscreen=true;a.maximized=true;a.minimized=true;a.fullscreen=false;a.minimized=false;a.maximized=false;a:focus()")
            eventually("return client.focus==a and core.client.focused()==a.handle")
            # Minimize before first-map focus, including a map callback's queued request.
            ev("K.rule{match={app='PENDING'},props={minimized=true}};client.on('map',function(x) if x.app_id=='QUEUED' then x:emit('request::minimize',true) end end)")
            for label in ('PENDING','QUEUED'):
                p,f=launch(env,work,label);processes.append(p);files.append(f)
                wait(h,env,'return #client.all()',f'{len(processes)}\n'.encode(),server)
                ev("assert(client.focus==a and core.client.focused()==a.handle)")
            ev("K.rule.clear();a:emit('request::fullscreen',true);a:close();a:emit('request::maximize',true)")
            wait(h,env,'return #client.all()',b'4\n',server)
            ev("for _,verb in ipairs({'set_fullscreen_hint','set_maximized_hint','set_suspended','set_minimized_hint'}) do core.client[verb](a.handle,true);core.client[verb](a.handle,false);assert(not pcall(core.client[verb],a.handle,{}));assert(not pcall(core.client[verb],-1,true)) end;a:toggle_minimized()")
            h.quit(server,env,log)
            assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
        finally:
            for p in processes:stop(p)
            for f in files:f.close()
    print('PASS: real float persistence/chrome/round trips, fullscreen/maximize/minimize, sticky/ownership, pixels/bands/focus, max choice, pending focus, stale verbs, idle/cleanup')
    print('State captures:',work.resolve())


def startup_requests(h):
    for mode in ('accept','refuse','alter'):
        refuse = mode=='refuse'
        config=DEFAULT+('''
local k=require('kiln')
client.off('request::fullscreen',k.defaults.fullscreen)
client.off('request::maximize',k.defaults.maximize)
''' if refuse else '')
        if mode=='alter':config+="\nlocal k=require('kiln');client.off('request::fullscreen',k.defaults.fullscreen);client.on('request::fullscreen',function(c,on) c.maximized=on end)\n"
        with h.boot(config) as (server,env,work,log):
            ps=[];fs=[]
            try:
                for label,flag,prop in [('FULL','--fullscreen','fullscreen'),('MAX','--maximized','maximized')]:
                    with probe(env,work,label) as (client_env,wire):
                        p,f=launch(client_env,work,label,(flag,));ps.append(p);fs.append(f)
                        wait(h,env,'return #client.all()',b'1\n',server)
                        source=f"for _,c in ipairs(client.all()) do if c.app_id=='{label}' then return not not c.{prop} end end"
                        wait(h,env,source,b'false\n' if refuse or (mode=='alter' and prop=='fullscreen') else b'true\n',server)
                        time.sleep(.15)
                        request='fullscreen' if prop=='fullscreen' else 'maximize'
                        state=2 if prop=='fullscreen' else 1
                        assert any(r.get('request')==request for r in wire),wire
                        assert any('ack' in r for r in wire),wire
                        configs=[r for r in wire if 'states' in r]
                        assert configs and any(state in r['states'] for r in configs)==(not refuse and not (mode=='alter' and prop=='fullscreen')),wire
                        if mode=='alter':assert any(1 in r['states'] for r in configs),wire
                        check(h,env,"c=client.all()[1];c.minimized=true",b'\n');time.sleep(.15)
                        assert any(9 in r['states'] for r in wire if 'states' in r),wire
                        check(h,env,"c.minimized=false",b'\n');time.sleep(.15)
                        assert 9 not in [r for r in wire if 'states' in r][-1]['states'],wire
                        stop(p);wait(h,env,'return #client.all()',b'0\n',server)
                h.quit(server,env,log)
            finally:
                for p in ps:stop(p)
                for f in fs:f.close()
    print('PASS: native foot startup fullscreen/maximize, accepted/refused/altered policy, decoded configure/ack/suspended evidence and no transient refused state')


def native(h):
    with private_x11(h.out) as display:
        with h.boot(DEFAULT,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            ps=[];fs=[]
            try:
                f=(work/'wev.log').open('w');fs.append(f)
                p=subprocess.Popen(['stdbuf','-oL','wev'],env=dict(env,WAYLAND_DEBUG='client'),stdout=f,stderr=f);ps.append(p)
                wait(h,env,'return #client.all()',b'1\n',server)
                check(h,env,"w=client.all()[1];s=screen.all()[1];K=require('kiln')",b'\n')
                window=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines()[-1]
                def key(chord):
                    subprocess.run(['xdotool','windowfocus',window],env=env,check=True)
                    subprocess.run(['xdotool','key',chord],env=env,check=True);time.sleep(.2)
                def state(prop,on=True):wait(h,env,'return not not w.'+prop,b'true\n' if on else b'false\n',server)
                def text():return (work/'wev.log').read_text()
                key('super+f');state('fullscreen');assert 'fullscreen' in text(),text()
                start=len(text());key('super+f');state('fullscreen',False)
                assert 'xdg_toplevel] configure:' in text()[start:] and 'fullscreen' not in text()[start:]
                key('super+m');state('maximized');assert 'maximized' in text()
                key('super+n');state('minimized')
                wait(h,env,'return core.client.focused()',b'nil\n',server)
                key('super+shift+n');state('minimized',False)
                key('super+m');state('maximized',False)
                key('super+shift+space');state('floating')
                key('super+shift+space');state('floating',False)
                key('super+space');check(h,env,"return K.layout.name(s.selected_tag.layout)",b'fair\n')
                # Native pointer target follows band order at a stationary overlap.
                p,f=launch(env,work,'INPUT');ps.append(p);fs.append(f)
                wait(h,env,'return #client.all()',b'2\n',server)
                check(h,env,"for _,c in ipairs(client.all()) do if c~=w then other=c end end;w.floating=true;w.float={x=90,y=100,width=500,height=400};other.floating=true;other.float={x=170,y=150,width=500,height=400};w.ontop=true;other:focus()",b'\n')
                time.sleep(.2)
                subprocess.run(['xdotool','mousemove','--window',window,'300','300','click','1'],env=env,check=True)
                wait(h,env,'return client.focus==w and core.client.focused()==w.handle',b'true\n',server)
                check(h,env,"other.band='overlay'",b'\n');time.sleep(.15)
                subprocess.run(['xdotool','click','1'],env=env,check=True)
                wait(h,env,'return client.focus==other and core.client.focused()==other.handle',b'true\n',server)
                subprocess.run(['xdotool','mousemove','--window',window,'200','110','click','1'],env=env,check=True)
                wait(h,env,'return client.focus==w and core.client.focused()==w.handle',b'true\n',server)
                stop(ps.pop());check(h,env,'w:close()',b'\n');wait(h,env,'return #client.all()',b'0\n',server)
                # A separate native Firefox profile supplies real enter/exit requests.
                profile=work/'firefox-profile';profile.mkdir()
                (profile/'user.js').write_text('user_pref("browser.shell.checkDefaultBrowser", false);\nuser_pref("browser.startup.homepage_override.mstone", "ignore");\nuser_pref("browser.aboutwelcome.enabled", false);\nuser_pref("datareporting.policy.firstRunURL", "");\nuser_pref("toolkit.cosmeticAnimations.enabled", false);\n')
                f=(work/'firefox.log').open('w');fs.append(f)
                p=subprocess.Popen(['firefox','--profile',str(profile),'--new-instance','--no-remote','about:blank'],
                    env=dict(env,MOZ_ENABLE_WAYLAND='1',GDK_BACKEND='wayland',WAYLAND_DEBUG='client'),stdout=f,stderr=f);ps.append(p)
                deadline=time.monotonic()+35
                while h.ev(env,'return #client.all()')!=b'1\n':
                    assert time.monotonic()<deadline and p.poll() is None,(work/'firefox.log').read_text()[-4000:]
                    time.sleep(.2)
                check(h,env,"ff=client.all()[1];ff:focus();ff.maximized=false",b'\n');time.sleep(.5)
                key('F11');wait(h,env,'return not not ff.fullscreen',b'true\n',server)
                wait(h,env,'return ff.width==s.width and ff.height==s.height',b'true\n',server)
                subprocess.run(['xdotool','mousemove','--window',window,'600','400'],env=env,check=True)
                time.sleep(1)
                capture(env,work/'firefox-fullscreen.png')
                key('F11');wait(h,env,'return not not ff.fullscreen',b'false\n',server)
                time.sleep(1)
                capture(env,work/'firefox-restored.png')
                evidence=(work/'firefox.log').read_text()
                assert '.set_fullscreen(' in evidence and '.unset_fullscreen(' in evidence and '.ack_configure(' in evidence
                check(h,env,"client.off('request::fullscreen',K.defaults.fullscreen)",b'\n')
                start=len(evidence);key('F11');time.sleep(.5)
                check(h,env,'return not not ff.fullscreen',b'false\n')
                refusal=(work/'firefox.log').read_text()[start:]
                assert '.set_fullscreen(' in refusal and '.ack_configure(' in refusal,refusal
                h.quit(server,env,log)
            finally:
                for p in ps:stop(p)
                for f in fs:f.close()
    print('PASS: private Xvfb bindings, decoded wev fullscreen/maximize hints, native overlapping input, Firefox F11 enter/exit/refused requests')
    print('Native state evidence:',work.resolve())


def workarea_settle(h):
    config="H=36;COUNTS={};AREAS={};FIRST={}\n"+DEFAULT.replace('h=36','h=H')+"""
local k=require('kiln')
screen.on('added',function(s)
 -- Measure workarea settling independently of the initial tag reveal.
 k.animation.remove(s.name)
 s.selected_tag.layout=function(cs,area,t)
  COUNTS[s.name]=(COUNTS[s.name] or 0)+1
  FIRST[s.name]=FIRST[s.name] or area
  AREAS[s.name]=area
  k.layout.tile(cs,area,t)
 end
end)
"""
    with h.boot(config,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        wait(h,env,'local s=screen.all()[1];return COUNTS[s.name]',b'2\n',server)
        check(h,env,"s1,s2=unpack(screen.all());assert(FIRST[s1.name].height==s1.height-16 and AREAS[s1.name].height==s1.height-52);screen.focused=s1",b'\n')
        p,f=launch(env,work,'SETTLE',('--maximized',))
        try:
            wait(h,env,'return #client.all()',b'1\n',server)
            wait(h,env,'return client.all()[1].height==s1.height-62',b'true\n',server)
            before=counts(log)
            check(h,env,'H=90;core.dirty(s1.name)',b'\n')
            wait(h,env,'return s1.workarea.y==90 and client.all()[1].height==s1.height-116',b'true\n',server)
            time.sleep(.2);after=counts(log)
            names=h.ev(env,'return s1.name,s2.name').decode().strip().split('\t')
            assert after[names[0]]-before[names[0]]==2 and after[names[1]]==before[names[1]],(before,after)
            assert h.ev(env,'return s2.workarea.y')==b'36\n'
            time.sleep(.2);assert counts(log)==after
            h.quit(server,env,log)
        finally:stop(p);f.close()
    print('PASS: first-frame fallback, workarea publication, bar resize settles in two solves, independent output and commit idle')


def run(h):
    workarea_settle(h)
    headless(h)
    startup_requests(h)
    native(h)
