"""Real transient/menu lifetimes and outer-backend grab receipts."""
import c_baseline
import json
import re
import subprocess
import time
from pathlib import Path
from PIL import Image
from declaration_checks import check, wait, settle
from policy_checks import private_x11
from layer_checks import CONFIG
from protocol_client import Client
from window_state_checks import launch, stop
from x11_client import XClient, u
from xwayland_checks import dependencies, xcommand, until

CONFIG += """
RULES=0; MAPS={}
K.rule{match={class='WireX11'},on=function(c) RULES=RULES+1;if c.parent then c.floating=true end end}
client.on('map',function(c)MAPS[#MAPS+1]={c.handle,c.parent and c.parent.handle} end)
"""


def run(h):
    dependencies()
    with private_x11(h.out) as outer:
        with h.boot(CONFIG,overrides={'DISPLAY':outer,'WAYLAND_DISPLAY':None,'WLR_BACKENDS':'x11','WLR_X11_OUTPUTS':'2'}) as (server,env,work,log):
            inner=h.ev(env,'return os.getenv("DISPLAY")').decode().strip()
            x=XClient(inner);n=Client(env);n.bind('zwlr_foreign_toplevel_manager_v1',3)
            foot,f=launch(env,work,'TRANSIENT-FOOT');rows=[]
            def ev(s):check(h,env,'do '+s+' end',b'\n')
            def yes(s):wait(h,env,'return '+s,b'true\n',server)
            def pump():x.pump(.08);n.pump(.1)
            def xdo(*args):xcommand(env,'xdotool',*args);pump()
            def pick():ev("for _,c in ipairs(client.all())do if c.instance=='parent' then P=c elseif c.instance=='dialog' then D=c elseif c.instance=='nested' then C=c elseif c.app_id=='TRANSIENT-FOOT' then F=c end end")
            def box(c):return list(map(float,h.ev(env,f"core.hits({c}.screen.name,0,0);local b=core.box({{'core.surface',{c}.handle}});return b.x,b.y,b.width,b.height").split()))
            def foreign_titles():n.pump(.1);return [m.get('title') for k,m in n.objects.values() if k=='foreign' and not m.get('closed')]
            def shot(label,output='X11-1'):
                path=work/(label+'.png');subprocess.run(['grim','-o',output,str(path)],env=env,check=True,timeout=5);return Image.open(path).convert('RGB')
            try:
                yes('#client.all()==1')
                ev("for _,s in ipairs(screen.all())do if s.name=='X11-1' then S=s else T=s end end;core.output.set_position(S.name,137,91);S.scale=1;T.scale=1.5;core.output.set_position(T.name,1161,91);screen.focused=S")
                p=x.create(title='Parent',instance='parent');yes('#client.all()==2')
                d=x.create(title='Dialog',instance='dialog',parent=p,window_type='DIALOG',color=0xa04040);yes('#client.all()==3')
                c=x.create(title='Nested',instance='nested',parent=d,window_type='DIALOG',color=0x408040);yes('#client.all()==4');pick()
                ev('assert(D.parent==P and C.parent==D and D.floating and C.floating and RULES==3);P.floating=true;P.float={x=40,y=90,width=350,height=300};D.float={x=90,y=150,width=300,height=220};C.float={x=150,y=210,width=250,height=160};F:move_to(T);C:focus()')
                pump();settle(log)
                windows=xcommand(env,'xdotool','search','--name','').decode().splitlines();assert len(windows)==3,windows
                win=windows[-2];xdo('windowraise',win);xdo('windowfocus',win)
                def point(lx,ly):
                    lw,lh=map(float,h.ev(env,'return S.width,S.height').split())
                    xdo('windowraise',win);xdo('windowfocus',win)
                    xdo('mousemove','--window',win,round(lx*1024/lw),round(ly*768/lh))
                def click(cname,wid):
                    b=box(cname);point(b[0]+30,b[1]+30);start=len(x.records);xdo('click',1)
                    found=[r for r in x.records[start:] if r['event']==4]
                    assert found and found[-1]['window']==wid and not found[-1]['synthetic'],found
                    assert all(abs(a-b)<=1 for a,b in zip(found[-1]['local'],[30,30])),found
                    rows.append(dict(client=cname,geometry=x.geometry(wid),button=found[-1],stack=x.children()))
                click('C',c);yes('core.client.focused()==C.handle');assert x.focus()==c
                stack=x.children();assert stack.index(c)>stack.index(d)>stack.index(p),('X stack differs from published nested order',stack,p,d,c)
                shot('nested-dialogs')
                # Published order remains meaningful even when the focused parent changes.
                ev('P.fullscreen=true;P:focus()');pump();settle(log)
                point(190,260);start=len(x.records);xdo('click',1)
                found=[r for r in x.records[start:] if r['event']==4]
                assert found and found[-1]['window']==p,('fullscreen visible/input disagreement',found)
                stack=x.children();assert stack.index(p)>stack.index(c),('X stack differs from fullscreen publication',stack,p,c)
                shot('fullscreen-over-dialogs');ev('P.fullscreen=false;C:focus()');pump()
                # Parent changes and invalid chains stay facts, without re-running rules.
                x.prop(c,'WM_TRANSIENT_FOR','WINDOW',u(p),32);x.sync();yes('C.parent==P')
                x.prop(p,'WM_TRANSIENT_FOR','WINDOW',u(c),32);x.sync();pump();yes('P.parent==nil and C.parent==P')
                x.prop(c,'WM_TRANSIENT_FOR','WINDOW',u(c),32);x.sync();pump();yes('C.parent==P')
                x.prop(c,'WM_TRANSIENT_FOR','WINDOW',u(d),32);x.sync();yes('C.parent==D')
                x.unmap(d);yes('not D.mapped and C.parent==D');ev('DH=D.handle;K.reload()');pump();pick()
                # Replay includes mapped clients only; the stale Lua parent is retired.
                yes('C.parent==nil and C.transient_for==DH and D.dead')
                x.map(d);pump();pick();yes('D.mapped and D.handle==DH and C.parent==D');ev('K.reload()');pump();pick();yes('D.parent==P and C.parent==D')
                ev('local seen={} for _,v in ipairs(MAPS)do assert(not v[2] or seen[v[2]]);seen[v[1]]=true end;C:focus()')
                # OR types bypass rules and chrome, remain foreign mirrors and own geometry.
                rules=int(h.ev(env,'return RULES'));menus=[]
                for i,kind in enumerate(['MENU','DROPDOWN_MENU','TOOLTIP',None]):
                    parent=menus[-1] if menus else c
                    m=x.create(title='Menu '+str(i),instance='menu-'+str(i),override=True,parent=parent,window_type=kind,box=(340+i*25,350+i*20,180,100),color=0xd0a030+i*0x040400)
                    menus.append(m);pump();yes('#client.all()=='+str(5+i))
                    ev("for _,a in ipairs(client.all())do if a.instance=='menu-"+str(i)+"' then M=a end end;assert(M.override_redirect and M.wants_focus=="+str(kind is None).lower()+')')
                    assert int(h.ev(env,'return RULES'))==rules
                    assert 'Menu '+str(i) in foreign_titles()
                    assert x.geometry(m)==[340+i*25,350+i*20,180,100]
                    assert not re.search(r'X11 published window='+str(m)+r' ',log.read_text())
                yes('core.client.focused()==M.handle')
                shot('nested-menus')
                # X server grabs, unlike Lua grabs, route actual server events to this window.
                m=menus[-1];x.grab_pointer(m);x.grab_keyboard(m)
                point(60,130);start=len(x.records);xdo('click',1)
                outside=[r for r in x.records[start:] if r['event']==4]
                assert outside and outside[-1]['window']==m and outside[-1]['local'][0]<0,outside
                x.ungrab();x.unmap(m);yes('not M.mapped');x.map(m);pump();x.grab_keyboard(m)
                start=len(x.records);xdo('key','Escape')
                assert any(r['event']==2 and r['window']==m and r['detail']==9 for r in x.records[start:]),x.records[start:]
                x.ungrab();x.unmap(m);yes('not M.mapped');x.map(m);pump();x.grab_keyboard(m)
                ev("BOUND=0;K.key{key='F6',press=function()BOUND=BOUND+1 end}")
                start=len(x.records);xdo('key','F6');yes('BOUND==1');assert not any(r['event']==2 for r in x.records[start:])
                ev('G=K.keygrabber{}');start=len(x.records);xdo('key','a');assert not any(r['event']==2 for r in x.records[start:]);ev('G:stop()')
                layer=n.layer('exclusive-menu',output='X11-1',keyboard=1)
                yes('core.client.focused()==LS.all[1].handle');start=len(x.records);ns=len(n.records);xdo('key','b')
                assert not any(r['event']==2 for r in x.records[start:])
                assert any(r.get('input')=='keyboard' and r['op']==3 for r in n.records[ns:])
                n.destroy(layer);pump();x.ungrab()
                # Move client-owned child across adjacent outputs at mixed densities.
                x.configure(m,x=1110,y=280,width=200,height=120);pump();settle(log)
                assert x.geometry(m)==[1110,280,200,120]
                # Whole output trees retain their order, so the later output's
                # background occludes overhang from the earlier output.
                left=shot('boundary-child-left');right=shot('boundary-child-right','X11-2')
                assert left.getpixel((995,220))==(220,172,48)
                assert right.getpixel((30,330))!=(220,172,48)
                # Put the child in the upper output tree; its visible overhang
                # into the other output must receive the same surface's input.
                ev('M:move_to(T)');pump();settle(log)
                left=shot('boundary-upper-left');right=shot('boundary-upper-right','X11-2')
                assert left.getpixel((995,220))==(220,172,48) and right.getpixel((30,330))==(220,172,48)
                point(20,600);point(995,220);start=len(x.records);xdo('click',1)
                x.pump(.2);assert x.geometry(m)==[1110,280,200,120]
                found=[r for r in x.records[start:] if r['event']==4]
                assert found and found[-1]['window']==m,('visible cross-output child missed',found)
                assert found[-1]['local']==[22,31] and found[-1]['root']==[1132,311] and not found[-1]['synthetic'],found
                rows.append(dict(client='boundary menu',geometry=x.geometry(m),button=found[-1],stack=x.children()))
                old=x.geometry(m)
                ev("core.set_frame_handler(function()error('transient rejected declaration')end);core.dirty()")
                time.sleep(.15);assert x.geometry(m)==old
                (work/'rc.lua').write_text("error('transient broken reload')\n");ev('K.reload()');pump();assert x.geometry(m)==old;h.healthy(env)
                (work/'rc.lua').write_text(CONFIG);ev('K.reload()');pump();pick();yes('C.parent==D and D.parent==P')
                # Destroying an ancestor clears direct children safely, including open menus.
                x.destroy(c);yes('C.dead');pump();ev("for _,a in ipairs(client.all())do if a.instance=='menu-0' then assert(a.parent==nil) end end")
                for m in reversed(menus):x.destroy(m);pump()
                ev('D:focus()');until(lambda:x.focus()==d,'dialog focus restored')
                a=n.toplevel('popup-neighbor');pump()
                ev("for _,v in ipairs(client.all())do if v.app_id=='popup-neighbor' then N=v end end;N:move_to(S);N.floating=true;N.float={x=400,y=160,width=300,height=250};N:focus()")
                pump();settle(log);nb=box('N');point(nb[0]+30,nb[1]+40);ns=len(n.records);xdo('mousedown',1)
                serial=[r for r in n.records[ns:] if r.get('input')=='pointer' and r['op']==3][-1]['words'][0]
                pop=n.popup(a,anchor=(60,60,5,5),size=(160,90),grab=serial);xdo('mouseup',1)
                ev('D:move_to(S);D.fullscreen=true');pump();settle(log)
                nb=box('N');px,py=nb[0]+pop['box'][0]+20,nb[1]+pop['box'][1]+20
                point(px,py);ns=len(n.records);xs=len(x.records);xdo('click',1)
                enters=[r for r in n.records if r.get('input')=='pointer' and r['op']==0]
                assert enters[-1]['words'][1]==pop['surface']
                assert len([r for r in n.records[ns:] if r.get('input')=='pointer' and r['op']==3])==2
                assert not any(r['event']==4 for r in x.records[xs:])
                picture=shot('native-popup-over-x-fullscreen');assert picture.getpixel((int(px),int(py)))==(208,144,32)
                assert picture.getpixel((50,500))==(160,64,64)
                n.destroy_xdg(pop);n.destroy_xdg(a);ev('D.fullscreen=false');pump()
                x.destroy(p);pump();yes('D.parent==nil');ev('K.reload()');pump();pick();yes('D.parent==nil');h.healthy(env)
                (work/'transient-wire.json').write_text(json.dumps(dict(outer=outer,inner=inner,samples=rows,x=x.records,native=n.records),indent=2)+'\n')
                h.quit(server,env,log)
            finally:x.close();n.close();stop(foot);f.close()
    print('PASS: transient parent changes/cycles/unmap/death/replay, nested OR types/foreign mirrors, real X grabs/dismissal, Lua/layer precedence, mixed-scale boundary input, native popup over X fullscreen and failed/repaired reload',flush=True)


if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-xtransient-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
