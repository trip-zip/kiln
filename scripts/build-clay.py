#!/usr/bin/env python3
"""Build the pinned external dependency, independently of source timestamps."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--test', action='store_true')
    args = parser.parse_args()
    source = args.root.resolve()
    pin = json.loads((ROOT / 'clay-dependency.json').read_text())
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != pin['revision']:
        raise SystemExit(f'Clay revision {revision} differs from pin {pin["revision"]}; see README.md for external checkout setup')
    files = ['clay.h', 'bindings/odin/clay-odin/clay.odin']
    subprocess.run(['git', '-C', str(source), 'diff', '--exit-code', 'HEAD', '--', *files], check=True)
    signature = {'root': str(source), 'revision': revision,
                 'sha256': {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in files}}
    if signature['sha256'] != pin['sha256']:
        raise SystemExit('Clay header/binding contents differ from the upstream manifest')
    dest = ROOT / 'build/clay'
    manifest = dest / 'source.json'
    needed = [dest / 'clay.odin', dest / 'clay.o', dest / 'linux/clay.a']
    if not manifest.exists() or json.loads(manifest.read_text()) != signature or not all(p.exists() for p in needed):
        dest.mkdir(parents=True, exist_ok=True)
        (dest / 'linux').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='compile-', dir=dest) as tmp:
            tmp = Path(tmp)
            subprocess.run(['gcc', '-x', 'c', '-DCLAY_IMPLEMENTATION', '-fPIC', '-O2', '-c', str(source / 'clay.h'), '-o', str(tmp / 'clay.o')], check=True)
            subprocess.run(['ar', 'rcs', str(tmp / 'clay.a'), str(tmp / 'clay.o')], check=True)
            (tmp / 'clay.odin').write_bytes((source / files[1]).read_bytes())
            for src, target in [('clay.o', needed[1]), ('clay.a', needed[2]), ('clay.odin', needed[0])]:
                (tmp / src).replace(target)
        manifest.write_text(json.dumps(signature, indent=2) + '\n')
        print(f'Built Clay {revision} from {source}', flush=True)
    if args.test:
        subprocess.run(['python3', str(ROOT / 'scripts/reproduce-clay-contracts.py'), '--known-limitations', '--clay-root', str(source)], check=True)


if __name__ == '__main__':
    main()
