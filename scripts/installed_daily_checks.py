"""Installed production desktop with real private-backend input and services."""
import json
import hashlib
from pathlib import Path
import subprocess
import time
from dbus_checks import private_bus, peer, notify, monitor
from policy_checks import private_x11
from declaration_checks import wait, settle, capture
from window_state_checks import launch, stop
from x11_client import XClient


def run(h, client_binary, runtime, cwd, config_source=None, theme_source=None):
    overrides={}
    if theme_source is not None:
        config_home=h.out/'intended-theme';(config_home/'kiln').mkdir(parents=True)
        (config_home/'kiln/theme').write_bytes(theme_source.read_bytes())
        overrides['XDG_CONFIG_HOME']=str(config_home)
    with private_bus(h.out/'daily-bus') as (address,bus), private_x11(h.out) as display:
        with h.boot(None,cwd=cwd,overrides={**overrides,'DBUS_SESSION_BUS_ADDRESS':address,'DISPLAY':display,'WAYLAND_DISPLAY':None,'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2'}) as (server,env,work,log):
            def ev(s):
                r=h.ev(env,s);assert not r.startswith(b'ERROR:'),(s,r);return r
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            def cli(*args):
                p=subprocess.run([str(client_binary),'-s',env['KILN_SOCK'],*args],env=env,cwd=cwd,capture_output=True,timeout=5)
                assert p.returncode==0 and not p.stderr,p
                return p.stdout
            def xdo(*args):
                subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5)
                time.sleep(.06)
            foot,f=launch(env,work,'INSTALLED-FOOT');x=None
            try:
                yes('#screen.all()==2 and #client.all()==1')
                x=XClient(ev('return os.getenv("DISPLAY")').decode().strip());x.create(instance='installed-x')
                yes('#client.all()==2')
                ev('K=require("kiln");S,T=unpack(screen.all());for _,c in ipairs(client.all())do c:move_to(S) end;screen.focused=S;core.output.set_position(S.name,-301,77);core.output.set_position(T.name,1000,91);T.scale=1.3')
                windows=subprocess.check_output(['xdotool','search','--name',''],env=env,text=True).splitlines()
                win=windows[-2];xdo('windowraise',win);xdo('windowfocus',win)
                xdo('key','super+2');yes('S.selected_tag==S.tags[2]')
                xdo('key','super+1');yes('S.selected_tag==S.tags[1]')
                layout=cli('layout','get');xdo('key','super+space');assert cli('layout','get')!=layout
                xdo('key','super+x');yes('K.prompt.active~=nil');xdo('type','--clearmodifiers','6*7');xdo('key','Return')
                yes('#notification.all()==1 and notification.all()[1].message=="42"');ev('notification.all()[1]:dismiss()')
                # The private application entry launches only a child of this instance.
                apps=Path(env['XDG_DATA_HOME'])/'applications';apps.mkdir(parents=True,exist_ok=True)
                (apps/'audit.desktop').write_text('[Desktop Entry]\nType=Application\nName=Audit Terminal\nExec=foot --app-id=installed-launcher\n')
                xdo('key','super+p');yes('K.prompt.active~=nil');xdo('type','--clearmodifiers','Audit Terminal');xdo('key','Return')
                yes('#client.all()==3')
                ev('for _,c in ipairs(client.all())do if c.app_id=="installed-launcher" then c:close()end end');yes('#client.all()==2')
                with peer(env,work,'org.ktest.InstalledDaily') as (_,marker),monitor(env,work,'org.freedesktop.Notifications') as signals:
                    yes('#K.systray.items()==1')
                    nid=notify(env,title='Installed daily test',actions='["open","Open"]')
                    yes('#notification.all()==1');seq=int(ev('return notification.all()[1].seq'))
                    def at(name,index=0):
                        q=ev('core.hits(S.name,S.x,S.y);local b=assert(core.box({'+json.dumps(name)+','+str(index)+'}));return (b.x+b.width/2)*S.scale,(b.y+b.height/2)*S.scale').split()
                        xdo('mousemove','--window',win,round(float(q[0])),round(float(q[1])))
                    settle(log);capture(env,work/'installed-daily.png')
                    at('notification:'+str(seq)+':action',1);xdo('click',1);yes('#notification.all()==0')
                    at('tray:org.ktest.InstalledDaily');xdo('click',1);xdo('click',5)
                    assert 'Activate 0 0' in marker.read_text() and 'Scroll 15 vertical' in marker.read_text()
                    assert f'ActionInvoked (uint32 {nid},' in signals.read_text()
                    xdo('key','super+shift+i');yes('core.inspector(S.name)')
                    path=work/'installed-daily-inspector.png';assert cli('screenshot',str(path),ev('return S.name').decode().strip())==str(path).encode()+b'\n'
                    xdo('key','super+shift+i');yes('not core.inspector(S.name)')
                    rc=runtime/'rc.lua';saved=rc.read_text()
                    try:
                        rc.write_text('error("installed daily repair")');cli('reload');yes('#screen.all()[1].tags==0')
                        rc.write_text(saved);cli('reload');yes('#client.all()==2 and #screen.all()[1].tags==5')
                    finally:rc.write_text(saved)
                    ev('for _,n in ipairs(notification.all())do n:dismiss() end');settle(log)
                    capture(env,work/'installed-daily-repaired.png')
                    source=ev('return debug.getinfo(require("kiln").reload).source').decode().strip()
                    assert source.startswith('@'+str(runtime)+'/lua/'),source
                    (work/'daily.json').write_text(json.dumps(dict(binary=str(h.binary),client=str(client_binary),config=str(rc),config_source=str(config_source) if config_source else None,config_sha256=hashlib.sha256(rc.read_bytes()).hexdigest(),theme_source=str(theme_source) if theme_source else None,theme_accent=ev('return K.theme.accent').decode().strip(),module=source,foot_pid=foot.pid,input='outer private Xvfb keyboard/button/wheel',personal_config=config_source is not None,normal_binary=True),indent=2)+'\n')
                h.quit(server,env,log)
            finally:
                if x:x.close()
                stop(foot);f.close()
    print('PASS: installed normal stock runtime, foot/X11, native tags/layout/prompt/launcher/notification/tray/inspector, screenshot, fractional non-origin outputs and repaired config')
