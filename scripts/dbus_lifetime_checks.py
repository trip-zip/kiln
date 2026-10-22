"""Settled service resources, reload/repair cycles, conflicts and bus loss."""
import json
from pathlib import Path
import re
import time
from dbus_checks import private_bus,peer,control,notify,close,call,CONFIG,monitor
from dbus_native_checks import installed
from declaration_checks import wait,settle,capture
from window_state_checks import launch,stop,counts

COUNTS='''
local ffi=require('ffi');ffi.cdef'long kiln_test_resource(int);'
function resource(k)return tonumber(ffi.C.kiln_test_resource(k))end
function refs()local n=0;for k,v in pairs(debug.getregistry())do if type(k)=='number' and type(v)=='function'then n=n+1 end end;return n end
LOADS=(LOADS or 0)+1
'''
PIXELS='{"image-data": <(1,1,4,true,8,4,@ay [200,40,90,255])>}'


def run(h):
    suite,base=installed(h)
    config=CONFIG+COUNTS
    with private_bus(h.out/'lifecycle-bus') as (address,bus):
        with suite.boot(config,overrides={'DBUS_SESSION_BUS_ADDRESS':address}) as (server,env,work,log):
            def ev(s):return suite.ev(env,s)
            def yes(s):wait(suite,env,'return '+s,b'true\n',server)
            foot,f=launch(env,work,'SERVICE-LIFETIME')
            try:
                yes('#client.all()==1');ev('HANDLE=client.all()[1].handle')
                samples=[]
                last_id=0
                with monitor(env,work,'org.freedesktop.Notifications') as signals:
                    for i in range(6):
                        id=notify(env,title='cycle '+str(i),actions='["accept","Accept"]',hints=PIXELS)
                        assert id>last_id;last_id=id
                        yes('#notification.all()==1')
                        notify(env,title='replaced',replaces=id,hints=PIXELS,actions='["accept","Accept"]')
                        yes('notification.all()[1].title=="replaced"')
                        ev('notification.all()[1]:invoke("accept")');yes('#notification.all()==0')
                        expires=notify(env,title='deadline',timeout=450,hints=PIXELS)
                        with peer(env,work,'org.ktest.Cycle'+str(i),'pixmap') as (p,marker):
                            yes('#K.systray.items()==1');control(env,'org.ktest.Cycle'+str(i),'SetIcon','blue')
                            control(env,'org.ktest.Cycle'+str(i),'SetTitle','updated')
                            yes('K.systray.items()[1].title=="updated"')
                            ev('notification.suspended=true')
                            held=notify(env,title='pending',hints=PIXELS)
                            yes('#notification.pending==1')
                            ev('K.reload()');yes('LOADS=='+str(2+i*2))
                            yes('#notification.pending==1 and #client.all()==1 and client.all()[1].handle==HANDLE')
                            control(env,'org.ktest.Cycle'+str(i),'SetDelay',300)
                            control(env,'org.ktest.Cycle'+str(i),'SetTitle','canceled')
                            yes('resource(6)==1')
                            # Reload fails with a bus read outstanding; the retained timer still expires.
                            rc=work/'rc.lua';rc.write_text('error("private lifecycle repair")')
                            ev('K.reload()');time.sleep(.05);suite.healthy(env)
                            yes('#notification.all()==0')
                            rc.write_text(config);ev('K.reload()');yes('LOADS=='+str(3+i*2))
                            yes('#notification.pending==1')
                            ev('notification.suspended=false');yes('#notification.all()==1')
                            close(env,held);yes('#notification.all()==0')
                        yes('#K.systray.items()==0 and resource(6)==0 and resource(7)==0')
                        # Reuse a well-known identity too; both populations must retire.
                        with peer(env,work,'org.ktest.Reuse','pixmap'):
                            yes('#K.systray.items()==1')
                        yes('#K.systray.items()==0');settle(log);time.sleep(.1)
                        ev('collectgarbage("collect")')
                        vals=list(map(int,ev('return refs(),resource(5),resource(6),resource(7),resource(9),resource(10),resource(11),resource(2),resource(3)').split()))
                        sample=dict(cycle=i,fds=len(list(Path(f'/proc/{server.pid}/fd').iterdir())),refs=vals[0],slots=vals[1],pending=vals[2],items=vals[3],keys=vals[4],timers=vals[5],timer_refs=vals[6],supplied=vals[7],image_bytes=vals[8],rasters=re.findall(r'live buffers (\d+), live bytes (\d+)',log.read_text())[-1])
                        samples.append(sample)
                        assert vals[1:]==[4,0,0,0,0,0,0,0],sample
                        assert signals.read_text().count('NotificationClosed (uint32 '+str(expires)+', uint32 1)')==1
                    stable=[{k:v for k,v in x.items() if k!='cycle'} for x in samples[1:]]
                    assert all(x==stable[0] for x in stable),samples
                    before=counts(log),ev('return resource(8)');time.sleep(.2)
                    assert (counts(log),ev('return resource(8)'))==before
                    capture(env,work/'settled-foot.png')
                    (work/'resources.json').write_text(json.dumps(dict(samples=samples,settled_cycles=5,unchanged_solves_and_dispatch=before[0],owned_pids=[server.pid,foot.pid,bus.pid]),indent=2))
                    # Exit with both a tray read and an expiry outstanding.
                    with peer(env,work,'org.ktest.Shutdown','pixmap','--delay','1000'):
                        notify(env,title='shutdown',timeout=10000,hints=PIXELS)
                        yes('resource(6)==1 and #notification.all()==1')
                        suite.quit(server,env,log)
                    assert not Path(env['KILN_SOCK']).exists()
                    assert 'Async cleanup: timers 0, pipes 0' in log.read_text()
                    assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
            finally:stop(foot);f.close()
    failures(h)
    print('ok   five settled combined cycles, bounded images/slots/FDs/refs/timers, service conflicts, absence and disconnect')


def failures(h):
    # Each occupied name disables only its own service, with no stealing or retry.
    for name in ('org.freedesktop.Notifications','org.kde.StatusNotifierWatcher'):
        directory=h.out/('conflict-'+name)
        with private_bus(directory) as (address,bus):
            penv=dict(__import__('os').environ,DBUS_SESSION_BUS_ADDRESS=address)
            with peer(penv,directory,name,'hold') as (holder,marker):
                owner=marker.read_text().split()[1]
                with h.boot(CONFIG,overrides={'DBUS_SESSION_BUS_ADDRESS':address}) as (server,env,work,log):
                    actual=call(env,'org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus.GetNameOwner',name)
                    assert owner in actual
                    if name=='org.freedesktop.Notifications':
                        assert call(env,'org.kde.StatusNotifierWatcher','/StatusNotifierWatcher','org.freedesktop.DBus.Properties.Get','org.kde.StatusNotifierWatcher','IsStatusNotifierHostRegistered')=='(<true>,)'
                    else:
                        id=notify(env);wait(h,env,'return #notification.all()',b'1\n',server);close(env,id)
                    h.healthy(env);h.ev(env,'n=K.notify{title="local without service",timeout=0};assert(n.id==nil);n:dismiss()')
                    (work/'conflict.txt').write_text('Name remained owned by '+owner+'; independent service answered.\n')
            # The next compositor can acquire the released names.
            with h.boot(CONFIG,overrides={'DBUS_SESSION_BUS_ADDRESS':address}) as (server,env,work,log):
                id=notify(env);wait(h,env,'return #notification.all()',b'1\n',server);close(env,id)
                assert call(env,'org.kde.StatusNotifierWatcher','/StatusNotifierWatcher','org.freedesktop.DBus.Properties.Get','org.kde.StatusNotifierWatcher','ProtocolVersion')=='(<0>,)'
    with h.boot(CONFIG,overrides={'DBUS_SESSION_BUS_ADDRESS':'unix:path='+str(h.out/'absent-private-bus')}) as (server,env,work,log):
        h.ev(env,'n=K.notify{title="No bus",timeout=.1};assert(n.id==nil)')
        wait(h,env,'return #notification.all()',b'0\n',server);h.healthy(env)
        assert 'session bus unavailable' in log.read_text()
    suite,base=installed(h)
    with private_bus(h.out/'death-bus') as (address,bus):
        with suite.boot(CONFIG+COUNTS,overrides={'DBUS_SESSION_BUS_ADDRESS':address}) as (server,env,work,log):
            with peer(env,work,'org.ktest.BusDeath','pixmap') as (p,marker):
                wait(suite,env,'return #K.systray.items()',b'1\n',server)
                control(env,'org.ktest.BusDeath','SetDelay',500);control(env,'org.ktest.BusDeath','SetTitle','pending')
                wait(suite,env,'return resource(6)',b'1\n',server)
                bus.terminate();bus.wait(timeout=5)
                wait(suite,env,'return resource(5),resource(6),#K.systray.items()',b'0\t0\t0\n',server)
                suite.healthy(env);before=suite.ev(env,'return resource(8)');time.sleep(.2);assert suite.ev(env,'return resource(8)')==before
                suite.ev(env,'K.notify{title="Disconnected local",timeout=.1}')
                wait(suite,env,'return #notification.all()',b'0\n',server)
                assert 'services disabled until compositor restart' in log.read_text()
                (work/'disconnect.txt').write_text('Owned bus terminated with pending property read; zero slots/pending/items, no idle dispatch, IPC and local notification expiry survived.\n')
    # A fresh private bus and compositor recover; no reconnect guarantee is asserted.
    with private_bus(h.out/'fresh-bus') as (address,bus):
        with h.boot(CONFIG,overrides={'DBUS_SESSION_BUS_ADDRESS':address}) as (server,env,work,log):
            notify(env);wait(h,env,'return #notification.all()',b'1\n',server)
            with peer(env,work,'org.ktest.Recovered'):wait(h,env,'return #K.systray.items()',b'1\n',server)
