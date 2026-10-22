"""Focused image/asset source contracts with real composed pixel controls."""
import c_baseline
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from PIL import Image
from declaration_checks import check, wait
from paint_checks import box, screenshot, pixel, update, stats
ROOT=Path(__file__).resolve().parents[1]
CONFIG=r'''
local kiln=require('kiln')
screen.on('added',function(s) if #s.tags==0 then tag.new{name='images',screen=s} end end)
COUNTS={};SHOW=true;PATH=SOURCE
local grow={type='grow'}
function pic(id,path,w,h,color,radius,aspect)
 core.open({id=id,image={path=path},aspectRatio=aspect,backgroundColor=color,
 layout={sizing={width=w,height=h}},cornerRadius={topLeft=radius,topRight=radius,bottomLeft=radius,bottomRight=radius}});core.close()
end
function image_frame(sn,w,h)
 COUNTS[sn]=(COUNTS[sn] or 0)+1
 core.open({id='root',layout={sizing={width=grow,height=grow},layoutDirection='ttb',padding={left=20,top=20},childGap=20},backgroundColor={r=0,g=0,b=0}})
 core.open({layout={sizing={width=grow,height=100},childGap=20}})
 if SHOW then
 pic('source',PATH,120,60);pic('tint',PATH,120,60,{r=240,g=120,b=60,a=128})
 pic('round',OPAQUE,60,60,nil,30);pic('opaque',OPAQUE,60,60)
 pic('missing',MISSING,60,60);pic('corrupt',CORRUPT,60,60)
 pic('aspect',OPAQUE,80,nil,nil,nil,2);pic('intrinsic',OPAQUE)
 end
 core.close()
 core.open({id='clients',layout={sizing={width=grow,height=grow}}})
 for _,s in ipairs(screen.all()) do if s.name==sn then for _,c in ipairs(kiln.visible_clients(s)) do core.surface(c.handle) end end end
 core.close();core.close()
 collectgarbage('collect')
end
core.set_frame_handler(image_frame)
'''

def counts(log):
    return tuple(map(int,re.findall(r'Images: decodes (\d+), resident (\d+), keys (\d+)',log.read_text())[-1]))

def run(h):
    assets=h.out/'source images';assets.mkdir()
    source=assets/"alpha's.png";opaque=assets/'opaque.png';missing=assets/'missing.png';corrupt=assets/'corrupt.png'
    im=Image.new('RGBA',(120,60))
    for x in range(120):
        for y in range(60): im.putpixel((x,y),(20,200,80,255 if x<40 else 128 if x<80 else 0))
    im.save(source);Image.new('RGB',(20,20),(40,100,220)).save(opaque);corrupt.write_text('not an image')
    config='\n'.join(f'{k}={json.dumps(str(v.resolve()))}' for k,v in [('SOURCE',source),('OPAQUE',opaque),('MISSING',missing),('CORRUPT',corrupt)])+'\n'+CONFIG
    with h.boot(config,overrides={'WLR_HEADLESS_OUTPUTS':'2','KILN_IMAGE_BUDGET_MB':'1'}) as (server,env,work,log):
        wait(h,env,"return COUNTS['HEADLESS-2']~=nil",b'true\n',server)
        b={n:box(h,env,n) for n in ['source','tint','round','opaque','missing','corrupt','aspect','intrinsic']}
        assert b['aspect'][2:]==(80,40),b
        assert b['intrinsic'][2:]==(0,0),b
        initial=screenshot(env,work/'images.png')
        for n,x,y,color in [('source',20,30,(20,200,80)),('source',60,30,(10,100,40)),('source',100,30,(0,0,0)),
          ('tint',20,30,(120,60,30)),('tint',60,30,(60,30,15)),('tint',100,30,(0,0,0)),
          ('round',1,1,(0,0,0)),('round',30,30,(40,100,220)),('opaque',1,1,(40,100,220)),
          ('missing',30,30,(0,0,0)),('corrupt',30,30,(0,0,0))]: pixel(initial,b[n],x,y,color)
        assert counts(log)[0]==4,counts(log)
        for s in ['HEADLESS-1','HEADLESS-2']:
            assert update(h,env,server,log,output=s)[:2]==(0,0)
        assert counts(log)[0]==4
        # No automatic dirtying; the second output retains its independent old raster.
        Image.new('RGBA',(120,60),(220,40,80,255)).save(source)
        before=counts(log)
        check(h,env,'core.image_reload(SOURCE)',b'\n');time.sleep(.1)
        assert counts(log)==before
        assert screenshot(env,work/'reload-before.png').tobytes()==initial.tobytes()
        assert update(h,env,server,log)[1]==2
        changed=screenshot(env,work/'reload-after.png');pixel(changed,b['source'],20,30,(220,40,80))
        assert screenshot(env,work/'other-old.png','HEADLESS-2').tobytes()==initial.tobytes()
        assert update(h,env,server,log,output='HEADLESS-2')[1]==2
        assert counts(log)[0]==5
        # A failed decode stays negative until explicitly invalidated.
        Image.new('RGB',(20,20),(230,180,20)).save(missing)
        assert update(h,env,server,log)[:2]==(0,0)
        pixel(screenshot(env,work/'negative.png'),b['missing'],30,30,(0,0,0))
        update(h,env,server,log,'core.image_reload(MISSING)')
        pixel(screenshot(env,work/'recovered.png'),b['missing'],30,30,(230,180,20))
        stable=screenshot(env,work/'stable.png')
        for i,body in enumerate(["pic('staged',SOURCE,40,40);error('after image')", "pic('staged',SOURCE,100000,100000)"]):
            check(h,env,f"core.set_frame_handler(function() ATTEMPT={i};{body} end);core.dirty('HEADLESS-1')",b'\n')
            wait(h,env,'return ATTEMPT',f'{i}\n'.encode(),server)
            assert screenshot(env,work/f'failure-{i}.png').tobytes()==stable.tobytes()
            assert update(h,env,server,log,'core.set_frame_handler(image_frame)')[:2]==(0,0)
        # The current working set may exceed budget, old decodes may not accumulate.
        for i in range(8):
            path=assets/f'churn-{i}.png';Image.new('RGB',(600,600),(i*20,80,160)).save(path)
            update(h,env,server,log,'PATH='+json.dumps(str(path.resolve())))
            assert counts(log)[1]<=600*600*4+20*20*4*2,counts(log)
        update(h,env,server,log,'SHOW=false')
        assert counts(log)[1]<=1024*1024,counts(log)
        update(h,env,server,log,'SHOW=true;PATH=SOURCE')
        check(h,env,"for _,s in ipairs(screen.all()) do if s.name=='HEADLESS-1' then screen.focused=s end end",b'\n')
        foot=subprocess.Popen(['foot','--title=IMAGE-FOOT','sh','-c',"printf 'Images and retained pixels\\n'; exec sleep 120"],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            wait(h,env,'return #client.all()',b'1\n',server);time.sleep(.3)
            live=screenshot(env,work/'images-foot.png')
            cb=box(h,env,'clients')
            assert live.getpixel((cb[0]+100,cb[1]+100))!=(0,0,0), 'foot must be visible on the captured output'
            assert update(h,env,server,log)[:2]==(0,0)
            h.quit(server,env,log)
            assert 'Paint cleanup: live buffers 0, live bytes 0' in log.read_text()
        finally:
            if foot.poll() is None: foot.terminate()
            foot.wait(timeout=5)
    print('PASS: image pixels/alpha/stencil, aspect/no intrinsic size, negatives/reload, two outputs, cache churn, atomic failures and reuse',work.resolve())
    generated(h)

def generated(h):
    cache=h.out/"cache with apostrophe's";cache.mkdir()
    snippet=r'''
local a=require('kiln.asset')
local function doc(c) return '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="20" height="20" fill="'..c..'"/></svg>' end
local calls=0;local execute=os.execute
os.execute=function(s) calls=calls+1;return execute(s) end
local x=a.request('one',20,20,doc('#ff0000'));local y=a.request('two',20,20,doc('#00ff00'))
a.flush();A=a.path(x);B=a.path(y);CALLS=calls
assert(A and B)
assert(x~=a.request('one',20,20,doc('#0000ff')));a.flush()
G=a.gradient('linear:0,0:80,0:0,#ff0000:1,#0000ff',80,20);assert(G)
for _,s in ipairs{false,{}, {type='radial'}, {type='linear',from={},to={}}, 'linear:bad:0,0:0,#ffffff'} do assert(not pcall(a.gradient,s,80,20)) end
'''
    config=snippet+r'''
core.set_frame_handler(function()
 core.open({layout={sizing={width=80,height=20}},image={path=G}});core.close()
end)
'''
    mtimes=None
    for warm in [False,True]:
        with h.boot(config,overrides={'XDG_CACHE_HOME':cache.resolve()}) as (server,env,work,log):
            check(h,env,'return CALLS',b'0\n' if warm else b'2\n')
            im=screenshot(env,work/'gradient.png');assert im.getpixel((5,10))[0]>200 and im.getpixel((75,10))[2]>200
            files={p.name:p.stat().st_mtime_ns for p in cache.rglob('*.png')}
            assert len(files)==4,files
            if warm: assert files==mtimes
            mtimes=files
            h.quit(server,env,log)
    fail=h.out/'failing-tools';fail.mkdir();shim=fail/'rsvg-convert';shim.write_text('#!/bin/sh\nexit 1\n');shim.chmod(0o755)
    fail_config=r'''
local a=require('kiln.asset');local calls=0;local execute=os.execute
os.execute=function(s) calls=calls+1;return execute(s) end
RESULT=a.svg('failure',20,20,'<svg/>');local before=calls
assert(a.svg('failure',20,20,'<svg/>')==nil and calls==before)
'''
    with h.boot(fail_config,overrides={'XDG_CACHE_HOME':cache.resolve(),'PATH':str(fail.resolve())+':'+os.environ['PATH']}) as (server,env,work,log):
        check(h,env,'return RESULT',b'nil\n');assert 'Lua config:' not in log.read_text();h.quit(server,env,log)
    print('PASS: isolated quoted asset cache, batched/cold/warm generation, pixel gradient, content keys, negative conversion and malformed specs')

if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py');compat=importlib.util.module_from_spec(spec);spec.loader.exec_module(compat)
    out=Path(tempfile.mkdtemp(prefix='images-',dir=ROOT/'build/verification'))
    with tempfile.TemporaryDirectory(prefix='ko-images-') as short:
        alias=Path(short)/'e';alias.symlink_to(out,target_is_directory=True)
        run(compat.Harness(ROOT/'build/kiln',c_baseline.source(),alias))
