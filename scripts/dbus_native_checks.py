"""Installed stock desktop and real outer-X11 clicks/wheel on a private bus."""
import json
from pathlib import Path
import shutil
import subprocess
import time
from dbus_checks import ROOT, private_bus,peer,monitor,control,notify,close
from declaration_checks import wait,settle,capture
from policy_checks import private_x11
from window_state_checks import launch,stop


def installed(h):
    base=h.out/'dbus-installed'
    if not base.exists():
        base.mkdir()
        data=base/'share';data.mkdir()
        shutil.copytree(ROOT/'lua',data/'lua')
        (data/'rc.lua').write_text((ROOT/'kilnrc.lua').read_text()+"\nLOADS=(LOADS or 0)+1\nK=require('kiln')\n")
        subprocess.run(['odin','build','.', '-collection:deps=build','-define:KILN_OUTPUT_FIXTURE=true','-define:KILN_DATADIR='+str(data.resolve()),'-out:'+str((base/'kiln').resolve()),'-extra-linker-flags:-Wl,--export-dynamic'],cwd=ROOT,check=True,timeout=60)
    suite=type(h)((base/'kiln').resolve(),h.original,base)
    suite.count=max([0]+[int(p.name.split('-')[1]) for p in base.glob('run-*')])
    return suite,base


def run(h):
    suite,base=installed(h)
    with private_bus(h.out/'native-notify-bus') as (address,bus),private_x11(h.out) as display:
        with suite.boot(None,cwd=base,overrides={'DBUS_SESSION_BUS_ADDRESS':address,'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
            def ev(s):return suite.ev(env,s)
            def yes(s):wait(suite,env,'return '+s,b'true\n',server)
            yes('LOADS==1 and #screen.all()[1].tags==5')
            ev('s=screen.all()[1];core.output.set_position(s.name,-301,77)')
            foot,f=launch(env,work,'DBUS-STOCK-FOOT')
            try:
                yes('#client.all()==1');ev('HANDLE=client.all()[1].handle')
                win=subprocess.check_output(['xdotool','search','--name',''],env=env,text=True).splitlines()[-1]
                def xdo(*args):subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);time.sleep(.04)
                def at(name,index=0):
                    q=ev('''local name='''+json.dumps(name)+''';local index='''+str(index)+'''
local s=screen.all()[1];core.hits(s.name,s.x,s.y);local b=assert(core.box({name,index}))
local x,y=b.x+b.width/2,b.y+b.height/2;local found=false
for _,hit in ipairs(core.hits(s.name,s.x+x,s.y+y))do if hit.name==name and hit.index==index then found=true end end
assert(found,'no visible hit');return x*s.scale,y*s.scale''').split()
                    xdo('mousemove','--window',win,round(float(q[0])),round(float(q[1])))
                xdo('windowfocus',win)
                with monitor(env,work,'org.freedesktop.Notifications') as signals,peer(env,work,'org.ktest.Native') as (p,marker):
                    yes('#K.systray.items()==1')
                    for scale in (1,1.3):
                        ev('s.scale='+str(scale));yes('math.abs(s.scale-'+str(scale)+')<.001')
                        id=notify(env,title='Stock notifications',body='Real click and wheel',actions='["open","Open log","retry","Retry"]',hints='{"value": <int32 67>,"image-data": <(2,2,8,true,8,4,@ay [255,0,0,255,0,255,0,255,0,0,255,255,255,255,255,255])>}')
                        yes('#notification.all()==1');seq=int(ev('return notification.all()[1].seq'))
                        settle(log);capture(env,work/f'stock-scale-{scale}.png')
                        at('notification:'+str(seq)+':action',1);xdo('click',1);yes('#notification.all()==0')
                        at('tray:org.ktest.Native');xdo('click',1);xdo('click',5)
                        time.sleep(.1)
                        assert 'ActionInvoked (uint32 '+str(id)+", 'open')" in signals.read_text()
                        assert marker.read_text().count('Activate 0 0')>= (1 if scale==1 else 2)
                        assert marker.read_text().count('Scroll 15 vertical')>= (1 if scale==1 else 2),marker.read_text()
                    xdo('key','super+x');xdo('type','--clearmodifiers','6*7');xdo('key','Return')
                    yes('#notification.all()==1 and notification.all()[1].title=="=" and notification.all()[1].message=="42"')
                    settle(log);capture(env,work/'stock-lua-result.png');ev('notification.all()[1]:dismiss()')
                    xdo('key','super+x');xdo('type','--clearmodifiers','error("prompt failure")');xdo('key','Return')
                    yes('#notification.all()==1 and notification.all()[1].title=="Lua error"')
                    ev('notification.all()[1]:dismiss()')
                    # Native do-not-disturb chord reaches the shipped configuration.
                    xdo('key','super+shift+d');yes('notification.suspended')
                    held=notify(env,title='Held through reload')
                    yes('#notification.pending==1')
                    xdo('key','super+shift+d');yes('not notification.suspended and #notification.pending==0')
                    ev('for _,n in ipairs(K and require("kiln.notification").retained())do n:dismiss()end')
                    yes('#notification.all()==0')
                    expiring=notify(env,title='Expiry survives reload',timeout=850)
                    action=notify(env,title='Action survives reload',actions='["resume","Resume"]')
                    yes('#notification.all()==2')
                    ev('notification.suspended=true;OLD=notification.all()[2];OLD:on("dismissed",function()STALE=true end)')
                    pending=notify(env,title='Pending during reload');yes('#notification.pending==1')
                    control(env,'org.ktest.Native','SetDelay',130);control(env,'org.ktest.Native','SetTitle','read through reload')
                    ev('K.reload()');yes('LOADS==2');yes('#notification.pending==1 and #client.all()==1 and client.all()[1].handle==HANDLE')
                    # Break and repair the actual installed config path.
                    rc=Path(ev('return core._config_path()').decode().strip());saved=rc.read_text()
                    try:
                        rc.write_text('error("private installed reload failure")')
                        ev('K.reload()');time.sleep(.12);suite.healthy(env);settle(log);capture(env,work/'stock-broken.png')
                        yes('#notification.all()==1 and notification.all()[1].id=='+str(action))
                        rc.write_text(saved);ev('K.reload()');yes('LOADS==3');yes('#client.all()==1 and client.all()[1].handle==HANDLE')
                    finally:rc.write_text(saved)
                    yes('#K.systray.items()==1 and K.systray.items()[1].title=="read through reload"')
                    yes('#notification.pending==1');ev('notification.suspended=false')
                    yes('#notification.all()==2');seq=int(ev('return notification.all()[1].seq'));settle(log)
                    capture(env,work/'stock-repaired.png');at('notification:'+str(seq)+':action',1);xdo('click',1)
                    yes('#notification.all()==1 and not STALE');close(env,pending);yes('#notification.all()==0')
                    assert signals.read_text().count('NotificationClosed (uint32 '+str(expiring)+', uint32 1)')==1
                    # A broken display reports once, then stops feeding error popups.
                    ev('K.defaults.notify_display=function()error("private display failure")end;core.dirty()')
                    time.sleep(.15);suite.healthy(env);settle(log)
                    before=len(log.read_text());time.sleep(.15);assert len(log.read_text())==before
                    ev('K.reload()');yes('LOADS==4');settle(log);capture(env,work/'stock-display-error-recovery.png');ev('for _,n in ipairs(notification.all())do n:dismiss()end')
                    control(env,'org.ktest.Native','SetIcon','blue');time.sleep(.8);settle(log);capture(env,work/'stock-icon-repaired.png')
                    (work/'input-receipts.json').write_text(json.dumps(dict(backend='private Xvfb -> wlroots X11',scales=[1,1.3],origin=[-301,77],notification_signals=signals.read_text(),tray_methods=marker.read_text(),client_handle=ev('return HANDLE').decode()),indent=2))
            finally:stop(foot);f.close()
    print('ok   installed stock desktop: real action/click/wheel/DND input, fractional non-origin captures and reload repair')
