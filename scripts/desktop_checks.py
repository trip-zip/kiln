"""Stock desktop flow and transactional declaration checks on private outputs."""
import c_baseline
import importlib.util
import tempfile
from pathlib import Path
from declaration_checks import check, wait, settle, capture
from paint_checks import ROOT
from window_state_checks import launch, stop, counts
import time

CONFIG = '''
K=require("kiln");ui=K.ui
screen.on("added",function(s)
 tag.new{name="one",screen=s}
 ui.bar(s,{edge="left",w=40},function()
  ui.box({id="cell1",w=24,h=24,color="#ff0000"})
  ui.box({id="cell2",w=24,h=24,color="#00ff00"})
  for _,dir in ipairs{"column","ttb"} do
   ui.box({dir=dir},function()
    ui.box({id=dir.."1",w=10,h=10})
    ui.box({id=dir.."2",w=10,h=10})
   end)
  end
 end)
end)
'''
def run(h):
    with h.boot(CONFIG, overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        def ev(src): check(h,env,'do '+src+' end',b'\n')
        wait(h,env,"return screen.all()[1].workarea~=nil",b'true\n',server)
        settle(log)
        ev('''for _,s in ipairs(screen.all()) do
          core.hits(s.name,s.x+2,s.y+s.height/2)
          local b,a,c=core.box({"bar",1}),core.box("cell1"),core.box("cell2")
          assert(b.x==0 and b.width==40 and b.height==s.height)
          local wa=s.workarea
          assert(wa.x==40 and wa.width==s.width-40 and wa.y==0 and wa.height==s.height)
          assert(a.x==c.x and c.y-a.y-a.height==6 and a.y-b.y==8)
          assert(a.x-b.x==(b.width-a.width)/2)
          for _,dir in ipairs{"column","ttb"} do
           local x,y=core.box(dir.."1"),core.box(dir.."2")
           assert(x.x==y.x and y.y==x.y+x.height)
          end
        end''')
        capture(env,work/'left.png')
        ev('''for _,s in ipairs(screen.all()) do
          ui.bar(s,{edge="top",h=30},function() ui.text("top") end)
          ui.bar(s,{edge="bottom",h=20},function() ui.text("bottom") end)
          ui.bar(s,{edge="right",w=50},function() ui.text("R") end)
          ui.bar(s,{edge="top",h=25},function() ui.text("second top") end)
        end''')
        settle(log)
        ev('''for _,s in ipairs(screen.all()) do
          local w=s.workarea
          assert(w.x==40 and w.y==55 and w.width==s.width-90 and w.height==s.height-75)
        end''')
        capture(env,work/'four-edges.png')
        p,f=launch(env,work,'EDGES')
        try:
            wait(h,env,'return #client.all()',b'1\n',server)
            for n in (1,2):
                ev(f'c=client.all()[1];s=screen.all()[{n}];c.tag=s.tags[1];core.dirty()')
                settle(log)
                ev('''core.hits(s.name,s.x,s.y);local b=core.box({'client',c.handle});local w=s.workarea
                  assert(b.x==w.x+8 and b.y==w.y+8 and b.width==w.width-16 and b.height==w.height-16)
                  assert(c.width==b.width-4 and c.height==b.height-26)''')
            capture(env,work/'four-edges-foot.png')
            # Band precedence orders the reservation fold; all dimensions remain Clay flow.
            ev('''ui.bar(s,{edge='top',band='below',h=11,pad=0,clip={vertical=true}},function()
              ui.box{id='short-child',w=40,h=40,color='#ff00ff',on_press=function()SHORT=true end}
            end)''')
            settle(log)
            ev('''core.hits(s.name,s.x,s.y);local bar=core.box({'bar',6});local b=core.box('short-child')
              assert(bar.y==55 and bar.height==11 and b.height==40 and s.workarea.y==66)
              local inside,outside=false,false
              for _,h in ipairs(core.hits(s.name,s.x+b.x+2,s.y+bar.y+2))do if h.name=='short-child' then inside=true end end
              for _,h in ipairs(core.hits(s.name,s.x+b.x+2,s.y+bar.y+20))do if h.name=='short-child' then outside=true end end
              assert(inside and not outside)''')
            capture(env,work/'short-bar-clipped.png')
            before=counts(log);time.sleep(.3);assert counts(log)==before
        finally:stop(p);f.close()
        h.quit(server,env,log)
    print('PASS: original bar geometry assertions, multiple bars/four edges/two outputs:',work.resolve())

if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py')
    compat=importlib.util.module_from_spec(spec);spec.loader.exec_module(compat)
    out=Path(tempfile.mkdtemp(prefix='desktop-',dir=ROOT/'build/verification'))
    with tempfile.TemporaryDirectory(prefix='ko-desktop-') as short:
        alias=Path(short)/'e';alias.symlink_to(out,target_is_directory=True)
        run(compat.Harness(ROOT/'build/kiln',c_baseline.source(),alias))
