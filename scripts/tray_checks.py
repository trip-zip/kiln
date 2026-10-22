"""Real SNI peers, owner replacement, overlapping reads, errors and cancellation."""
from PIL import Image
from pathlib import Path
import json
import subprocess
import time
from dbus_checks import private_bus,monitor,peer,control,call,live,CONFIG
from declaration_checks import check,wait,settle,capture
from window_state_checks import stop


def run(h):
    with private_bus(h.out/'tray-bus') as (address,bus):
        with h.boot(CONFIG,overrides={'DBUS_SESSION_BUS_ADDRESS':address}) as (server,env,work,log):
            icon=Path(env['XDG_DATA_HOME'])/'icons/hicolor/32x32/apps/network-wireless.png'
            icon.parent.mkdir(parents=True,exist_ok=True)
            Image.new('RGBA',(32,32),(40,210,90,255)).save(icon)
            def ev(s):return h.ev(env,s)
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            def prop(name):return call(env,'org.kde.StatusNotifierWatcher','/StatusNotifierWatcher','org.freedesktop.DBus.Properties.Get','org.kde.StatusNotifierWatcher',name)
            with monitor(env,work,'org.kde.StatusNotifierWatcher') as signals:
                assert prop('IsStatusNotifierHostRegistered')=='(<true>,)'
                assert prop('ProtocolVersion')=='(<0>,)'
                assert prop('RegisteredStatusNotifierItems')=='(<@as []>,)'
                xml=subprocess.check_output(['gdbus','introspect','--session','--dest','org.kde.StatusNotifierWatcher','--object-path','/StatusNotifierWatcher','--xml'],env=env,text=True,timeout=5)
                (work/'watcher.xml').write_text(xml)
                assert all(x in xml for x in ('RegisterStatusNotifierItem','RegisteredStatusNotifierItems','StatusNotifierHostRegistered'))
                call(env,'org.kde.StatusNotifierWatcher','/StatusNotifierWatcher','org.kde.StatusNotifierWatcher.RegisterStatusNotifierHost','fixture')
                with peer(env,work,'org.ktest.Pixmap') as (p,marker):
                    yes('#K.systray.items()==1')
                    check(h,env,'local n=K.systray.items()[1];return n.id,n.status,n.icon',b'test-item\tActive\ttray:org.ktest.Pixmap\n')
                    settle(log);assert live(h,env,'tray:org.ktest.Pixmap');capture(env,work/'tray-initial.png')
                    with peer(env,work,'org.ktest.Named','name'):
                        yes('#K.systray.items()==2')
                        check(h,env,'return K.systray.items()[2].service,K.systray.items()[2].icon',b'org.ktest.Named\tnetwork-wireless\n')
                        settle(log);assert live(h,env,'tray:org.ktest.Named');capture(env,work/'tray-named-icon.png')
                        x,y=map(float,ev('local b=core.box("tray:org.ktest.Named");return b.x+b.width/2,b.y+b.height/2').split())
                        assert Image.open(work/'tray-named-icon.png').convert('RGB').getpixel((int(x),int(y)))==(40,210,90)
                        items=prop('RegisteredStatusNotifierItems');assert items.index('Named')<items.index('Pixmap'),items
                        control(env,'org.ktest.Pixmap','Register','org.ktest.Pixmap');yes('#K.systray.items()==2')
                        control(env,'org.ktest.Pixmap','SetIcon','blue');time.sleep(.1);settle(log);capture(env,work/'tray-replaced.png')
                        x,y=map(float,ev('local b=core.box("tray:org.ktest.Pixmap");return b.x+b.width/2,b.y+b.height/2').split())
                        assert Image.open(work/'tray-replaced.png').convert('RGB').getpixel((int(x),int(y)))==(30,80,230)
                        control(env,'org.ktest.Pixmap','SetStatus','Passive');yes('K.systray.items()[1].status=="Passive"')
                        settle(log);assert live(h,env,'tray:org.ktest.Pixmap');capture(env,work/'tray-passive-source-behavior.png')
                        control(env,'org.ktest.Pixmap','SetStatus','');yes('K.systray.items()[1].status==""')
                        control(env,'org.ktest.Pixmap','SetStatus','NeedsAttention');yes('K.systray.items()[1].status=="NeedsAttention"')
                        ev('local s=screen.all()[1];local p=require("kiln.state").screen_presses[s.name];assert(p["on_press:tray:org.ktest.Pixmap#0"])();assert(p["on_scroll:tray:org.ktest.Pixmap#0"])({dx=0,dy=15,mods={}});core.tray_activate("org.ktest.Pixmap","secondary",29)')
                        time.sleep(.1);text=marker.read_text();assert 'Activate 0 0' in text and 'Scroll 15 vertical' in text and 'SecondaryActivate 29 0' in text,text
                        control(env,'org.ktest.Pixmap','SetDelay',75)
                        control(env,'org.ktest.Pixmap','SetTitle','old snapshot')
                        time.sleep(.1)
                        control(env,'org.ktest.Pixmap','SetTitle','new snapshot')
                        control(env,'org.ktest.Pixmap','SetIcon','name')
                        yes('K.systray.items()[1].title=="new snapshot" and K.systray.items()[1].icon=="network-wireless"')
                        control(env,'org.ktest.Pixmap','SetDelay',0)
                        control(env,'org.ktest.Pixmap','SetIcon','malformed')
                        yes('K.systray.items()[1].icon=="network-wireless"')
                    yes('#K.systray.items()==1')
                yes('#K.systray.items()==0');settle(log);assert not live(h,env,'tray:org.ktest.Pixmap');capture(env,work/'tray-removed.png')
                assert 'StatusNotifierItemUnregistered (\'org.ktest.Pixmap\',)' in signals.read_text()
                with peer(env,work,'org.ktest.Path','pixmap','--path','/CustomItem') as (p,marker):
                    yes('#K.systray.items()==1')
                    unique=marker.read_text().splitlines()[0].split()[1]
                    check(h,env,'return K.systray.items()[1].service',(unique+'\n').encode())
                    ev('core.tray_activate('+json.dumps(unique)+',"activate",3)');time.sleep(.08);assert 'Activate 3 0' in marker.read_text()
                yes('#K.systray.items()==0')
                with peer(env,work,'org.ktest.SlowFirst','pixmap','--delay','100'):
                    time.sleep(.05)
                    with peer(env,work,'org.ktest.FastSecond','name'):
                        yes('#K.systray.items()==2')
                        check(h,env,'return K.systray.items()[1].service,K.systray.items()[2].service',b'org.ktest.SlowFirst\torg.ktest.FastSecond\n')
                yes('#K.systray.items()==0')
                with peer(env,work,'org.ktest.Missing','missing'):
                    yes('#K.systray.items()==1')
                    check(h,env,'local n=K.systray.items()[1];return n.id,n.title,n.status,n.icon',b'test-item\tnil\tnil\tnil\n')
                    settle(log);assert live(h,env,'tray:org.ktest.Missing')
                yes('#K.systray.items()==0')
                # Slow replies exceed the bounded timeout; IPC and rendering still run.
                with peer(env,work,'org.ktest.Slow','pixmap','--delay','1100') as (p,marker):
                    with (work/'responsive-foot.log').open('w') as output:
                        foot=subprocess.Popen(['foot','--title=STALLED-PEER-FOOT','sh','-c','printf "first frame\\n"; while test ! -f "$1"; do sleep .01; done; printf "second frame\\n"; exec sleep 1000','--',str(work/'repaint')],env=env,stdout=output,stderr=output)
                        try:
                            yes('#client.all()==1')
                            start=time.monotonic();assert ev('return 6*7')==b'42\n'
                            capture(env,work/'stalled-peer-before.png');(work/'repaint').touch();time.sleep(.15);capture(env,work/'stalled-peer-after.png')
                            assert time.monotonic()-start<1
                            assert (work/'stalled-peer-before.png').read_bytes()!=(work/'stalled-peer-after.png').read_bytes()
                        finally:stop(foot)
                    yes('#K.systray.items()==1');check(h,env,'return K.systray.items()[1].icon',b'nil\n')
                    # Refresh stays in flight when the owner dies.
                    control(env,'org.ktest.Slow','SetTitle','late');time.sleep(.04)
                yes('#K.systray.items()==0');time.sleep(.8);yes('#K.systray.items()==0')
                with peer(env,work,'org.ktest.Replace','pixmap') as (old,oldmarker):
                    # Keep the old process alive while its name is replaced.
                    yes('#K.systray.items()==1');settle(log)
                    ev('STALE_PRESS=require("kiln.state").screen_presses[screen.all()[1].name]["on_press:tray:org.ktest.Replace#0"]')
                    control(env,'org.ktest.Replace','SetDelay',250);control(env,'org.ktest.Replace','SetTitle','departed owner')
                    time.sleep(.1)
                    newdir=work/'replacement';newdir.mkdir()
                    with peer(env,newdir,'org.ktest.Replace','name','--replace') as (new,newmarker):
                        yes('#K.systray.items()==1 and K.systray.items()[1].icon=="network-wireless"')
                        control(env,'org.ktest.Replace','SetTitle','replacement owner')
                        yes('K.systray.items()[1].title=="replacement owner"')
                        ev('assert(STALE_PRESS)();core.tray_activate("org.ktest.Replace","activate",71)');time.sleep(.35)
                        assert 'Activate 71 0' in newmarker.read_text() and 'Activate 0 0' not in newmarker.read_text() and 'Activate' not in oldmarker.read_text()
                        old_unique=oldmarker.read_text().splitlines()[0].split()[1]
                        control(env,old_unique,'SetTitle','stale owner signal');time.sleep(.1)
                        yes('#K.systray.items()==1 and K.systray.items()[1].title=="replacement owner"')
                    yes('#K.systray.items()==0')
                with peer(env,work,'org.ktest.Return','name'):yes('#K.systray.items()==1')
                yes('#K.systray.items()==0')
                with peer(env,work,'org.ktest.Return','pixmap'):yes('#K.systray.items()==1 and K.systray.items()[1].icon=="tray:org.ktest.Return"')
                yes('#K.systray.items()==0')
                (work/'coverage.txt').write_text('Wire registrations/properties/signals; synthetic press/scroll and SecondaryActivate method receipts; overlapping snapshots, missing/invalid pixmaps, unique path identity, slow-peer timeouts, owner replacement and late reply cancellation.\n')
            assert 'Lua event:' not in log.read_text() and "kiln: error in '" not in log.read_text()
    print('ok   SNI wire battery, owner replacement, slow peers and canceled replies')
