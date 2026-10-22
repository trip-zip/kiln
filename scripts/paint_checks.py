"""Focused paint-test font/shape assertions and retained scale-one raster checks."""
import c_baseline
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from PIL import Image, ImageChops
from declaration_checks import check, wait

ROOT = Path(__file__).resolve().parents[1]
CONFIG = r'''
local kiln=require('kiln')
screen.on('added',function(s) if #s.tags==0 then tag.new{name='paint',screen=s} end end)
local grow={type='grow'}
local white={r=255,g=255,b=255}
TEXT='Handgloves WWW iii'; FONT=core.font('Sans'); SIZE=18; COLOR=white
RADIUS=24; BW=3; SHAPESIZE=140; OFFSET=0; SHOW=true; COUNTS={}
BOLD=core.font('Sans Bold'); MONO=core.font('Monospace'); MISSING=core.font('NoSuchFamilyXYZ')
function leaf(id,text,font,size,extra)
  core.open({id=id})
  local cfg={fontId=font,fontSize=size,textColor=white,wrapMode='none'}
  for k,v in pairs(extra or {}) do cfg[k]=v end
  core.text(text,cfg);core.close()
end
function cell(id,text,font,size,extra)
  core.open({layout={sizing={width=290,height=60}}})
  leaf(id,text,font,size,extra);core.close()
end
function paint_frame(sn,w,h)
 COUNTS[sn]=(COUNTS[sn] or 0)+1
 core.open({id='root',layout={sizing={width=grow,height=grow},layoutDirection='ttb',
   padding={left=16,right=16,top=16,bottom=16},childGap=12},backgroundColor={r=0,g=0,b=0}})
 core.open({id='shapes',layout={sizing={width=grow,height=90},childGap=20}})
 core.open({id='disc',layout={sizing={width=40,height=40}},backgroundColor=white,
   cornerRadius={topLeft=20,topRight=20,bottomLeft=20,bottomRight=20}});core.close()
 core.open({id='ring',layout={sizing={width=40,height=40}},cornerRadius={topLeft=20,topRight=20,bottomLeft=20,bottomRight=20},
   border={color=white,width={left=3,right=3,top=3,bottom=3}}});core.close()
 core.open({id='asym',layout={sizing={width=SHAPESIZE,height=70}},backgroundColor={r=40,g=100,b=160},
   cornerRadius={topLeft=RADIUS,topRight=RADIUS/2,bottomLeft=0,bottomRight=RADIUS/3},
   border={color={r=240,g=150,b=40},width={left=BW,right=BW*2,top=BW+1,bottom=BW+2}}});core.close()
 core.open({id='alpha',layout={sizing={width=60,height=60}},backgroundColor={r=240,g=120,b=60,a=128}});core.close()
 core.open({id='alpha-round',layout={sizing={width=60,height=60}},backgroundColor={r=240,g=120,b=60,a=128},
   cornerRadius={topLeft=20,topRight=20,bottomLeft=20,bottomRight=20}});core.close()
 core.open({id='thin',layout={sizing={width=400,height=70}},cornerRadius={topLeft=14,topRight=14,bottomLeft=14,bottomRight=14},
   border={color={r=80,g=220,b=170},width={left=2,right=2,top=2,bottom=2}}});core.close()
 core.close()
 core.open({layout={sizing={width=grow,height=60}}})
 cell('reg','Handgloves WWW iii',0,18);cell('same','Handgloves WWW iii',core.font('Sans'),18)
 cell('bold','Handgloves WWW iii',BOLD,18)
 cell('dynamic',TEXT,FONT,SIZE,{textColor=COLOR})
 core.close()
 core.open({layout={sizing={width=grow,height=60}}})
 cell('mono','Handgloves WWW iii',MONO,18);cell('fallback','Handgloves WWW iii',65535,18)
 cell('missing','Handgloves WWW iii',MISSING,18);cell('utf8','Héllo λ 世界',0,18)
 core.close()
 core.open({layout={sizing={width=grow,height=125},childGap=24}})
 core.open({id='wrap',layout={sizing={width=130,height={type='fit'}}}})
 core.text('Words wrap across several lines',{fontSize='18',textColor=white,wrapMode='words'});core.close()
 for _,a in ipairs{'left','center','right'} do
   core.open({id=a,layout={sizing={width=180,height={type='fit'}}}})
   core.text('Wide words here\nHi',{fontSize=18,textColor=white,wrapMode='newlines',lineHeight=30,textAlignment=a});core.close()
 end
 core.open({id='between',layout={sizing={width=120,height=90},layoutDirection='ttb',childGap=10},
   border={color=white,width={betweenChildren=2}}})
 for i=1,3 do core.open({id={'child',i},layout={sizing={width=120,height=20}}});core.close() end
 core.close()
 leaf('empty','',0,16);leaf('numeric',12345,0,'16')
 core.close()
 core.open({layout={sizing={width=grow,height=40},padding={left=OFFSET}}})
 if SHOW then leaf('moving','Moves without a new raster',0,18) end
 core.close()
 core.open({id='client-frame',layout={sizing={width=grow,height=grow}},
   cornerRadius={topLeft=24,topRight=8,bottomLeft=0,bottomRight=16},
   border={color={r=80,g=220,b=170},width={left=3,right=6,top=4,bottom=8}}})
 if screen.all()[1] then
  for _,c in ipairs(kiln.visible_clients(screen.all()[1])) do core.surface(c.handle) end
 end
 core.close();core.close();collectgarbage('collect')
end
core.set_frame_handler(paint_frame)
'''


def box(h, env, name, screen='HEADLESS-1'):
    src = f"core.hits('{screen}',0,0);local b=core.box('{name}');return b.x,b.y,b.width,b.height"
    return tuple(map(int, h.ev(env, src).split()))


def screenshot(env, path, output='HEADLESS-1'):
    subprocess.run(['grim', '-o', output, str(path)], env=env, check=True, timeout=5)
    return Image.open(path).convert('RGB')


def crop(im, b):
    x,y,w,h=b
    return im.crop((x,y,x+w,y+h))


def pixel(im,b,x,y,expected,tolerance=2):
    value=im.getpixel((b[0]+x,b[1]+y))
    assert all(abs(a-b)<=tolerance for a,b in zip(value,expected)), (b,x,y,value,expected)


def stats(log, output='HEADLESS-1'):
    rows=re.findall(r'Paint '+output+r': mutations (\d+), rasters (\d+), nodes (\d+), bytes (\d+), live buffers (\d+), live bytes (\d+)',log.read_text())
    assert rows, log.read_text()
    return tuple(map(int,rows[-1]))


def update(h,env,server,log,source='',output='HEADLESS-1'):
    count=int(h.ev(env,f"return COUNTS['{output}']"))
    check(h,env,source+f";core.dirty('{output}')",b'\n')
    wait(h,env,f"return COUNTS['{output}']",f'{count+1}\n'.encode(),server)
    return stats(log,output)


def run(h):
    with h.boot(CONFIG) as (server,env,work,log):
        wait(h,env,"return core.box('ring')~=nil",b'true\n',server)
        for expression,expected in [
            ("return type(core.font('Sans Bold'))",b'number\n'),
            ("return core.font('Sans Bold')==core.font('Sans Bold'),core.font('Sans')",b'true\t0\n'),
            ("local ok,e=pcall(core.font,'Sans Bold 14');return not ok and e:match('size')~=nil",b'true\n'),
            ("return type(core.font('NoSuchFamilyXYZ'))",b'number\n'),
            ("return pcall(core.font,42)",None),
        ]:
            if expected is None: assert h.ev(env,expression).startswith(b'false\t')
            else: check(h,env,expression,expected)
        names=['disc','ring','asym','alpha','alpha-round','thin','reg','same','bold','dynamic','mono','fallback','missing','utf8','wrap','left','center','right','between','empty','numeric','moving','client-frame']
        boxes={n:box(h,env,n) for n in names}
        (work/'boxes.json').write_text(json.dumps(boxes,indent=2))
        assert boxes['bold'][2]>boxes['reg'][2]
        assert boxes['reg'][2:]==boxes['same'][2:]==boxes['fallback'][2:]
        assert boxes['mono'][2]!=boxes['reg'][2]
        assert boxes['empty'][2]==0 and boxes['numeric'][2]>0
        assert boxes['wrap'][3]>boxes['reg'][3]*2
        assert boxes['left'][3]==boxes['center'][3]==boxes['right'][3]==60
        initial=screenshot(env,work/'paint.png')
        for n,x,y,color in [('disc',20,20,(255,255,255)),('disc',2,2,(0,0,0)),
                            ('ring',20,1,(255,255,255)),('ring',20,8,(0,0,0)),
                            ('ring',20,20,(0,0,0)),('ring',2,2,(0,0,0)),
                            ('asym',1,1,(0,0,0)),('asym',70,1,(240,150,40)),
                            ('asym',70,30,(40,100,160)),('asym',1,40,(240,150,40)),
                            ('asym',70,68,(240,150,40)),('thin',200,30,(0,0,0)),
                            ('thin',200,1,(80,220,170)),('alpha',30,30,(120,60,30)),
                            ('alpha-round',30,30,(120,60,30)),('alpha-round',1,1,(0,0,0)),
                            ('between',60,24,(255,255,255)),('between',60,26,(0,0,0))]:
            pixel(initial,boxes[n],x,y,color)
        for n in ['same','fallback','missing','dynamic']:
            assert crop(initial,boxes[n]).tobytes()==crop(initial,boxes['reg']).tobytes(),n
        assert crop(initial,boxes['mono']).tobytes()!=crop(initial,boxes['reg']).tobytes()
        assert crop(initial,boxes['bold']).tobytes()!=crop(initial,boxes['reg']).tobytes()
        # The second line is short, so each alignment moves its painted extent.
        starts=[]
        for n in ['left','center','right']:
            im=crop(initial,boxes[n]).crop((0,30,180,60))
            extent=im.getbbox(); assert extent is not None
            starts.append(extent[0])
        assert starts[0]<starts[1]<starts[2],starts
        for _ in range(3):
            assert update(h,env,server,log)[:2]==(0,0)
        # Every content property changes independently; static siblings remain byte-identical.
        for i,source in enumerate(["TEXT='A shorter string'", "TEXT='Handgloves WWW iii'", 'FONT=BOLD',
                                   'FONT=0', 'SIZE=24','SIZE=18', 'COLOR={r=230,g=100,b=50}',
                                   'COLOR={r=255,g=255,b=255}', 'RADIUS=0','RADIUS=24',
                                   'BW=8','BW=3','SHAPESIZE=160','SHAPESIZE=140']):
            st=update(h,env,server,log,source)
            assert st[0]>0 and (st[1]==0 if source=='RADIUS=0' else st[1]>0),(source,st)
            current=screenshot(env,work/f'change-{i:02d}.png')
            assert crop(current,boxes['reg']).tobytes()==crop(initial,boxes['reg']).tobytes(),source
            if source in ['FONT=BOLD','FONT=0']:
                control='bold' if source=='FONT=BOLD' else 'reg'
                assert box(h,env,'dynamic')[2:]==boxes[control][2:]
                assert crop(current,box(h,env,'dynamic')).tobytes()==crop(initial,boxes[control]).tobytes()
            assert update(h,env,server,log)[:2]==(0,0)
        restored=screenshot(env,work/'restored.png')
        assert restored.tobytes()==initial.tobytes(), 'stale pixels after restoring content'
        st=update(h,env,server,log,'OFFSET=90')
        assert st[0]>0 and st[1]==0,st
        moved=screenshot(env,work/'moved.png')
        assert crop(moved,box(h,env,'moving')).tobytes()==crop(initial,boxes['moving']).tobytes()
        assert crop(moved,boxes['moving']).getpixel((0,0))==(0,0,0)
        update(h,env,server,log,'OFFSET=0')
        baseline=stats(log)
        for i in range(60):
            st=update(h,env,server,log,f"TEXT='dynamic {i}';collectgarbage('collect')")
            assert st[4]<=baseline[4] and st[5]<baseline[5]+10000,st
        update(h,env,server,log,"TEXT='Handgloves WWW iii'")
        removed=update(h,env,server,log,'SHOW=false')
        assert removed[4]<baseline[4]
        update(h,env,server,log,'SHOW=true')
        assert stats(log)[2:]==baseline[2:]
        # Staged text, validation and resource failure all preserve the published frame.
        for i,body in enumerate([
            "core.text('staged');collectgarbage('collect');error('after text')",
            "core.text('staged');core.open({border={width={left=-1}}})",
            "core.text('staged');core.text('bad',{wrapMode=9})",
            "core.text('staged',{textColor={r=255}});core.open({id='huge',layout={sizing={width=100000,height=100000}},backgroundColor={r=255},cornerRadius={topLeft=20}});core.close()",
        ]):
            check(h,env,f'core.set_frame_handler(function() ATTEMPT={i};{body} end);core.dirty()',b'\n')
            wait(h,env,'return ATTEMPT',f'{i}\n'.encode(),server)
            assert screenshot(env,work/f'failed-{i}.png').tobytes()==initial.tobytes()
            assert box(h,env,'reg')==boxes['reg']
            check(h,env,"local b=core.box('ring');for _,v in ipairs(core.hits('HEADLESS-1',b.x+2,b.y+2)) do if v.name=='ring' then return true end end;return false",b'true\n')
            assert update(h,env,server,log,'core.set_frame_handler(paint_frame)')[:2]==(0,0)
        assert 'Raster candidate rejected' in log.read_text()
        foot=subprocess.Popen(['foot','--title=PAINT-FOOT','--font=monospace:size=14','sh','-c',
                               "printf '\\033[?25l\\n  Text, borders and rounded chrome\\n\\n  A real Wayland client beneath a transparent border\\n'; exec sleep 120"],
                              env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            wait(h,env,'return #client.all()',b'1\n',server)
            time.sleep(.25)
            real=screenshot(env,work/'paint-foot.png')
            cb=box(h,env,'client-frame')
            upper=(0,0,1280,cb[1]-8)
            assert real.crop(upper).tobytes()==initial.crop(upper).tobytes(), 'client map erased unchanged chrome'
            for i,source in enumerate(['RADIUS=0','RADIUS=24',"TEXT='Client stays visible'","TEXT='Handgloves WWW iii'"]):
                update(h,env,server,log,source)
                painted=screenshot(env,work/f'paint-foot-change-{i}.png')
                assert crop(painted,boxes['reg']).tobytes()==crop(initial,boxes['reg']).tobytes(), source
                assert painted.getpixel((cb[0]+100,cb[1]+100))==real.getpixel((cb[0]+100,cb[1]+100)), source
            assert painted.crop(upper).tobytes()==initial.crop(upper).tobytes(), 'client frame retained stale chrome'
            pixel(real,cb,100,1,(80,220,170))
            # The center belongs to foot, not a black or opaque border raster.
            center=real.getpixel((cb[0]+cb[2]//2,cb[1]+cb[3]//2))
            assert center not in [(0,0,0),(80,220,170)],center
            before_log=log.read_text().count('Layout ')
            time.sleep(.3)
            assert log.read_text().count('Layout ')==before_log
            assert update(h,env,server,log)[:2]==(0,0)
            h.quit(server,env,log)
            assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
        finally:
            if foot.poll() is None: foot.terminate()
            foot.wait(timeout=5)
    print('PASS: focused paint-test fonts/disc/ring, alpha pixels, wrapping/alignment, mutations, GC, failure recovery and owned cleanup')
    print('Paint screenshots:',work.resolve())
    multiple_outputs(h)


def multiple_outputs(h):
    config=r'''
COUNTS={};F=core.font('Monospace')
core.set_frame_handler(function(sn,w,h)
 COUNTS[sn]=(COUNTS[sn] or 0)+1
 core.open({id='bg',layout={sizing={width={type='grow'},height={type='grow'}}},backgroundColor={r=0,g=0,b=0}})
 core.open({id='fit'});core.text('Same text different outputs',{fontId=sn=='HEADLESS-1' and 0 or F,
 fontSize=sn=='HEADLESS-1' and 16 or 28,textColor={r=255,g=255,b=255}});core.close();core.close()
end)
'''
    with h.boot(config,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        wait(h,env,"return COUNTS['HEADLESS-2']~=nil",b'true\n',server)
        dims={s:box(h,env,'fit',s) for s in ['HEADLESS-1','HEADLESS-2']}
        assert dims['HEADLESS-1'][2]<dims['HEADLESS-2'][2]
        initial={s:screenshot(env,work/(s+'.png'),s).tobytes() for s in dims}
        for _ in range(3):
            for s in dims:
                assert update(h,env,server,log,output=s)[:2]==(0,0)
                assert box(h,env,'fit',s)==dims[s]
                assert screenshot(env,work/(s+'-again.png'),s).tobytes()==initial[s]
        check(h,env,"return COUNTS['HEADLESS-1'],COUNTS['HEADLESS-2']",b'4\t4\n')
        h.quit(server,env,log)
        assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
    print('PASS: independent measurement/raster contexts on two headless outputs')


if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py')
    compat=importlib.util.module_from_spec(spec);spec.loader.exec_module(compat)
    out=Path(tempfile.mkdtemp(prefix='paint-',dir=ROOT/'build/verification'))
    with tempfile.TemporaryDirectory(prefix='ko-paint-') as short:
        alias=Path(short)/'e';alias.symlink_to(out,target_is_directory=True)
        run(compat.Harness(ROOT/'build/kiln',c_baseline.source(),alias))
