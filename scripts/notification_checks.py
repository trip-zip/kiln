"""Notification protocol, model, pixels and deterministic action dispatch."""
from PIL import Image
import subprocess
import time
from dbus_checks import private_bus,monitor,notify,close,call,live,CONFIG
from declaration_checks import check,wait,settle,capture


def run(h):
    with private_bus(h.out/'notification-bus') as (address,bus):
        with h.boot(CONFIG,overrides={'DBUS_SESSION_BUS_ADDRESS':address}) as (server,env,work,log):
            def ev(s):return h.ev(env,s)
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            with monitor(env,work,'org.freedesktop.Notifications') as signals:
                assert call(env,'org.freedesktop.Notifications','/org/freedesktop/Notifications','org.freedesktop.Notifications.GetServerInformation')=="('kiln', 'kiln', '0.1', '1.2')"
                assert call(env,'org.freedesktop.Notifications','/org/freedesktop/Notifications','org.freedesktop.Notifications.GetCapabilities')=="(['body', 'actions', 'icon-static'],)"
                xml=subprocess.check_output(['gdbus','introspect','--session','--dest','org.freedesktop.Notifications','--object-path','/org/freedesktop/Notifications','--xml'],env=env,text=True,timeout=5)
                (work/'notifications.xml').write_text(xml)
                assert all(x in xml for x in ('Notify','ActionInvoked','NotificationClosed','a{sv}'))
                id=notify(env,actions='["open","Open log","rerun","Rerun","odd"]',hints='{"value": <int32 42>}')
                assert id==1;yes('#notification.all()==1')
                check(h,env,'local n=notification.all()[1];return n.title,n.message,#n.actions,n.actions[1].key,n.actions[2].key,n.actions[3].label,n.value',b'Hello\tBody\t3\topen\trerun\todd\t42\n')
                settle(log);assert live(h,env,'notification:1');assert live(h,env,'notification:1:action',1)
                check(h,env,'local a,b=core.box("notification:1:fill"),core.box("notification:1:bar");return math.floor(a.width/b.width*100+.5)',b'42\n')
                capture(env,work/'actions-progress.png')
                ev('local s=screen.all()[1];assert(require("kiln.state").screen_presses[s.name]["on_press:notification:1:action#1"])()')
                yes('#notification.all()==0');settle(log);assert not live(h,env,'notification:1')
                text=signals.read_text();assert 'ActionInvoked (uint32 1, \'open\')' in text and 'NotificationClosed (uint32 1, uint32 2)' in text,text
                id=notify(env,title='Volume',hints='{"value": <int32 40>}')
                assert id==2
                assert notify(env,title='Volume',body='42%',replaces=id,hints='{"value": <int32 42>}')==id
                yes('#notification.all()==1 and notification.all()[1].message=="42%"')
                close(env,id);yes('#notification.all()==0')
                close(env,888);assert notify(env,replaces=999)==999;yes('#notification.all()==1');close(env,999);yes('#notification.all()==0')
                id=notify(env,timeout=180);assert id==3;yes('#notification.all()==1');yes('#notification.all()==0')
                time.sleep(.03);assert 'NotificationClosed (uint32 3, uint32 1)' in signals.read_text()
                ev('K.theme.notification_timeout.normal=.12')
                id=notify(env,timeout=-1);yes('#notification.all()==1');yes('#notification.all()==0')
                id=notify(env,timeout=80,hints='{"urgency": <byte 2>}');yes('notification.all()[1].urgency=="critical"');time.sleep(.15);yes('#notification.all()==1')
                ev('notification.all()[1].urgency="normal"');yes('#notification.all()==0')
                id=notify(env,timeout=120);yes('#notification.all()==1');ev('notification.all()[1].urgency="critical"');time.sleep(.2);yes('#notification.all()==1')
                ev('notification.all()[1].urgency="normal";notification.all()[1].timeout=0');time.sleep(.2);yes('#notification.all()==1');close(env,id);yes('#notification.all()==0')
                ev('notification.suspended=true')
                first=notify(env,title='first',timeout=100)
                second=notify(env,title='second')
                yes('#notification.pending==2 and #notification.all()==0')
                assert notify(env,title='replaced pending',replaces=first,timeout=100)==first
                yes('#notification.pending==2 and notification.pending[1].title=="replaced pending"')
                close(env,second);yes('#notification.pending==1');time.sleep(.2);yes('#notification.pending==1')
                third=notify(env,title='third');yes('#notification.pending==2')
                ev('notification.suspended=false');yes('#notification.pending==0 and #notification.all()==2 and notification.all()[1].id=='+str(first))
                yes('#notification.all()==1');close(env,third);yes('#notification.all()==0')
                pixels='(2,2,8,true,8,4,@ay [255,0,0,255,0,255,0,128,0,0,255,255,255,255,255,255])'
                for alias in ('image-data','image_data','icon_data'):
                    id=notify(env,title=alias,hints='{"'+alias+'": <'+pixels+'>,"image-path": <"/not/chosen">}',icon='/also/not/chosen')
                    yes('#notification.all()==1 and notification.all()[1].icon=="notify:'+str(id)+'"')
                    seq=ev('return notification.all()[1].seq').decode().strip();settle(log);assert live(h,env,'notification:'+seq+':icon');capture(env,work/(alias+'.png'))
                    if alias=='image-data':
                        blue='(3,3,12,true,8,4,@ay ['+','.join(['30,80,230,255']*9)+'])'
                        notify(env,replaces=id,title='Replaced pixels',hints='{"image-data": <'+blue+'>}')
                        yes('notification.all()[1].title=="Replaced pixels"');settle(log);capture(env,work/'inline-replaced.png')
                        x,y=map(float,ev('local b=core.box("notification:'+seq+':icon");return b.x+b.width/2,b.y+b.height/2').split())
                        assert Image.open(work/'inline-replaced.png').convert('RGB').getpixel((int(x),int(y)))==(30,80,230)
                    close(env,id);yes('#notification.all()==0')
                for image in ('(64,64,256,true,8,4,@ay [1,2,3,4])','(-1,2,8,true,8,4,@ay [1])','(2,2,1,true,8,4,@ay [1])','(2147483647,2147483647,2147483647,true,8,4,@ay [1])'):
                    id=notify(env,hints='{"image-data": <'+image+'>}')
                    yes('#notification.all()==1 and notification.all()[1].icon==nil');close(env,id);yes('#notification.all()==0')
                id=notify(env,hints='{"image-path": <"/nonexistent/icon.png">,"flag": <true>,"str": <"text">,"signed": <int64 -5>,"float": <1.25>,"container": <[1,2]>}')
                yes('#notification.all()==1')
                check(h,env,'local n=notification.all()[1];return n.icon,n.hints.flag,n.hints.str,n.hints.signed,n.hints.float,n.hints.container',b'/nonexistent/icon.png\ttrue\ttext\t-5\t1.25\tnil\n')
                close(env,id);yes('#notification.all()==0');time.sleep(.03)
                before=signals.read_text().count('NotificationClosed')
                ev('local n=K.notify{title="local",timeout=0};n:invoke("open");n:invoke("again")')
                time.sleep(.05);assert signals.read_text().count('NotificationClosed')==before
                assert signals.read_text().count('ActionInvoked')==1
                assert 'NotificationClosed (uint32 2, uint32 3)' in signals.read_text()
                (work/'coverage.txt').write_text('Real methods/signals, deterministic handler dispatch, visible hits, scalar hints, image aliases/precedence/replacement/validation, pending replacement/close, timeout/urgency, local no-signals.\n')
            assert 'Lua event:' not in log.read_text() and "kiln: error in '" not in log.read_text()
    print('ok   notification wire battery, model edges, hits and inline replacement')

    with h.boot(CONFIG,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        h.ev(env,'core.output.set_position(screen.all()[1].name,-301,77);screen.all()[2].scale=1.3;n=K.notify{title="Source multi-output",timeout=0,screen=screen.all()[1]};core.dirty()')
        settle(log)
        result=h.ev(env,'''local found=0;for _,s in ipairs(screen.all())do
core.hits(s.name,s.x,s.y);local b=core.box('notification:1');assert(b)
for _,v in ipairs(core.hits(s.name,s.x+b.x+b.width/2,s.y+b.y+b.height/2))do if v.name=='notification:1' then found=found+1 end end
end;return found''')
        assert result==b'2\n',result
        capture(env,work/'source-multi-output.png')
        (work/'multi-output.txt').write_text('Source default display iterates all active notifications on each output, despite n.screen. Both outputs were explicitly dirtied; no screen-filter policy was introduced.\n')
