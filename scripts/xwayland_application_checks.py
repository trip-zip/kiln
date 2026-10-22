"""Real toolkit applications on owned XWayland displays and private profiles."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
from PIL import Image,ImageChops,ImageStat
from xwayland_scenario import scenario,main


def application(h,kind):
    with scenario(h) as s:
        root=Path(os.environ.get('KILN_APP_ROOT',str(Path.home()/'.cache/kiln-session16-apps/root')))
        env=dict(s.env,DISPLAY=s.inner,GDK_BACKEND='x11',QT_QPA_PLATFORM='xcb',MOZ_ENABLE_WAYLAND='0',MOZ_DBUS_REMOTE='0',NO_AT_BRIDGE='1')
        for key in ('HOME','XDG_CONFIG_HOME','XDG_DATA_HOME','XDG_CACHE_HOME'):Path(env[key]).mkdir(parents=True,exist_ok=True)
        text='kiln session16 '+kind
        if kind=='gtk':cmd=['zenity','--entry','--title=Kiln GTK entry','--text=Private compatibility entry']
        elif kind=='qt':cmd=['vlc','--no-one-instance','--no-media-library','--no-qt-privacy-ask']
        elif kind=='firefox':
            profile=s.work/'firefox-profile';profile.mkdir()
            (profile/'user.js').write_text('user_pref("browser.shell.checkDefaultBrowser",false);user_pref("browser.aboutwelcome.enabled",false);user_pref("browser.startup.homepage_override.mstone","ignore");user_pref("datareporting.policy.dataSubmissionEnabled",false);')
            page=s.work/'input.html';page.write_text('<title>Kiln Firefox input</title><body onclick="document.title=String.fromCharCode(99,108,105,99,107,101,100)" style="background:#ccddee;min-height:100vh"><h1>Private X11 application check</h1><input autofocus style="font-size:24px" oninput="document.title=this.value"><button onclick="document.title=\'clicked\'">Pointer receipt</button>')
            cmd=['firefox','--no-remote','--new-instance','--profile',str(profile),page.as_uri()]
        elif kind=='java-game':
            cmd=[str(root/'usr/lib/jvm/java-27-openjdk/bin/java'),'-Duser.home='+env['HOME'],'-jar',str(root/'usr/share/java/freecol/FreeCol.jar'),'--freecol-data',str(root/'usr/share/java/freecol/data'),'--no-sound','--windowed','800x600','--no-intro','--no-splash','--private','--server-ip','127.0.0.1']
        else:raise AssertionError(kind)
        log=s.work/'application.log';result=dict(kind=kind,versions=subprocess.check_output(['pacman','-Q','zenity','gtk4','vlc','qt5-base','firefox'],text=True),command=cmd,inner=s.inner,outer=s.env['DISPLAY'],profile=env['HOME'])
        with log.open('w') as output:
            process=subprocess.Popen(cmd,env=env,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
            result['pid']=process.pid
            try:
                end=time.monotonic()+45
                while time.monotonic()<end:
                    s.pump(.1)
                    if int(s.val('#client.all()'))>=3:break
                    assert process.poll() is None,log.read_text()
                s.wait('#client.all()>=3')
                def pick():s.ev("for _,c in ipairs(client.all())do if c~=X and c~=N and not c.override_redirect then A=c;break end end")
                pick();s.ev('A:move_to(T);A:focus()');s.pump(.3)
                handle=int(s.val('A.handle'));matches=re.findall(r'X11 associate window=(\d+) handle='+str(handle)+r' ',s.log.read_text());assert matches,(handle,s.log.read_text()[-2000:])
                window=int(matches[-1]);result.update(window=window,handle=handle,wm_class=s.x.get_property(window,'WM_CLASS')[3].decode(errors='replace'),wm_pid=s.x.get_property(window,'_NET_WM_PID')[3].hex())
                s.point('A',100,100);s.focus('A')
                if kind=='gtk':s.point('A',100,133);s.xdo('click',1)
                if kind=='qt':
                    s.xdo('key','ctrl+n');s.pump(.5);s.wait('#client.all()==4');s.shot('qt-network-dialog')
                    handles=s.val("(function()local r={};for _,c in ipairs(client.all())do if c~=X and c~=N then r[#r+1]=c.handle end end;return table.concat(r,' ')end)()").decode().split()
                    windows=[int(re.findall(r'X11 associate window=(\d+) handle='+v+r' ',s.log.read_text())[-1]) for v in handles]
                    assert len({v & ~s.x.mask for v in windows})==1,windows
                    result['shared_connection_windows']=windows
                if kind in ('gtk','qt','firefox'):
                    if kind=='firefox':s.xdo('key','ctrl+l')
                    s.xdo('key','ctrl+a');s.xdo('type','--clearmodifiers','--delay','10',text);s.xdo('key','ctrl+a');s.xdo('key','ctrl+c')
                    s.pump(.2);s.focus('X')
                    received=s.x.receive(s.w,'CLIPBOARD','UTF8_STRING',s.pump)
                    assert received==text.encode(),(kind,received,text)
                    result['typed_copied_bytes']=received.hex()
                    if kind=='qt':s.focus('A');s.xdo('key','Escape')
                    if kind=='firefox':
                        s.focus('A');s.xdo('key','Escape');s.point('A',200,180);s.xdo('click',1)
                        s.until(lambda:s.x.get_property(window,'_NET_WM_NAME')[3].startswith(b'clicked'),'Firefox page pointer receipt')
                        result['pointer_title']=s.x.get_property(window,'_NET_WM_NAME')[3].decode()
                if kind=='java-game':
                    s.ev('T.scale=1;A.fullscreen=true');s.pump(.5);s.shot('java-menu-full')
                    s.point('A',345,292);s.xdo('click',1);s.pump(.5);s.shot('java-new-game')
                    diff=ImageChops.difference(Image.open(s.work/'java-menu-full.png').convert('RGB'),Image.open(s.work/'java-new-game.png').convert('RGB'))
                    assert sum(ImageStat.Stat(diff).mean)>5,'game menu did not respond to pointer'
                    result['game_menu_pointer']=True
                    s.point('A',520,182);s.xdo('click',1);s.xdo('key','ctrl+a');s.xdo('type','--clearmodifiers',text);s.xdo('key','ctrl+a');s.xdo('key','ctrl+c');s.focus('X')
                    received=s.x.receive(s.w,'CLIPBOARD','UTF8_STRING',s.pump);assert received==text.encode(),received
                    result['typed_copied_bytes']=received.hex();s.focus('A');s.shot('java-text-clipboard')
                    s.point('A',540,477);s.xdo('click',1);s.pump(.2)
                s.shot(kind+'-mapped')
                result['scales']=[]
                for scale in (1,1.5,2):
                    s.ev(f'T.scale={scale};A:move_to(T);A.fullscreen=false;A.maximized=false;A.floating=true;A.float={{x=80,y=70,width=360,height=280}}');s.pump(.25)
                    before=s.x.geometry(window);s.ev('A.float={x=110,y=95,width=410,height=310}');s.pump(.25)
                    after=s.x.geometry(window);assert before[2:]!=after[2:],(kind,before,after)
                    s.ev('A.fullscreen=true');s.pump(.2)
                    state=s.x.get_property(window,'_NET_WM_STATE')[3];assert s.x.atom('_NET_WM_STATE_FULLSCREEN').to_bytes(4,'little') in state
                    s.ev('A.fullscreen=false;A:move_to(S)');s.pump(.2);left=s.x.geometry(window)
                    s.ev('A:move_to(T)');s.pump(.2);assert s.x.geometry(window)[:2]!=left[:2]
                    result['scales'].append(dict(scale=scale,before=before,resized=after,moved_from=left,moved_to=s.x.geometry(window)))
                s.reload();pick();s.ev('A:move_to(T);A:focus()');s.pump(.3);s.h.healthy(s.env);s.shot(kind+'-reloaded')
                result['reload']=True
                if kind=='gtk':
                    s.xdo('key','Return');process.wait(timeout=8);assert text in log.read_text(),log.read_text()
                    result['entry_stdout']=text
                else:
                    s.ev('A:close()');s.pump(.4)
                    result['close_requested']=True
                s.h.healthy(s.env)
            finally:
                result['exit_before_cleanup']=process.poll()
                try:os.killpg(process.pid,signal.SIGTERM)
                except ProcessLookupError:pass
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=5)
                result['exit_after_cleanup']=process.returncode
                def remaining():
                    found=[]
                    for path in Path('/proc').iterdir():
                        if not path.name.isdigit():continue
                        try:
                            fields=(path/'stat').read_text().rsplit(')',1)[1].split()
                            if int(fields[2])==process.pid and fields[0]!='Z':found.append(int(path.name))
                        except (FileNotFoundError,ProcessLookupError):pass
                    return found
                end=time.monotonic()+5
                while remaining() and time.monotonic()<end:time.sleep(.025)
                result['remaining_processes']=remaining()
                (s.work/'application.json').write_text(json.dumps(result,indent=2)+'\n')
                assert not result['remaining_processes'],result['remaining_processes']
        s.wait('#client.all()==2');s.quit()
    print('PASS: real application '+kind,flush=True)


def run(h):
    failures=[]
    for kind in os.environ.get('KILN_APP_CASES','gtk,qt,firefox,java-game').split(','):
        try:application(h,kind)
        except Exception as exc:
            print('FAIL: application',kind,repr(exc),flush=True);failures.append((kind,repr(exc)))
    assert not failures,failures

if __name__=='__main__':main(run,'applications')
