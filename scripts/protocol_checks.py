"""Decoration and xdg popup wire, pixels, retained ordering and native ownership."""
import c_baseline
import json
import subprocess
import time
from PIL import Image
from declaration_checks import check,wait,settle,capture
from window_state_checks import launch,stop,counts
from protocol_client import Client,u
from layer_checks import CONFIG


def run(h):
    with h.boot(CONFIG+"\nMODES={};client.on('request::decoration_mode',function(c,m) MODES[#MODES+1]=m end)",overrides={'WLR_HEADLESS_OUTPUTS':'2'}) as (server,env,work,log):
        c=Client(env);p,f=launch(env,work,'DECORATED-FOOT')
        def ev(src):check(h,env,'do '+src+' end',b'\n')
        def yes(src):wait(h,env,'return '+src,b'true\n',server)
        def pump():c.pump(.2);settle(log);c.pump(.2)
        def root_box():
            return list(map(int,h.ev(env,"core.hits(A.screen.name,A.screen.x,A.screen.y);local b=core.box({'core.surface',A.handle});return b.x+A.screen.x,b.y+A.screen.y,A.screen.x,A.screen.y,A.screen.width,A.screen.height").split()))
        def configs():return len([r for r in c.records if r.get('popup') and r['op']==0])
        def fits(meta,root,ancestors=()):
            x,y,w,h=meta['box'];rx,ry,ox,oy,ow,oh=root
            x+=rx+sum(q['box'][0] for q in ancestors);y+=ry+sum(q['box'][1] for q in ancestors)
            assert ox<=x and oy<=y and x+w<=ox+ow and y+h<=oy+oh,(meta['box'],root,ancestors)
        try:
            yes('#client.all()==1')
            footlog=work/'DECORATED-FOOT.log'
            assert 'zxdg_toplevel_decoration_v1' in footlog.read_text() and '.configure(2)' in footlog.read_text()
            ev('F=client.all()[1];F.floating=true;F.float={x=80,y=100,width=450,height=320};S=F.float')
            yes('F.width==446 and F.height==294')
            capture(env,work/'single-titlebar-foot.png')
            ev('F.fullscreen=true');yes('F.width==F.screen.width and F.height==F.screen.height')
            ev('F.fullscreen=false');yes('F.width==446 and F.height==294 and F.float==S')
            ev('F.floating=false')
            a=c.toplevel('popup-root',geometry=(12,17));b=c.toplevel('neighbor',color=0xff902040);pump()
            yes('#client.all()==3')
            ev("for _,v in ipairs(client.all()) do if v.app_id=='popup-root' then A=v elseif v.app_id=='neighbor' then B=v end end;F.minimized=true;A.tag=screen.all()[1].selected_tag;B.tag=A.tag")
            pump()
            assert [r['mode'] for r in c.records if 'decoration' in r]==[2,2]
            yes("#MODES>=3 and MODES[#MODES]=='client_side'")
            n=len([r for r in c.records if r.get('xdg')==a['xdg'] and 'ack' in r])
            for mode in (2,1,1):c.send(a['decoration'],1,u(mode))
            c.send(a['decoration'],2);pump()
            assert len([r for r in c.records if r.get('xdg')==a['xdg'] and 'ack' in r])==n
            yes("MODES[#MODES]=='none'")
            # Legacy advertises server decorations; its request echo is wlroots policy.
            legacy=c.bind('org_kde_kwin_server_decoration_manager',1)
            legacy_obj=c.new('decoration')
            c.send(legacy,0,u(legacy_obj,a['surface']));c.roundtrip()
            assert c.records[-1].get('mode')==2
            c.send(legacy_obj,0);c.roundtrip()
            pop=c.popup(a,anchor=(600,80,5,5));nested=c.popup(pop,anchor=(150,50,5,5),size=(130,80),color=0xff20b0b0);pump()
            root=root_box();fits(pop,root);fits(nested,root,(pop,))
            capture(env,work/'popup-overhang.png')
            image=Image.open(work/'popup-overhang.png').convert('RGB')
            x=root[0]+pop['box'][0]+40;y=root[1]+pop['box'][1]+20
            assert image.getpixel((x,y))==(208,144,32),(x,y,image.getpixel((x,y)))
            n=configs();before=counts(log)
            for _ in range(3):ev('core.dirty(A.screen.name)');pump()
            assert configs()==n
            paints=[line for line in log.read_text().splitlines() if line.startswith('Paint '+h.ev(env,'return A.screen.name').decode().strip()+':')]
            assert all('mutations 0, rasters 0' in line for line in paints[-3:]),paints[-3:]
            c.reposition(pop,123,(1200,650,2,2));pump()
            assert any(r.get('popup')==pop['role'] and r['op']==2 and r['words']==[123] for r in c.records)
            fits(pop,root_box());fits(nested,root_box(),(pop,))
            # Failed parent relocation preserves pixels and emits no popup configure.
            capture(env,work/'before-relocation.png');n=configs()
            ev("H=K.on_declare(function() error('popup relocation rejected') end);A.floating=true;A.float={x=1070,y=570,width=180,height=140};core.dirty()")
            pump();assert configs()==n
            capture(env,work/'failed-relocation.png')
            assert (work/'before-relocation.png').read_bytes()==(work/'failed-relocation.png').read_bytes()
            ev('K.off_declare(H);core.dirty()');pump();fits(pop,root_box());fits(nested,root_box(),(pop,))
            ev('A:move_to(screen.all()[2]);A.float={x=30,y=50,width=380,height=260}')
            pump();fits(pop,root_box());fits(nested,root_box(),(pop,))
            assert root_box()[2]!=root[2]
            capture(env,work/'nonorigin-constrained.png')
            layer=c.layer('popup-layer',width=220,height=50,zone=0,band=3)
            lp=c.popup(layer,anchor=(210,40,2,2));pump()
            assert lp.get('painted') and lp['box'][2:]==(180,100)
            capture(env,work/'layer-parented-popup.png')
            # A real xdg_toplevel parent remains a dialog parent after replay.
            dialog=c.toplevel('real-dialog',parent=a);pump()
            ev("for _,v in ipairs(client.all()) do if v.app_id=='real-dialog' then D=v end end;assert(D.parent==A);AH=A.handle;DH=D.handle;LH=LS.all[1].handle;oldlayer=LS.all[1];K.reload()")
            pump();yes('#client.all()==4')
            ev("A=require('kiln.object').lookup(AH);D=require('kiln.object').lookup(DH);assert(D.parent==A and LS.all[1]==oldlayer and LS.all[1].handle==LH)")
            # Parent-first destruction removes protocol descendants and their scene trees.
            c.destroy_xdg(dialog);c.destroy_xdg(a);pump()
            assert pop.get('done') and nested.get('done')
            c.destroy_xdg(nested);c.destroy_xdg(pop)
            c.destroy(layer);pump();assert lp.get('done');c.destroy_xdg(lp)
            c.destroy_xdg(b);pump()
            yes('#client.all()==1 and #LS.all==0')
            for _ in range(5):
                root_client=c.toplevel('cycle-root');child=c.popup(root_client)
                c.destroy_xdg(root_client);c.destroy_xdg(child)
            pump();yes('#client.all()==1')
            bad=Client(env)
            try:
                wrong=bad.toplevel('invalid-decoration-order')
                try:
                    bad.destroy_xdg(wrong,role_first=True)
                except AssertionError as error:
                    assert 'xdg_toplevel destroyed before xdg_toplevel_decoration' in str(error),error
                else:raise AssertionError('invalid decoration order was accepted')
            finally:bad.close()
            h.healthy(env);yes('#client.all()==1')
            (work/'protocol-wire.json').write_text(json.dumps(c.records,indent=2)+'\n')
            h.quit(server,env,log)
        finally:c.close();stop(p);f.close()
    print('PASS: real foot decoration, mode requests, legacy manager, nested/layer popups, constraints, tokens, atomic relocation and real dialog replay')

if __name__=='__main__':
    import importlib.util,tempfile
    from pathlib import Path
    spec=importlib.util.spec_from_file_location('compat',Path(__file__).with_name('compat-test.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-protocol-checks-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(Path(__file__).resolve().parents[1]/'build/kiln',c_baseline.source(),out))
