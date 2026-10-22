"""Device-density chrome and native fractional buffers, using private outputs."""
import c_baseline
import json
import re
from pathlib import Path
import subprocess
import time
from PIL import Image
from declaration_checks import check,wait,settle
from paint_checks import screenshot,stats
from protocol_client import Client
from window_state_checks import launch,stop
from layer_checks import CONFIG as DESKTOP

CONFIG=r'''
K=require('kiln')
screen.on('added',function(s) if #s.tags==0 then tag.new{name='density',screen=s} end end)
OFFSET=0;SCROLL=-20;COUNTS={};BAD=false
local white={r=255,g=255,b=255};local grow={type='grow'}
local radius={topLeft=14,topRight=9,bottomLeft=4,bottomRight=18}
function density_frame(sn,w,h)
 COUNTS[sn]=(COUNTS[sn] or 0)+1
 core.open({id='root',layout={sizing={width=w,height=h},layoutDirection='ttb',padding={left=15+OFFSET,top=15,right=15,bottom=15},childGap=12},backgroundColor={r=16,g=23,b=32}})
 core.open({id='label'});core.text('Density: Handgloves WWW iii 0123456789',{fontSize=17,textColor=white,wrapMode='none'});core.close()
 core.open({layout={sizing={width=grow,height=65},childGap=15}})
 core.open({id='ring',layout={sizing={width=81,height=61}},cornerRadius=radius,border={color={r=255,g=170,b=60},width={left=3,right=6,top=4,bottom=7}}});core.close()
 core.open({id='picture',layout={sizing={width=81,height=61}},cornerRadius=radius,image={path=IMAGE}});core.close()
 core.open({id='tiles',layout={sizing={width=123,height=61}}})
 for i=1,3 do core.open({id={'tile',i},layout={sizing={width=41,height=61}},backgroundColor=({{r=50,g=170,b=110},{r=60,g=110,b=210},{r=210,g=70,b=100}})[i]});core.close() end
 core.close();core.close()
 core.open({id='clip',layout={sizing={width=179,height=25}},clip={horizontal=true,vertical=true,childOffset={x=SCROLL,y=0}}})
 core.open({id='long',layout={sizing={width=450,height=25}}});core.text('Clipped scrolling and ellipsis at device density',{fontSize=17,textColor=white,wrapMode='none',ellipsize=true});core.close();core.close()
 core.open({id='clients',layout={sizing={width=grow,height=grow}}})
 for _,s in ipairs(screen.all())do if s.name==sn then for _,c in ipairs(K.visible_clients(s))do core.surface(c.handle)end end end
 core.close()
 if BAD then core.open({id={'bad','notanumber'}});core.close() end
 core.close()
end
core.set_frame_handler(density_frame)
'''

def box(h,env,name,output='HEADLESS-1'):
    return tuple(map(float,h.ev(env,f"core.hits('{output}',0,0);local b=core.box('{name}');return b.x,b.y,b.width,b.height").split()))

def run(h):
    protocol(h)
    asset=h.out/'density-image.png'
    im=Image.new('RGB',(81,61))
    for y in range(61):
        for x in range(81):im.putpixel((x,y),((x*13)%256,(y*19)%256,180 if x%2 else 40))
    im.save(asset)
    with h.boot('IMAGE='+json.dumps(str(asset.resolve()))+'\n'+CONFIG,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        def yes(s):wait(h,env,'return '+s,b'true\n',server)
        ev("for _,s in ipairs(screen.all())do if s.name=='HEADLESS-1' then S=s;screen.focused=s end end;core.output.set_position('HEADLESS-1',-301,53);core.output.set_position('HEADLESS-2',1400,0)")
        foot,f=launch(env,work,'DENSITY-FOOT')
        try:
            yes('#client.all()==1');settle(log)
            other=stats(log,'HEADLESS-2');proof=[]
            for scale in [1,1.5,2,1.3,1.5]:
                ev(f'S.scale={scale}');yes(f'math.abs(S.scale-{scale})<1e-6');settle(log)
                rasters=stats(log)[1];assert rasters>0 or scale==1
                image=screenshot(env,work/f'density-{scale}.png')
                # Fixed-size chrome gains device pixels while public boxes stay logical.
                b=box(h,env,'ring');assert b[2:]==(81,61)
                assert stats(log,'HEADLESS-2')==other
                x,y,w,hh=box(h,env,'tiles');edge=lambda v:int(v*scale+.5)
                colors=[(50,170,110),(60,110,210),(210,70,100)]
                for i,color in enumerate(colors):
                    for px in range(edge(int(x)+41*i),edge(int(x)+41*(i+1))):
                        assert image.getpixel((px,edge(y+30)))==color,(scale,px,color,image.getpixel((px,edge(y+30))))
                clip=box(h,env,'clip')
                for py in range(edge(clip[1]),edge(clip[1]+clip[3])):
                    assert image.getpixel((edge(clip[0]+clip[2]),py))==(16,23,32)
                before=stats(log);ev("core.dirty('HEADLESS-1')");settle(log);assert stats(log)[:2]==(0,0)
                proof.append({'scale':scale,'paint':before,'ring':b,'label':box(h,env,'label')})
            assert proof[0]['paint'][3]<proof[1]['paint'][3]<proof[2]['paint'][3]
            rows=re.findall(r'Raster \d+: scale ([\d.]+) origin ([^ ]+) logical (\d+)x(\d+) device (\d+)x(\d+)',log.read_text())
            images={}
            for ss,origin,lw,lh,dw,dh in rows:
                scale=float(ss);lw,lh,dw,dh=map(int,(lw,lh,dw,dh))
                assert abs(dw-lw*scale)<=1 and abs(dh-lh*scale)<=1
                if (lw,lh)==(81,61):images[scale]=(dw,dh)
            assert images[1]==(81,61) and images[2]==(162,122)
            assert 120<=images[1.5][0]<=122 and 90<=images[1.5][1]<=92
            print('Chrome image device sizes:',images,flush=True)
            # A one-pixel move changes rounded device spans at fractional density.
            ev("OFFSET=1;core.dirty('HEADLESS-1')");settle(log);assert stats(log)[1]>0
            screenshot(env,work/'density-moved-origin.png')
            before=screenshot(env,work/'before-failure.png')
            ev("BAD=true;core.dirty('HEADLESS-1')");time.sleep(.15)
            assert screenshot(env,work/'failed-declaration.png').tobytes()==before.tobytes()
            yes('S.scale==1.5 and #client.all()==1');assert 'table id index' in log.read_text()
            # Hardware facts change immediately even when the next Lua frame
            # fails; the published logical boxes/input frame remain retained.
            oldbox=box(h,env,'label');oldpaint=stats(log)
            ev('S.scale=2');time.sleep(.15)
            yes('S.scale==2 and S.width==640');assert box(h,env,'label')==oldbox
            assert stats(log)==oldpaint
            ev('S.scale=1.5');time.sleep(.1)
            assert screenshot(env,work/'restored-scale-failed-frame.png').tobytes()==before.tobytes()
            ev("BAD=false;core.dirty('HEADLESS-1')");settle(log)
            ev("core.set_frame_handler(function() core.open({layout={sizing={width=100000,height=100000}},cornerRadius={topLeft=5},backgroundColor={r=255}});core.close() end);core.dirty('HEADLESS-1')")
            time.sleep(.15);assert screenshot(env,work/'failed-raster.png').tobytes()==before.tobytes()
            ev("core.set_frame_handler(density_frame);core.dirty('HEADLESS-1')");settle(log)
            for _ in range(3):
                ev('S.scale=2');settle(log);ev('S.scale=1.5');settle(log)
            (work/'density-proof.json').write_text(json.dumps(proof,indent=2)+'\n')
            assert not any(x in log.read_text() for x in ["error in '",'DUPLICATE','tree==scene:'])
            h.quit(server,env,log)
            assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
        finally:stop(foot);f.close()
    print('PASS: density raster sizes, independent outputs, touching tile edges, cropped text, moved origins, foot captures and transactional declaration/raster recovery')

def protocol(h):
    with h.boot(DESKTOP,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        def ev(s):check(h,env,'do '+s+' end',b'\n')
        ev("for _,s in ipairs(screen.all())do if s.name=='HEADLESS-1' then S=s;screen.focused=s else T=s end end")
        all_records=[]
        for scale in [1,1.5,2,1.3]:
            ev(f'S.scale={scale};screen.focused=S');settle(log)
            c=Client(env,fractional=True)
            try:
                assert c.globals['wp_fractional_scale_manager_v1'][0][1]==1
                assert c.globals['wp_viewporter'][0][1]==1
                assert c.globals['zxdg_output_manager_v1'][0][1]==3
                a=c.toplevel('density-native');c.pump(.3)
                assert a['scale120']==round(scale*120),a
                assert a['buffer_size']==tuple(round(v*scale) for v in a['size'])
                output=next(m for _,(kind,m) in c.objects.items() if kind=='output' and m.get('name')=='HEADLESS-1')
                assert output['scale']==int(-(-scale//1))
                for nextscale in [2,1.5,1]:
                    ev(f'S.scale={nextscale}');c.pump(.3);settle(log);c.pump(.2)
                    assert a['scale120']==round(nextscale*120),a
                    assert a['buffer_size']==tuple(round(v*nextscale) for v in a['size'])
                ev('T.scale=1.5;client.all()[1]:move_to(T)');c.pump(.4);settle(log);c.pump(.1)
                assert a['scale120']==180 and len(a['outputs'])==1
                before=log.read_text().count('Layout ')
                c.paint(a,*a['size']);c.pump(.15);assert before==log.read_text().count('Layout ')
                all_records+=c.records
                c.destroy_xdg(a);c.pump(.1)
            finally:c.close()
        (work/'fractional-wire.json').write_text(json.dumps(all_records,indent=2)+'\n')
        h.quit(server,env,log)
    print('PASS: fractional/viewport versions, integer output fallback, 120/156/180/240 before map and mapped, viewport buffer dimensions, output moves and repaint without solves')

if __name__=='__main__':
    import importlib.util,tempfile
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-density-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
