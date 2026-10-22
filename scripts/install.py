#!/usr/bin/env python3
"""Install the normal runtime, and remove only files in its exact manifest."""
import argparse
import json
import os
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser()
p.add_argument('action',choices=['install','uninstall'])
p.add_argument('--bindir',required=True)
p.add_argument('--datadir',required=True)
p.add_argument('--destdir',default='')
a=p.parse_args()
bindir,datadir=Path(a.bindir),Path(a.datadir)
assert bindir.is_absolute() and datadir.is_absolute(),'install directories must be absolute'
assert '..' not in bindir.parts and '..' not in datadir.parts
runtime=datadir/'kiln'

def stage(path):return Path(a.destdir)/path.relative_to('/') if a.destdir else path

manifest=runtime/'install-manifest.json'
files={bindir/'kiln':(ROOT/'build/kiln',0o755),
       bindir/'kiln-client':(ROOT/'build/kiln-client',0o755),
       runtime/'rc.lua':(ROOT/'kilnrc.lua',0o644)}
for src in (ROOT/'licenses').iterdir():files[datadir/'licenses/kiln'/src.name]=(src,0o644)
files[datadir/'licenses/kiln/LICENSE']=(ROOT/'LICENSE',0o644)
for src in sorted((ROOT/'lua').rglob('*.lua')):files[runtime/src.relative_to(ROOT)]=(src,0o644)
completion_files={datadir/'bash-completion/completions/kiln-client':'kiln-client.bash',
                  datadir/'zsh/site-functions/_kiln-client':'_kiln-client',
                  datadir/'fish/vendor_completions.d/kiln-client.fish':'kiln-client.fish'}
desktop=datadir/'wayland-sessions/kiln.desktop'
allowed=set(map(str,[*files,*completion_files,desktop,manifest]))
if a.action=='install':
    for path,(src,mode) in files.items():
        target=stage(path);target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(src,target);target.chmod(mode)
    for path,name in completion_files.items():
        target=stage(path);target.parent.mkdir(parents=True,exist_ok=True)
        text=(ROOT/'completions'/name).read_text()
        target.write_text(text);target.chmod(0o644)
    # Desktop Entry escaping is distinct from shell escaping.
    exe=str(bindir/'kiln').replace('\\','\\\\').replace('"','\\"').replace('`','\\`').replace('$','\\$').replace('%','%%')
    text='[Desktop Entry]\nName=Kiln\nComment=Lua-configured Wayland compositor\nExec="'+exe+'"\nType=Application\n'
    target=stage(desktop);target.parent.mkdir(parents=True,exist_ok=True);target.write_text(text);target.chmod(0o644)
    stage(manifest).write_text(json.dumps(sorted(allowed),indent=2)+'\n');stage(manifest).chmod(0o644)
    print('Installed',len(allowed),'files; runtime datadir:',runtime,'; staging:',a.destdir or '(none)')
else:
    target=stage(manifest)
    if not target.exists():raise SystemExit('No installation manifest at '+str(target))
    recorded=json.loads(target.read_text())
    assert set(recorded)<=allowed,'manifest contains paths outside this runtime'
    parents=set()
    for path in recorded:
        target=stage(Path(path));target.unlink(missing_ok=True);parents.add(target.parent)
    # Empty ancestors only; unrelated files and directories retain ownership.
    for parent in sorted(parents,key=lambda x:len(x.parts),reverse=True):
        while parent not in (stage(bindir),stage(datadir),Path('/'),Path(a.destdir or '/')):
            try:parent.rmdir()
            except OSError:break
            parent=parent.parent
    print('Uninstalled',len(recorded),'manifest files')
