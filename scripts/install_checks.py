"""Exercise actual install targets in disposable final and staging prefixes."""
import c_baseline
import importlib.util
import json
from pathlib import Path
import shutil
import shlex
import stat
import subprocess
import tempfile
from declaration_checks import wait,settle
from stock_checks import STOCK

ROOT=Path(__file__).resolve().parents[1]

def run(h,intended_config=None,intended_theme=None):
    base=h.out/'install-targets';base.mkdir()
    prefix=base/'prefix with spaces';bindir=prefix/'executables';datadir=prefix/'data'
    args=[f'prefix={prefix}',f'bindir={bindir}',f'datadir={datadir}']
    receipts=[]
    def make(target,*extra):
        p=subprocess.run(['make',target,*args,*extra],cwd=ROOT,capture_output=True,text=True,timeout=90)
        receipts.append(dict(target=target,extra=extra,status=p.returncode,stdout=p.stdout,stderr=p.stderr))
        assert p.returncode==0,(p.stdout,p.stderr)
    try:
        make('install');make('install')
        runtime=datadir/'kiln';manifest=json.loads((runtime/'install-manifest.json').read_text())
        assert len(manifest)==len(set(manifest))
        for file in manifest:
            p=Path(file);assert p.is_file()
            mode=0o755 if p.parent==bindir else 0o644
            assert stat.S_IMODE(p.stat().st_mode)==mode,(file,p.stat().st_mode)
            assert not any(x in p.name for x in ('fixture','SESSION-','test-helper'))
        desktop=datadir/'wayland-sessions/kiln.desktop'
        subprocess.run(['desktop-file-validate',str(desktop)],check=True)
        assert str(bindir/'kiln') in desktop.read_text()
        assert not (bindir/'kiln-odin').exists() and not (bindir/'kiln-odin-client').exists()
        assert 'Name=Kiln\n' in desktop.read_text()
        for name in ('LICENSE','Clay.txt','LuaJIT-binding.txt'):
            assert (datadir/'licenses/kiln'/name).is_file()
        assert (datadir/'licenses/kiln/LICENSE').read_bytes()==(ROOT/'LICENSE').read_bytes()
        sentinel=runtime/'lua/kiln/unrelated.keep';sentinel.write_text('keep')
        (bindir/'unrelated.keep').write_text('keep')
        cwd=base/'cwd';cwd.mkdir()
        suite=type(h)(bindir/'kiln',h.original,base)
        with suite.boot(None,cwd=cwd) as (server,env,work,log):
            wait(suite,env,'return #screen.all()[1].tags',b'5\n',server)
            source=suite.ev(env,'return debug.getinfo(require("kiln").reload).source').decode().strip()
            assert source.startswith('@'+str(runtime)+'/lua/'),source
            def cli(*args):
                p=subprocess.run([str(bindir/'kiln-client'),'-s',env['KILN_SOCK'],*args],cwd=cwd,capture_output=True,timeout=5)
                assert p.returncode==0 and not p.stderr,p
                return p.stdout
            assert cli('ping')==b'pong\n'
            for shell,completion in [('bash',datadir/'bash-completion/completions/kiln-client'),('zsh',datadir/'zsh/site-functions/_kiln-client')]:
                words=shlex.join([str(bindir/'kiln-client'),'--json','-s',env['KILN_SOCK'],'tag','view',''])
                if shell=='bash':
                    source=f'source {shlex.quote(str(completion))};COMP_WORDS=({words});COMP_CWORD=6;_kiln_client;printf "%s\\n" "${{COMPREPLY[@]}}"'
                else:
                    source=f'compadd() {{ printf "%s\\n" "${{(@P)2}}"; }};words=({words});CURRENT=7;source {shlex.quote(str(completion))}'
                p=subprocess.run([shell,'-c',source],env=env,cwd=cwd,capture_output=True,text=True,timeout=5)
                assert p.returncode==0 and not p.stderr and 'dev' in p.stdout.splitlines(),(shell,p.stdout,p.stderr)
                receipts.append(dict(completion=shell,stdout=p.stdout,stderr=p.stderr,status=p.returncode))

            if shutil.which('fish'):
                completion_dir=datadir/'fish/vendor_completions.d'
                source=f'set -gx PATH {shlex.quote(str(bindir))} $PATH; set -g fish_complete_path {shlex.quote(str(completion_dir))}; complete -C {shlex.quote(words[:-2])}'
                p=subprocess.run(['fish','--no-config','-c',source],env=env,cwd=cwd,capture_output=True,text=True,timeout=5)
                assert p.returncode==0 and not p.stderr and 'dev' in p.stdout.splitlines(),p
                receipts.append(dict(completion='fish installed autoload',stdout=p.stdout,stderr=p.stderr,status=p.returncode))
            else:
                receipts.append(dict(completion='fish installed autoload',status='NOT RUN: shell unavailable'))

            image=work/'installed.png';assert cli('screenshot',str(image))==str(image).encode()+b'\n';assert image.is_file()
            assert cli('inspector')==b'on\n'
            wait(suite,env,'return core.box("Clay__RootContainer") and core.box("Clay__RootContainer").width',b'880\n',server)
            inspector_image=work/'installed-inspector.png'
            assert cli('screenshot',str(inspector_image))==str(inspector_image).encode()+b'\n'
            assert inspector_image.is_file()
            assert cli('inspector')==b'off\n'
            # The installed library owns recovery; nothing imports from the checkout.
            (runtime/'rc.lua').write_text('error("installed repair")')
            cli('reload');wait(suite,env,'return #screen.all()[1].tags',b'0\n',server)
            (runtime/'rc.lua').write_text(STOCK);cli('reload')
            wait(suite,env,'return #screen.all()[1].tags',b'5\n',server)
            suite.quit(server,env,log)
        from installed_daily_checks import run as daily
        daily(suite,bindir/'kiln-client',runtime,cwd)
        if intended_config is not None:
            saved=(runtime/'rc.lua').read_bytes()
            try:
                (runtime/'rc.lua').write_bytes(intended_config.read_bytes())
                daily(suite,bindir/'kiln-client',runtime,cwd,intended_config,intended_theme)
            finally:(runtime/'rc.lua').write_bytes(saved)
        # Explicit bad selection does not fall through to the working installed default.
        missing=base/'missing.lua'
        with suite.boot(None,cwd=cwd,overrides={'KILN_RC':missing}) as (server,env,work,log):
            assert suite.ev(env,'return screen')==b'nil\n'
            missing.write_text('require("kiln");REPAIRED=true')
            assert suite.ev(env,'require("kiln").reload()')==b'true\n'
            wait(suite,env,'return REPAIRED',b'true\n',server)
            suite.quit(server,env,log)
        staging=base/'staging';make('install','DESTDIR='+str(staging))
        staged=lambda p:staging/Path(p).relative_to('/')
        staged_manifest=json.loads(staged(runtime/'install-manifest.json').read_text())
        assert staged_manifest==manifest
        assert {str(p.relative_to(staging)) for p in staging.rglob('*') if p.is_file()}=={p.lstrip('/') for p in manifest}
        # The staged executable retains the final datadir, not its staging root.
        assert str(runtime).encode() in staged(bindir/'kiln').read_bytes()
        assert str(staging).encode() not in staged(bindir/'kiln').read_bytes()
        make('uninstall','DESTDIR='+str(staging));assert not list(staging.rglob('*.lua'))
        make('uninstall');assert sentinel.read_text()=='keep' and (bindir/'unrelated.keep').read_text()=='keep'
        assert not any(Path(p).exists() for p in manifest)
        # The phony build always incorporates settings, including changes after install.
        second=base/'changed';make('all','datadir='+str(second))
        assert str(second/'kiln').encode() in (ROOT/'build/kiln').read_bytes()
        assert str(runtime).encode() not in (ROOT/'build/kiln').read_bytes()
        (base/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    finally:
        (base/'install-receipts.json').write_text(json.dumps(receipts,indent=2)+'\n')
        # Restore the ordinary build for later groups using the same pathname.
        subprocess.run(['make'],cwd=ROOT,check=True,stdout=subprocess.DEVNULL,timeout=90)
    print('PASS: real/repeated install, arbitrary cwd, installed stock/CLI/capture/reload/repair, DESTDIR manifest, permissions, desktop validity, settings rebuild and sentinel-preserving uninstall')

if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('--config',type=Path,help='previously reviewed intended config, copied into the disposable runtime')
    parser.add_argument('--theme',type=Path,help='reviewed theme selection copied into the private config home')
    args=parser.parse_args()
    if args.theme and not args.config:parser.error('--theme requires --config')
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-install-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(ROOT/'build/kiln',c_baseline.source(),out),args.config,args.theme)
