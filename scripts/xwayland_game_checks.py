"""Real X hidden-cursor grabs translated by XWayland into Wayland locks."""
import re
from xwayland_scenario import scenario,main


def lock_events(s):
    return re.findall(r'zwp_locked_pointer_v1[#@](\d+)\.(locked|unlocked|destroy)\(',s.log.read_text())


def active(s):
    states={}
    for obj,event in lock_events(s):states[obj]=event
    return sum(v=='locked' for v in states.values())


def run(h):
    with scenario(h,fixture=h.implementation=='odin',debug=True) as s:
        x=s.x
        s.click('X');hidden=x.hidden_cursor(s.w);x.grab_pointer(s.w,s.w,hidden);s.pump(.2)
        s.until(lambda:active(s)==1,'XWayland lock activation')
        s.ev('BEFORE=MOTIONS;OLDX=PX;OLDY=PY');start=len(x.records)
        s.shot('game-locked')
        s.xdo('mousemove_relative','--',90,45);s.xdo('mousemove_relative','--',-40,-20)
        s.wait('MOTIONS==BEFORE and PX==OLDX and PY==OLDY')
        motions=[r for r in x.records[start:] if r['event']==6];assert motions,motions
        s.rows.append(dict(case='X lock',events=lock_events(s),x_motions=motions,backend='Xvfb absolute input translated to relative; not raw hardware'))
        # Reload must not send a duplicate activation to an already locked object.
        events=lock_events(s);s.reload();s.pump(.2)
        assert lock_events(s)==events and active(s)==1
        x.warp(s.w,120,110);s.pump();assert active(s)==1
        assert 'set_cursor_position_hint' in s.log.read_text()
        position=x.pointer_position(s.w);assert position['local']==[120,110],position
        s.rows.append(dict(case='X warp under lock',position=position,translated_hint=True))
        s.ev("K.button{mods={'alt'},button=1,press=function(v)v:grab_move()end};K.button{mods={'alt'},button=3,press=function(v)v:grab_resize()end}")
        for button in (1,3):
            s.point('X',100,100);s.ev('BEFORE=MOTIONS')
            old=x.geometry(s.w);s.xdo('keydown','alt');s.xdo('mousedown',button)
            s.until(lambda:active(s)==0,'compositor grab suspends X lock')
            s.xdo('mousemove_relative','--',70,45);s.wait('MOTIONS>BEFORE')
            s.shot('game-move' if button==1 else 'game-resize')
            s.xdo('mouseup',button);s.xdo('keyup','alt');s.point('X',100,100)
            s.until(lambda:active(s)==1,'X lock resumes by focus')
            assert x.geometry(s.w)!=old,(button,old,x.geometry(s.w))
            s.rows.append(dict(case='compositor grab',button=button,before=old,after=x.geometry(s.w),events=lock_events(s)))
        cursor_start=len(s.log.read_text());x.ungrab();x.cursor(s.w);s.pump();s.until(lambda:active(s)==0,'visible cursor release')
        hotspots=re.findall(r'wl_pointer[#@]\d+\.set_cursor\(\d+, wl_surface[#@]\d+, (\d+), (\d+)\)',s.log.read_text()[cursor_start:])
        assert any(int(a)>0 and int(b)>0 for a,b in hotspots),hotspots
        s.rows.append(dict(case='visible X cursor replacement',hotspots=hotspots))
        s.point('N');s.click('N');assert x.focus()!=s.w
        s.shot('game-released')
        s.click('X');hidden=x.hidden_cursor(s.w);x.grab_pointer(s.w,s.w,hidden);s.pump()
        s.until(lambda:active(s)==1,'fresh hidden cursor grab')
        s.ev('core.output.set_enabled(T.name,false)');s.pump();s.h.healthy(s.env)
        s.ev('core.output.set_enabled(T.name,true)');s.pump();s.point('X',100,100)
        x.ungrab();s.pump();x.grab_pointer(s.w,s.w,hidden);s.pump()
        s.until(lambda:active(s)==1,'lock after output enable')
        x.unmap(s.w);s.pump();s.until(lambda:active(s)==0,'unmapped X lock')
        x.map(s.w);s.pump();s.pick();s.ev('X:move_to(T)');s.click('X')
        x.grab_pointer(s.w,s.w,hidden);s.pump();s.until(lambda:active(s)==1,'remapped X lock')
        if h.implementation=='odin':
            s.ev('assert(output_fixture(1,T.name))');s.pump();s.wait('#screen.all()==1');s.h.healthy(s.env)
            s.ev("assert(output_fixture(3,''))");s.pump();s.wait('#screen.all()==2');s.pick();s.refresh_windows()
            s.ev('T.scale=1.5;core.output.set_position(T.name,1161,91);X:move_to(T)');s.pump()
            x.ungrab();s.click('X');x.grab_pointer(s.w,s.w,hidden);s.pump();s.until(lambda:active(s)==1,'lock after output replacement')
        x.destroy(s.w);s.pump();s.until(lambda:active(s)==0,'destroyed X lock')
        s.rows.append(dict(case='focus/unmap/destroy/output/reload recovery',events=lock_events(s)))
        s.quit()
    print('PASS: real XWayland game lock',flush=True)

if __name__=='__main__':main(run,'game-locks')
