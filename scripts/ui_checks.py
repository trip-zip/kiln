"""Primitive UI publication, settling, scrolling and owned native input."""
import c_baseline
import importlib.util
import json
import subprocess
import tempfile
import time
from pathlib import Path
from PIL import Image
from declaration_checks import check, wait
from paint_checks import ROOT, screenshot, pixel, stats
from policy_checks import private_x11
CONFIG=r'''
K=require('kiln');ui=K.ui
COUNTS={};N=10;FITSIZE=130;P=0;R=0;OUTER=0;ENTER=0;LEAVE=0;BAD=0;ERR=0;FLOAT=0
K.on('error',function() ERR=ERR+1 end)
screen.on('added',function(s) if #s.tags==0 then tag.new{name='ui',screen=s} end end)
function draw(sn,w,h)
 COUNTS[sn]=(COUNTS[sn] or 0)+1
 ui.column({id='root',w=w,h=h,color='#101014'},function()
  ui.box({id='workarea:'..sn,w=w,h=h},function()
   ui.column({id='panel',w=350,h=400,pad=20,gap=12,on_press=function() OUTER=OUTER+1 end},function()
    ui.row({w=310,h=50,gap=12},function()
     ui.image(IMAGE,{w=50,h=50,radius=8})
     ui.box({id='label',w=180,h=40,clip={horizontal=true}},function() ui.text('Héllo λ 世界: a long clipped label',{size=22,ellipsize=true,wrap='none'}) end)
    end)
    ui.scroll({id={'scroll',1},w=260,h=120,color='#202030',step=4},function()
     for i=1,N do
      local row=i
      ui.box({id={'row',i},w='grow',h=40,color=i%2==0 and '#405080' or '#304060',
       on_press=REPLACE and function() BAD=BAD+1 end or function() P=P+1;LAST=row;if THROW then error('row callback') end end,
       on_release=function() R=R+1 end,
       on_hover=function(over,hit) assert(hit.screen==sn);if over then ENTER=ENTER+1 else LEAVE=LEAVE+1 end end},
       function() ui.text('Row '..i,{size=18}) end)
     end
    end)
    ui.scroll({id={'scroll',2},w=260,h=60,color='#303030'},function() ui.box({w=260,h=100},function() ui.text('Independent indexed viewport') end) end)
   end)
   ui.box({id='edge',w=20,h=20,float={to='root',anchor='right_bottom',offset={x=-5,y=-5}}})
   ui.box({id='fitted',w=FITSIZE,h=70,color='#806020',float={to='element',parent='edge',anchor={parent='right_bottom',element='left_top'},fit=true,band='overlay'}},function() ui.text('Fitted float') end)
   ui.box({id='rootfit',w=40,h=20,color='#604020',float={to='root',anchor='right_bottom',offset={x=50,y=50},fit=true}})
   ui.box({id='underfloat',w=100,h=60,color='#803040',float={to='root',offset={x=380,y=30},band='below'},on_press=function() FLOAT=FLOAT+10 end})
   ui.box({id='overfloat',w=100,h=60,color='#208060',float={to='root',offset={x=410,y=50},band='above',passthrough=true},on_press=not NOFLOAT and function() FLOAT=FLOAT+1 end or nil})
   if SHOWOVER then ui.box({id='overlay-clip',w=OVERCLIP and 40 or 80,h=60,clip={horizontal=OVERCLIP},float={to='root',offset={x=700,y=300},band='overlay',passthrough=true}},function() ui.box({id='client-overlay',w=80,h=60,color='#605020',on_press=function() FLOAT=FLOAT+100 end}) end) end
   for _,c in ipairs(K.visible_clients(screen.all()[1])) do
    ui.box({id='client-clip',w=100,h=100,clip={horizontal=true,vertical=true},float={to='root',offset={x=500,y=160},band='normal'}},function()
     ui.surface(c,{w=400,h=320})
    end)
   end
  end)
 end)
 if FAIL then ui.box({id={'row',1},on_press=function() BAD=BAD+1 end});error('staged handler') end
 if HUGE then ui.box({w=100000,h=100000,radius=4,color='#ffffff'}) end
 collectgarbage('collect')
end
core.set_frame_handler(draw)
'''

def settled(h,env,server,screen):
    # Wait for the bounded follow-up frame and reject an ongoing repaint loop.
    time.sleep(.15)
    n=h.ev(env,f"return COUNTS['{screen}']")
    time.sleep(.15)
    assert h.ev(env,f"return COUNTS['{screen}']")==n, 'UI did not settle'
    assert server.poll() is None

def change(h,env,server,screen,src):
    check(h,env,src+f";core.dirty('{screen}')",b'\n')
    settled(h,env,server,screen)

def run(h):
    asset=h.out/'ui.png';Image.new('RGBA',(50,50),(90,180,240,255)).save(asset)
    cfg='IMAGE='+json.dumps(str(asset))+'\n'+CONFIG
    with private_x11(h.out) as display:
      with h.boot(cfg,overrides={'WLR_BACKENDS':'x11','DISPLAY':display,'WAYLAND_DISPLAY':None}) as (server,env,work,log):
        sn='X11-1'
        wait(h,env,"return core.box('fitted')~=nil",b'true\n',server)
        settled(h,env,server,sn)
        check(h,env,"local b=core.box('fitted');local r=core.box('root');return b.x>=0 and b.y>=0 and b.x+b.width<=r.width and b.y+b.height<=r.height",b'true\n')
        check(h,env,"local b=core.box('rootfit');local r=core.box('root');return b.x+b.width==r.width and b.y+b.height==r.height",b'true\n')
        before_count=int(h.ev(env,"return COUNTS['X11-1']"))
        change(h,env,server,sn,'FITSIZE=240')
        assert int(h.ev(env,"return COUNTS['X11-1']"))-before_count<=3
        check(h,env,"local b=core.box('fitted');local r=core.box('root');return b.width==240 and b.x>=0 and b.x+b.width<=r.width",b'true\n')
        change(h,env,server,sn,'FITSIZE=130')
        check(h,env,"return ui==require('kiln.ui'),ui.bands.background,ui.bands.overlay,type(ui.widget)",b'true\t-1000\t5000\tfunction\n')
        windows=subprocess.check_output(['xdotool','search','--name',''],env=env).decode().splitlines();window=windows[-1]
        def xdo(*args):
          subprocess.run(['xdotool',*map(str,args)],env=env,check=True,timeout=5);time.sleep(.08)
        def point(x,y): xdo('mousemove','--window',window,x,y)
        xdo('windowfocus',window)
        first=screenshot(env,work/'ui-before.png',sn)
        check(h,env,"local ok=pcall(ui.box,{id={'row',1},on_press=function() BAD=BAD+1 end});return ok",b'false\n')
        point(60,100);xdo('click',1)
        check(h,env,'return P,R,LAST,OUTER,ENTER>0',b'1\t1\t1\t0\ttrue\n')
        point(360,300);check(h,env,'return LEAVE>0',b'true\n')
        point(60,100);xdo('click',5);settled(h,env,server,sn)
        check(h,env,"return core.box({'scroll:content',1}).y-core.box({'scroll',1}).y",b'-60\n')
        xdo('click','--repeat',12,'--delay',30,5);settled(h,env,server,sn)
        check(h,env,"return core.box({'scroll:content',1}).y-core.box({'scroll',1}).y,core.box({'scroll:content',2}).y-core.box({'scroll',2}).y",b'-280\t0\n')
        check(h,env,"for _,v in ipairs(core.hits('X11-1',60,100)) do if v.name=='row' then return v.index end end",b'8\n')
        screenshot(env,work/'ui-scrolled.png',sn)
        change(h,env,server,sn,'N=2')
        check(h,env,"return core.box({'scroll:content',1}).y-core.box({'scroll',1}).y",b'0\n')
        xdo('click',4);settled(h,env,server,sn)
        check(h,env,"return core.box({'scroll:content',1}).y-core.box({'scroll',1}).y",b'0\n')
        for failure in ['FAIL','HUGE']:
          before=screenshot(env,work/(failure+'-before.png'),sn)
          change(h,env,server,sn,failure+'=true;REPLACE=true')
          assert screenshot(env,work/(failure+'-after.png'),sn).tobytes()==before.tobytes()
          old=int(h.ev(env,'return P'));point(60,100);xdo('click',1)
          check(h,env,'return P,BAD',f'{old+1}\t0\n'.encode())
          change(h,env,server,sn,failure+'=false;REPLACE=false')
          assert stats(log,sn)[:2]==(0,0),stats(log,sn)
        change(h,env,server,sn,'THROW=true')
        xdo('click',1);check(h,env,'return ERR',b'1\n')
        point(430,70);xdo('click',1);check(h,env,'return FLOAT',b'1\n')
        change(h,env,server,sn,'NOFLOAT=true')
        xdo('click',1);check(h,env,'return FLOAT',b'11\n')
        # Native surfaces keep their overhang beyond a clipping parent.
        with (work/'wev.log').open('w') as output:
          client=subprocess.Popen(['stdbuf','-oL','wev'],env=env,stdout=output,stderr=output)
          try:
            wait(h,env,'return #client.all()',b'1\n',server);settled(h,env,server,sn)
            check(h,env,"BP=0;K.button{button=1,press=function(c) assert(c==client.all()[1]);BP=BP+1 end}",b'\n')
            point(750,350);start=len((work/'wev.log').read_text());xdo('click',1);xdo('click',5)
            received=(work/'wev.log').read_text()[start:]
            assert received.count('wl_pointer] button:')==2,received
            assert 'wl_pointer] axis:' in received,received
            check(h,env,'return BP',b'1\n')
            change(h,env,server,sn,'SHOWOVER=true')
            start=len((work/'wev.log').read_text())
            xdo('click',1)
            assert 'wl_pointer] button:' not in (work/'wev.log').read_text()[start:], 'stale native focus under newly painted chrome'
            check(h,env,'return BP,FLOAT',b'1\t111\n')
            xdo('click',5)
            assert 'wl_pointer] axis:' not in (work/'wev.log').read_text()[start:]
            change(h,env,server,sn,'OVERCLIP=true')
            start=len((work/'wev.log').read_text());xdo('click',1);xdo('click',5)
            assert (work/'wev.log').read_text()[start:].count('wl_pointer] button:')==2
            assert 'wl_pointer] axis:' in (work/'wev.log').read_text()[start:]
            check(h,env,'return BP,FLOAT',b'2\t111\n')
            change(h,env,server,sn,'SHOWOVER=false')
            start=len((work/'wev.log').read_text());xdo('click',1)
            assert (work/'wev.log').read_text()[start:].count('wl_pointer] button:')==2
            check(h,env,'return BP',b'3\n')
          finally:
            client.terminate();client.wait(timeout=5)
        wait(h,env,'return #client.all()',b'0\n',server)
        foot=subprocess.Popen(['foot','--title=SESSION-06','sh','-c',"printf '\\033[?25l\\n  Session 6\\n  Images, clips, scroll, floats\\n'; exec sleep 120"],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
          wait(h,env,'return #client.all()',b'1\n',server);settled(h,env,server,sn)
          change(h,env,server,sn,'N=10;THROW=false')
          point(60,100);xdo('click',5);settled(h,env,server,sn)
          screenshot(env,work/'ui-foot.png',sn)
          for _ in range(2):
            change(h,env,server,sn,'')
            assert stats(log,sn)[:2]==(0,0),stats(log,sn)
          h.quit(server,env,log)
          assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
        finally:
          if foot.poll() is None: foot.terminate()
          foot.wait(timeout=5)
    print('PASS: native Xvfb wheel/button/hover, nested handlers, clipped rows, shrink/clamp, fit, failed handlers/rasters, client overhang/input, cleanup:',work.resolve())
    multiple(h,cfg)

def multiple(h,cfg):
    with h.boot(cfg,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
      wait(h,env,"return COUNTS['HEADLESS-2']~=nil",b'true\n',server)
      settled(h,env,server,'HEADLESS-1')
      # Synthetic dispatch isolates same/indexed IDs across outputs, using live Clay hits.
      check(h,env,"local x,y;for _,o in ipairs(core.output.list()) do if o.name=='HEADLESS-1' then x,y=o.x,o.y end end;require('kiln.ui_input'){name='axis',screen='HEADLESS-1',x=x+60,y=y+100,dy=15}",b'\n')
      settled(h,env,server,'HEADLESS-1')
      check(h,env,"core.hits('HEADLESS-1',60,100);local a=core.box({'scroll:content',1}).y-core.box({'scroll',1}).y;core.hits('HEADLESS-2',1340,100);return a,core.box({'scroll:content',1}).y-core.box({'scroll',1}).y",b'-60\t0\n')
      for sn in ['HEADLESS-2','HEADLESS-1']*2:
        change(h,env,server,sn,'');assert stats(log,sn)[:2]==(0,0)
      h.quit(server,env,log)
    print('PASS: synthetic-only interleaved output handler/scroll isolation')

if __name__=='__main__':
 spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py')
 compat=importlib.util.module_from_spec(spec);spec.loader.exec_module(compat)
 out=Path(tempfile.mkdtemp(prefix='ui-',dir=ROOT/'build/verification'))
 with tempfile.TemporaryDirectory(prefix='ko-ui-') as short:
  alias=Path(short)/'e';alias.symlink_to(out,target_is_directory=True)
  run(compat.Harness(ROOT/'build/kiln',c_baseline.source(),alias))
