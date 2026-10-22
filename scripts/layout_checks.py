"""Layout-test geometry adaptations over real clients and public solved boxes."""
import math
from pathlib import Path
import time

from PIL import Image, ImageChops

from declaration_checks import check, wait, capture, settle
from model_checks import cleanup, spawn

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = (ROOT / 'scripts/fixtures/strip.lua').read_text()
FAMILIES = ['tile','tile.left','tile.top','tile.bottom','fair','fair.horizontal',
            'spiral','dwindle','corner','corner.nw','corner.ne','corner.sw','corner.se',
            'magnifier','carousel','max','floating']


def expected(name, n, box, gap, factor=.5, masters=1, columns=1, focus=0, carousel=.5):
    """Independent restatement of the original layout-test.sh box expectations."""
    out = [None]*n
    x,y,w,h = box
    def run(ids, b, horizontal):
        if not ids: return
        x,y,w,h=b
        size=((w if horizontal else h)-gap*(len(ids)-1))/len(ids)
        for i,k in enumerate(ids):
            out[k]=(x+i*(size+gap),y,size,h) if horizontal else (x,y+i*(size+gap),w,size)
    ids=list(range(n))
    if not n: return out
    if name.startswith('tile'):
        horizontal=name not in ('tile.top','tile.bottom')
        leading=name in ('tile','tile.bottom')
        nm=min(masters,n); rest=n-nm
        size=w if horizontal else h
        m=(size-gap)*factor if rest and nm else size
        r=size-gap-m if nm and rest else size
        mb=(x if leading or not rest else x+r+gap,y,m,h) if horizontal else (x,y if leading or not rest else y+r+gap,w,m)
        run(ids[:nm],mb,not horizontal)
        sx=x+(m+gap if leading and nm else 0) if horizontal else x
        sy=y if horizontal else y+(m+gap if leading and nm else 0)
        cols=min(columns,rest)
        at=nm
        if cols:
            size=(r-gap*(cols-1))/cols
            for col in range(cols):
                take=math.ceil((n-at)/(cols-col))
                b=(sx+col*(size+gap),sy,size,h) if horizontal else (sx,sy+col*(size+gap),w,size)
                run(ids[at:at+take],b,not horizontal);at+=take
    elif name.startswith('fair'):
        horizontal=name=='fair.horizontal'; cols=math.ceil(math.sqrt(n));at=0
        size=((h if horizontal else w)-gap*(cols-1))/cols
        for col in range(cols):
            take=math.ceil((n-at)/(cols-col))
            b=(x,y+col*(size+gap),w,size) if horizontal else (x+col*(size+gap),y,size,h)
            run(ids[at:at+take],b,horizontal);at+=take
    elif name in ('spiral','dwindle'):
        for k in ids:
            if k==n-1: out[k]=(x,y,w,h);break
            horizontal=k%2==0;lead=name=='dwindle' or k%4<2
            if horizontal:
                w=(w-gap)/2;out[k]=(x if lead else x+w+gap,y,w,h)
                if lead:x+=w+gap
            else:
                h=(h-gap)/2;out[k]=(x,y if lead else y+h+gap,w,h)
                if lead:y+=h+gap
    elif name.startswith('corner'):
        side=ids[1::2];foot=ids[2::2]
        left=name not in ('corner.ne','corner.se');top=name not in ('corner.sw','corner.se')
        bh=(h-gap)*factor if foot else h; fh=h-gap-bh
        mw=(w-gap)*factor if side else w; sw=w-gap-mw
        by=y if top or not foot else y+fh+gap
        out[0]=(x if left or not side else x+sw+gap,by,mw,bh)
        run(side,(x+mw+gap if left else x,by,sw,bh),False)
        run(foot,(x,y+bh+gap if top else y,w,fh),True)
    elif name=='max':out[focus]=(x,y,w,h)
    elif name=='magnifier':
        run([k for k in ids if k!=focus],box,False)
        mw,mh=math.floor(w*factor),math.floor(h*factor)
        out[focus]=(x+(w-mw)/2,y+(h-mh)/2,mw,mh)
    elif name=='carousel':
        col=max(1,math.floor(w*carousel));strip=n*col+(n-1)*gap
        off=max(min(0,w-strip),min(0,w/2-focus*(col+gap)-col/2))
        out=[(x+off+k*(col+gap),y,col,h) for k in ids]
    elif name=='floating':out=[(40+k*18,80+k*12,400,260) for k in ids]
    return out


def read_boxes(h,env):
    raw=h.ev(env,"local o={};for _,c in ipairs(CS) do local b=core.box({'client',c.handle});o[#o+1]=b and string.format('%d,%d,%d,%d',b.x,b.y,b.width,b.height) or '-' end;return table.concat(o,';')").decode().strip()
    return [None if b=='-' else tuple(map(int,b.split(','))) for b in raw.split(';')]


def layouts(h):
    config=DEFAULT+'''
L=require('kiln.layout');K=require('kiln');COUNT=0;CHOSEN=L.tile
screen.on('added',function(s)
 if s==screen.all()[1] then
  s.selected_tag.layout=function(cs,area,t,slots)
   CS=cs;AREA=area;local chosen={}
   for i=1,math.min(COUNT,#cs) do chosen[i]=cs[i] end
   CHOSEN(chosen,area,t)
  end
 end
end)
'''
    with h.boot(config,overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        fds=[]
        try:
            check(h,env,"s=screen.all()[1];t=s.selected_tag;screen.focused=s",b'\n')
            for i in range(7):
                fd,_=spawn(h,env,work,str(i));fds.append(fd)
                wait(h,env,'return #client.all()',f'{i+1}\n'.encode(),server)
            check(h,env,"CS=client.all();for i,c in ipairs(CS) do c.float={x=40+(i-1)*18,y=80+(i-1)*12,width=400,height=260} end",b'\n')
            check(h,env,"assert(K.layout==L and #L.list==9);for _,f in ipairs(L.list) do assert(L.name(f)) end;assert(L.name(L.tile.left)=='tile.left');assert(L.next(L.tile.left)==L.tile);assert(L.name(function() end)==nil);local old=L.list;L.list={L.max,L.tile};assert(L.next(L.max)==L.tile and L.next(L.tile)==L.max);L.list={};assert(L.next(L.tile)==nil);L.list=old",b'\n')
            cases=[(name,n,8,.5,1,1,0,.5) for name in FAMILIES for n in (0,1,4,7)]
            cases += [('tile',7,g,f,m,c,0,.5) for g,f,m,c in [(0,.7,2,2),(20,.8,1,3),(8,.05,0,1),(8,.5,9,1),(8,.5,1,20)]]
            cases += [('carousel',7,20,.5,1,1,6,.7),('magnifier',4,20,.7,1,1,2,.5)]
            for name,n,g,f,m,c,focus,cw in cases:
                check(h,env,f"COUNT={n};CHOSEN=L.{name};t.gap={g};t.master_width_factor={f};t.master_count={m};t.column_count={c};t.carousel_width={cw};CS[{focus+1}]:focus();core.dirty(s.name)",b'\n')
                settle(log)
                area=tuple(map(float,h.ev(env,'return string.format("%g,%g,%g,%g",AREA.x,AREA.y,AREA.width,AREA.height)').decode().strip().split(',')))
                want=expected(name,n,area,g,f,m,c,focus,cw)+[None]*(7-n)
                got=read_boxes(h,env)
                for i,(a,b) in enumerate(zip(got,want)):
                    if b is None:
                        # core.box deliberately remembers the last successful box.
                        if a:
                            px=max(0,min(1279,a[0]+a[2]/2));py=max(0,min(719,a[1]+a[3]/2))
                            check(h,env,f"for _,hit in ipairs(core.hits(s.name,s.x+{px},s.y+{py})) do assert(hit.name~='core.surface' or hit.index~=CS[{i+1}].handle) end",b'\n')
                        continue
                    assert a is not None,(name,n,i,a,b)
                    if a:assert all(abs(v-z)<=1 for v,z in zip(a,b)),(name,n,g,f,m,c,i,a,b)
            # Public replacement governs every layout and a custom declaration gets the contract.
            check(h,env,"COUNT=4;PRESSES=0;CHOSEN=function(cs,area,tag,...) assert(select('#',...)==0);assert(tag==t and #cs==4 and area.width>0);L.fair(cs,area,tag);K.ui.box({id='layout-control',w=100,h=40,color='#00ff00',float={to='root',band='overlay',offset={x=1100,y=660}},on_press=function() PRESSES=PRESSES+1 end}) end;GOOD=CHOSEN;core.dirty(s.name)",b'\n')
            time.sleep(.1);capture(env,work/'tiled.png')
            check(h,env,"OLD=K.widgets.client;CALLS=0;K.widgets.client=function(c,cfg) CALLS=CALLS+1;OLD(c,cfg) end;core.dirty(s.name)",b'\n')
            wait(h,env,'return CALLS',b'4\n',server)
            # Failure after staged chrome/clients must not publish geometry or pixels.
            before=read_boxes(h,env);capture(env,work/'before-error.png')
            check(h,env,"K.animation.start(s.name,'failed-frame',1,.2,0);CHOSEN=function(cs) K.widgets.client(cs[1],{w=99,h=99});K.ui.box({id='layout-control',w=100,h=40,color='#ff0000',float={to='root',band='overlay',offset={x=1100,y=660}},on_press=function() PRESSES=PRESSES+100 end});error('layout failure') end;core.dirty(s.name)",b'\n')
            settle(log,quiet=.35);assert read_boxes(h,env)==before
            capture(env,work/'failed-layout.png')
            original=Image.open(work/'before-error.png').convert('RGB')
            failed=Image.open(work/'failed-layout.png').convert('RGB')
            origin=int(h.ev(env,'return s.x').decode())
            # Live terminals repaint; the composite rings/titlebars and control must stay identical.
            for x,y,w,height in before[:4]:
                region=(origin+x,y,origin+x+w,y+24)
                assert ImageChops.difference(original.crop(region),failed.crop(region)).getbbox() is None
            region=(origin+1100,660,origin+1200,700)
            assert ImageChops.difference(original.crop(region),failed.crop(region)).getbbox() is None
            check(h,env,"local hit=core.hits(s.name,s.x+1150,s.y+680)[1];assert(hit.name=='layout-control');require('kiln.state').screen_presses[s.name]['on_press:layout-control#0']({});return PRESSES",b'1\n')
            check(h,env,"CHOSEN=GOOD;core.dirty(s.name)",b'\n');time.sleep(.1)
            assert read_boxes(h,env)==before
            check(h,env,"core.dirty(s.name)",b'\n');time.sleep(.1)
            paints=[l for l in log.read_text().splitlines() if l.startswith('Paint '+h.ev(env,'return s.name').decode().strip()+':')]
            assert 'mutations 0, rasters 0' in paints[-1],paints[-1]
            check(h,env,"COUNT=7;CHOSEN=L.tile;t.master_width_factor=-100;core.dirty(s.name)",b'\n');settle(log)
            assert read_boxes(h,env)[0][2]>0
            check(h,env,"t.master_width_factor=100",b'\n');settle(log)
            assert read_boxes(h,env)[0][2]>1000
            h.quit(server,env,log)
        finally:cleanup(fds)
    print('PASS: all layout families/variants, zero/one/four/seven clients, live params, clamp, custom/name/cycle/replacement, failed-frame recovery, retained scene')
    print('Layout artifacts:',work.resolve())


def run(h):
    layouts(h)
