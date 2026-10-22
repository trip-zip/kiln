#!/usr/bin/env python3
"""Fetch hash-pinned application fixtures into a private cache, without installation."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import urllib.request

ROOT=Path(os.environ.get('KILN_APP_ROOT',str(Path.home()/'.cache/kiln-session16-apps/root')))
PACKAGES={
    'jre-openjdk-27.u35-1-x86_64.pkg.tar.zst':'b95e100b667ae3e22d412208638b4ad7de9ad7f49b802cf66afa58ab3fe99df7',
    'freecol-1.2.0-2-any.pkg.tar.zst':'474bbee538888ca6cff533e2b8778b5aa98f59158be6d438b977ce8cfd8049e3',
}

def main():
    cache=ROOT.parent/'packages';cache.mkdir(parents=True,exist_ok=True);ROOT.mkdir(parents=True,exist_ok=True)
    for name,expected in PACKAGES.items():
        dest=cache/name
        if not dest.exists():
            url='https://fastly.mirror.pkgbuild.com/extra/os/x86_64/'+name
            print('Downloading',url,flush=True)
            with urllib.request.urlopen(url,timeout=60) as response,dest.open('wb') as out:
                while chunk:=response.read(1024*1024):out.write(chunk)
        actual=hashlib.sha256(dest.read_bytes()).hexdigest();assert actual==expected,(name,actual,expected)
        subprocess.run(['bsdtar','-xf',str(dest),'-C',str(ROOT)],check=True,timeout=60)
    # Arch packages use absolute configuration links; relocate only these
    # extracted links so the runtime reads its own private configuration.
    for p in (ROOT/'usr/lib/jvm').rglob('*'):
        if p.is_symlink():
            target=p.readlink()
            if target.is_absolute() and (ROOT/str(target).lstrip('/')).exists():
                p.unlink();p.symlink_to(ROOT/str(target).lstrip('/'))
    (ROOT.parent/'packages.json').write_text(json.dumps(PACKAGES,indent=2)+'\n')
    print('Private application fixtures:',ROOT)

if __name__=='__main__':main()
