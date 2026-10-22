"""Private D-Bus wire checks. Synthetic dispatch is labeled separately from input."""
import c_baseline
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from declaration_checks import check, wait, settle, capture

ROOT = Path(__file__).resolve().parents[1]
CONFIG = '''
K=require('kiln');ui=K.ui
screen.on('added',function(s)
 tag.new{name='one',screen=s,layout=K.layout.tile};s.tags[1]:view()
 ui.bar(s,{edge='top',h=28,color='#202030'},function()K.widgets.systray();ui.spacer()end)
end)
'''


@contextlib.contextmanager
def private_bus(directory):
    directory.mkdir(parents=True, exist_ok=True)
    address = 'unix:path=' + str(directory/'bus')
    with (directory/'bus.log').open('w') as log:
        bus = subprocess.Popen(['dbus-daemon','--session','--nofork','--nopidfile','--address='+address], stdout=log, stderr=log)
        try:
            end = time.monotonic()+5
            while not (directory/'bus').exists():
                assert bus.poll() is None
                assert time.monotonic()<end
                time.sleep(.01)
            yield address, bus
        finally:
            if bus.poll() is None: bus.terminate()
            bus.wait(timeout=5)


def call(env, dest, path, method, *args):
    assert env['DBUS_SESSION_BUS_ADDRESS'].startswith('unix:path=')
    return subprocess.check_output(['gdbus','call','--session','--dest',dest,'--object-path',path,'--method',method,*map(str,args)], env=env, stderr=subprocess.STDOUT, timeout=5).decode().strip()


def notify(env, title='Hello', body='Body', replaces=0, actions='[]', hints='{}', timeout=0, icon=''):
    r=call(env,'org.freedesktop.Notifications','/org/freedesktop/Notifications','org.freedesktop.Notifications.Notify','fixture',replaces,icon,title,body,actions,hints,'--',timeout)
    return int(r.split()[1].rstrip(',)'))


def close(env, id):
    return call(env,'org.freedesktop.Notifications','/org/freedesktop/Notifications','org.freedesktop.Notifications.CloseNotification',id)


@contextlib.contextmanager
def monitor(env, work, destination):
    path=work/(destination+'.signals')
    with path.open('w') as f:
        p=subprocess.Popen(['stdbuf','-oL','gdbus','monitor','--session','--dest',destination],env=env,stdout=f,stderr=f)
        try:
            end=time.monotonic()+3
            while 'is owned by' not in path.read_text():
                assert p.poll() is None and time.monotonic()<end,path.read_text()
                time.sleep(.02)
            yield path
        finally:
            p.terminate();p.wait(timeout=5)
            (work/(destination+'.monitor-process.json')).write_text(json.dumps(dict(pid=p.pid,exit_code=p.returncode,alive=p.poll() is None)))


@contextlib.contextmanager
def peer(env,work,name,mode='pixmap',*extra):
    marker=work/(name+'.receipts')
    with (work/(name+'.log')).open('a') as f:
        p=subprocess.Popen(['python3',str(ROOT/'scripts/sni-item.py'),name,mode,str(marker),*extra],env=env,stdout=f,stderr=f)
        try:
            end=time.monotonic()+3
            while not marker.exists() or 'Owner ' not in marker.read_text():
                assert p.poll() is None and time.monotonic()<end,(work/(name+'.log')).read_text()
                time.sleep(.02)
            yield p,marker
        finally:
            if p.poll() is None:p.terminate()
            p.wait(timeout=5)
            (work/(name+'.process.json')).write_text(json.dumps(dict(pid=p.pid,exit_code=p.returncode,alive=p.poll() is None)))


def control(env,name,method,*args):
    return call(env,name,'/Control','test.Fixture.'+method,*args)


def live(h,env,name,index=0):
    return h.ev(env,"""local name="""+json.dumps(name)+""";local idx="""+str(index)+"""
local b=core.box({name,idx});if not b then return false end
local s=screen.all()[1]
for _,hit in ipairs(core.hits(s.name,s.x+b.x+b.width/2,s.y+b.y+b.height/2)) do
 if hit.name==name and hit.index==idx then return true end
end;return false""")==b'true\n'


def run(h):
    import notification_checks, tray_checks, dbus_native_checks, dbus_lifetime_checks
    notification_checks.run(h)
    tray_checks.run(h)
    dbus_native_checks.run(h)
    dbus_lifetime_checks.run(h)


if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='dbus-',dir=ROOT/'build/verification'))
    print(out,flush=True)
    import sys
    fn=run
    if len(sys.argv)>1:fn=__import__(sys.argv[1]).run
    with tempfile.TemporaryDirectory(prefix='ko-bus-') as short:
        alias=Path(short)/'e';alias.symlink_to(out,target_is_directory=True)
        fn(mod.Harness(ROOT/'build/kiln',c_baseline.source(),alias))
