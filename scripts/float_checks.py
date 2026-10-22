"""Public floating attachments, Clay paint order and live hit order."""
import c_baseline
import importlib.util
import tempfile
from pathlib import Path
from declaration_checks import check, wait
from paint_checks import ROOT, box, screenshot, pixel, update
CONFIG=r'''
COUNTS={};PASS=true;INHERIT=true;SWAP=false;KIND=false
function floating(sn,w,h)
 COUNTS[sn]=(COUNTS[sn] or 0)+1
 core.open({id='root',layout={sizing={width=w,height=h}},backgroundColor={r=0,g=0,b=0}})
 core.open({id='lower',layout={sizing={width=200,height=200}},backgroundColor={r=200,g=0,b=0}});core.close()
 core.open({id={'target',7},layout={sizing={width=100,height=80}},floating={attachTo='root',offset={x=40,y=40},zIndex=1},clip={horizontal=true}})
 core.open({id='parent',layout={sizing={width=150,height=120}},floating={attachTo='parent',offset={x=20,y=20},zIndex=2,clipTo=INHERIT and 'attached_parent' or 'none',pointerCaptureMode=PASS and 'passthrough' or 'capture'},backgroundColor={r=0,g=200,b=0}});core.close();core.close()
 for _,name in ipairs(SWAP and {'b','a'} or {'a','b'}) do
  core.open({id=name,layout={sizing={width=60,height=50}},backgroundColor=name=='a' and {r=0,g=0,b=255} or {r=255,g=255,b=0},
   cornerRadius=KIND and {topLeft=5} or nil,
   floating={attachTo='element',parentId={'target',7},attachPoints={parent='right_bottom',element='left_top'},offset={x=100,y=0},zIndex=3,pointerCaptureMode='passthrough'}});core.close()
 end
 core.open({id='negative',layout={sizing={width=100,height=100}},backgroundColor={r=255,g=0,b=255},floating={attachTo='root',zIndex=-1}});core.close()
 core.open({id='expand',layout={sizing={width=20,height=20}},floating={attachTo='root',offset={x=400,y=100},expand={width=5,height=10}}});core.close()
 core.close()
end
core.set_frame_handler(floating)
'''
def run(h):
 with h.boot(CONFIG) as (server,env,work,log):
  wait(h,env,"return core.box('b')~=nil",b'true\n',server)
  assert box(h,env,'parent')==(60,60,150,120)
  assert box(h,env,'a')==(240,120,60,50)
  assert box(h,env,'expand')==(395,90,30,40)
  im=screenshot(env,work/'floats.png')
  pixel(im,(0,0,0,0),10,10,(200,0,0));pixel(im,(0,0,0,0),70,150,(200,0,0));pixel(im,(0,0,0,0),145,150,(200,0,0))
  pixel(im,box(h,env,'a'),30,20,(255,255,0))
  check(h,env,"return core.hits('HEADLESS-1',70,150)[1].name",b'lower\n')
  check(h,env,"return core.hits('HEADLESS-1',145,150)[1].name",b'lower\n')
  check(h,env,"return core.hits('HEADLESS-1',250,130)[1].name,core.hits('HEADLESS-1',250,130)[2].name",b'b\ta\n')
  assert update(h,env,server,log)[:2]==(0,0)
  update(h,env,server,log,'SWAP=true;KIND=true')
  pixel(screenshot(env,work/'reorder.png'),box(h,env,'a'),30,20,(0,0,255))
  check(h,env,"return core.hits('HEADLESS-1',250,130)[1].name",b'a\n')
  update(h,env,server,log,'PASS=false')
  check(h,env,"for _,v in ipairs(core.hits('HEADLESS-1',70,70)) do if v.name=='lower' then return false end end;return true",b'true\n')
  check(h,env,"return core.hits('HEADLESS-1',145,150)[1].name",b'lower\n')
  update(h,env,server,log,'INHERIT=false')
  check(h,env,"return core.hits('HEADLESS-1',145,150)[1].name",b'parent\n')
  pixel(screenshot(env,work/'escaped.png'),(0,0,0,0),145,150,(0,200,0))
  assert update(h,env,server,log)[:2]==(0,0)
  h.quit(server,env,log)
 print('PASS: parent/root/indexed attachment, expand, negative/equal z, kind/reorder, capture/passthrough and inherited axis clip:',work.resolve())
if __name__=='__main__':
 spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py')
 compat=importlib.util.module_from_spec(spec);spec.loader.exec_module(compat)
 out=Path(tempfile.mkdtemp(prefix='floats-',dir=ROOT/'build/verification'))
 with tempfile.TemporaryDirectory(prefix='ko-floats-') as short:
  alias=Path(short)/'e';alias.symlink_to(out,target_is_directory=True)
  run(compat.Harness(ROOT/'build/kiln',c_baseline.source(),alias))
