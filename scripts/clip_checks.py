"""Scale-one clip pixels, solved boxes, retained crops and Pango bounds."""
import c_baseline
import importlib.util
import tempfile
from pathlib import Path
from PIL import Image
from declaration_checks import check, wait
from paint_checks import ROOT, box, screenshot, pixel, update

CONFIG = r'''
COUNTS={}; CW=70; OFF=-20; AX='h'; E=true; SHOW=true; WM='none';TXT='Héllo λ 世界 WWW long text that truncates'
function clipped(sn,w,h)
 COUNTS[sn]=(COUNTS[sn] or 0)+1
 core.open({id='root',layout={sizing={width=w,height=h},layoutDirection='ttb',padding={left=30,top=30},childGap=100},backgroundColor={r=0,g=0,b=0}})
 for i,kind in ipairs{'fill','image','border','text'} do
  core.open({id='clip-'..kind,layout={sizing={width=CW,height=30}},clip=SHOW and {horizontal=AX~='v',vertical=AX~='h',childOffset={x=OFF,y=0}} or nil})
  core.open({id=kind,layout={sizing={width=200,height=70}},
   backgroundColor=kind=='fill' and {r=255,g=0,b=0} or nil,
   image=kind=='image' and {path=IMAGE} or nil,
   border=kind=='border' and {color={r=0,g=255,b=0},width={left=4,right=4,top=4,bottom=4}} or nil,
   cornerRadius=kind=='border' and {topLeft=16,topRight=16,bottomLeft=16,bottomRight=16} or nil})
  if kind=='text' then core.text(TXT,{fontSize=22,textColor={r=255,g=255,b=255},wrapMode=WM,ellipsize=E}) end
  core.close();core.close()
 end
 core.close()
end
core.set_frame_handler(clipped)
'''

def run(h):
    asset=h.out/'crop.png'
    image=Image.new('RGBA',(200,70),(0,0,255,255))
    for x in range(100,200):
        for y in range(70): image.putpixel((x,y),(255,255,0,255))
    image.save(asset)
    import json
    with h.boot('IMAGE='+json.dumps(str(asset))+'\n'+CONFIG) as (server,env,work,log):
        wait(h,env,"return core.box('text')~=nil",b'true\n',server)
        original=box(h,env,'text')
        first=screenshot(env,work/'horizontal.png')
        for kind,color in [('fill',(255,0,0)),('image',(0,0,255)),('border',(0,255,0))]:
            b=box(h,env,'clip-'+kind)
            pixel(first,b,-1,1,(0,0,0));pixel(first,b,1,1,color);pixel(first,b,69,1,color);pixel(first,b,70,1,(0,0,0))
        pixel(first,box(h,env,'clip-fill'),10,50,(255,0,0))
        check(h,env,"local a=core.hits('HEADLESS-1',40,80);for _,v in ipairs(a) do if v.name=='fill' then return true end end;return false",b'false\n')
        assert update(h,env,server,log)[:2]==(0,0)
        update(h,env,server,log,'CW=50')
        narrow=screenshot(env,work/'narrow.png')
        assert box(h,env,'text')==original
        assert first.crop((30,420,80,450)).tobytes()!=narrow.crop((30,420,80,450)).tobytes()
        st=update(h,env,server,log,'E=false;OFF=-40')
        assert st[1]==1,st
        st=update(h,env,server,log,'OFF=-60')
        assert st[1]==0,st
        for ax in ['v','both']:
            update(h,env,server,log,"AX='"+ax+"';CW=70;OFF=0")
            im=screenshot(env,work/(ax+'.png'))
            b=box(h,env,'clip-fill')
            pixel(im,b,10,29,(255,0,0));pixel(im,b,10,30,(0,0,0))
            pixel(im,b,100,10,(255,0,0) if ax=='v' else (0,0,0))
        update(h,env,server,log,'SHOW=false')
        plain=screenshot(env,work/'unclipped.png')
        update(h,env,server,log,'E=true')
        assert screenshot(env,work/'no-bound.png').tobytes()==plain.tobytes()
        for mode in ['none','words','newlines']:
            update(h,env,server,log,"WM='"+mode+"';SHOW=true;AX='h';TXT='Hi';OFF=0;E=false")
            fitting=screenshot(env,work/('fit-'+mode+'.png'))
            update(h,env,server,log,'E=true')
            assert screenshot(env,work/('fit-ellipsis-'+mode+'.png')).tobytes()==fitting.tobytes()
        update(h,env,server,log,"WM='none';TXT='Héllo λ 世界 WWW long text that truncates';SHOW=true;AX='h';CW=70;OFF=-20")
        assert screenshot(env,work/'restored.png').tobytes()==first.tobytes()
        check(h,env,"core.set_frame_handler(function() core.open({clip={horizontal=true}});core.text('failed',{ellipsize=true});error('staged clip') end);core.dirty()",b'\n')
        import time
        time.sleep(.1)
        assert screenshot(env,work/'failed.png').tobytes()==first.tobytes()
        assert update(h,env,server,log,'core.set_frame_handler(clipped)')[:2]==(0,0)
        h.quit(server,env,log)
        assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
    nested(h,asset)
    print('INHERITED CLAY: visible horizontal child misses; nested outer x clip does not constrain hits. Pixel masks and all other hits remain asserted.')
    print('PASS: axis clips, image source crops, border tiles, UTF-8 ellipsis, retained pixels, failed-frame recovery:',work.resolve())


def nested(h,asset):
    import json
    cfg=r"""
COUNTS={};CLIP=false;X=0
core.set_frame_handler(function(sn,w,h)
 COUNTS[sn]=(COUNTS[sn] or 0)+1
 core.open({layout={sizing={width=w,height=h},layoutDirection='ttb',padding={left=35,top=25},childGap=100},backgroundColor={r=0,g=0,b=0}})
 for _,kind in ipairs{'fill','image','border','text'} do
  core.open({id='outer-'..kind,layout={sizing={width=70,height=30}},clip={horizontal=CLIP,childOffset={x=X}}})
  core.open({layout={sizing={width=180,height=30}},clip={vertical=CLIP}})
  core.open({id='nested-'..kind,layout={sizing={width=200,height=70}},
   image=kind=='image' and {path=IMAGE} or nil,
   backgroundColor=kind=='fill' and {r=255,g=0,b=0} or nil,
   border=kind=='border' and {color={r=0,g=255,b=0},width={left=4,right=4,top=4,bottom=4}} or nil,
   cornerRadius=kind=='border' and {topLeft=16,topRight=16,bottomLeft=16,bottomRight=16} or nil})
  if kind=='text' then core.text('Nested clipping λ 世界',{fontSize=24,textColor={r=255,g=255,b=255},wrapMode='none'}) end
  core.close();core.close();core.close()
 end
 core.close()
end)
"""
    with h.boot('IMAGE='+json.dumps(str(asset))+'\n'+cfg) as (server,env,work,log):
        wait(h,env,"return core.box('nested-text')~=nil",b'true\n',server)
        base=screenshot(env,work/'nested-controls.png')
        boxes={k:box(h,env,'nested-'+k) for k in ['fill','image','border','text']}
        update(h,env,server,log,'CLIP=true')
        clipped=screenshot(env,work/'nested-intersection.png')
        for kind,b in boxes.items():
            assert box(h,env,'nested-'+kind)==b
            for y in range(70):
                for x in range(200):
                    want=base.getpixel((b[0]+x,b[1]+y)) if x<70 and y<30 else (0,0,0)
                    assert clipped.getpixel((b[0]+x,b[1]+y))==want,(kind,x,y)
            check(h,env,f"for _,v in ipairs(core.hits('HEADLESS-1',{b[0]+80},{b[1]+10})) do if v.name=='nested-{kind}' then return false end end;return true",b'false\n')
            check(h,env,f"for _,v in ipairs(core.hits('HEADLESS-1',{b[0]+10},{b[1]+40})) do if v.name=='nested-{kind}' then return false end end;return true",b'true\n')
        st=update(h,env,server,log,'X=90')
        assert st[1]==0,st
        empty=screenshot(env,work/'empty-intersection.png')
        assert empty.getbbox() is None
        check(h,env,"return core.hits('HEADLESS-1',40,30)[1].name",b'outer-fill\n')
        update(h,env,server,log,'X=0;CLIP=false')
        assert screenshot(env,work/'nested-restored.png').tobytes()==base.tobytes()
        h.quit(server,env,log)
    print('PASS: nested mixed-axis and empty intersection pixel masks across fill/image/border/text:',work.resolve())

if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py')
    compat=importlib.util.module_from_spec(spec);spec.loader.exec_module(compat)
    out=Path(tempfile.mkdtemp(prefix='clips-',dir=ROOT/'build/verification'))
    with tempfile.TemporaryDirectory(prefix='ko-clips-') as short:
        alias=Path(short)/'e';alias.symlink_to(out,target_is_directory=True)
        run(compat.Harness(ROOT/'build/kiln',c_baseline.source(),alias))
