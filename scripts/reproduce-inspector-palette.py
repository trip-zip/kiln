#!/usr/bin/env python3
"""Fail when the pinned public Clay header cannot express the source palette."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
manifest=json.loads((ROOT/'clay-dependency.json').read_text())
clay=Path.home()/'tools'/manifest['checkout']
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=clay,text=True).strip()==manifest['revision']
work=Path(tempfile.mkdtemp(prefix='kiln-inspector-api-',dir='/tmp'))
public=['Clay__debugViewWidth','Clay__debugViewHighlightColor']
palette=['CLAY__DEBUGVIEW_COLOR_'+str(i) for i in range(1,5)]+['CLAY__DEBUGVIEW_COLOR_SELECTED_ROW']
records=[]
for symbol in public+palette:
    source=work/(symbol+'.c')
    source.write_text('#include "clay.h"\nvoid probe(void) { (void)'+symbol+'; }\n')
    p=subprocess.run(['gcc','-std=c11','-Werror','-fsyntax-only','-I',str(clay),str(source)],capture_output=True,text=True)
    records.append(dict(symbol=symbol,status=p.returncode,stderr=p.stderr))
    if symbol in public:assert p.returncode==0,p.stderr
    print(symbol+(': public declaration available' if p.returncode==0 else ': absent from public header'))
receipt=dict(revision=manifest['revision'],probe_dir=str(work),records=records)
out=ROOT/'build/verification/session-19';out.mkdir(parents=True,exist_ok=True)
(out/'inspector-public-api.json').write_text(json.dumps(receipt,indent=2)+'\n')
assert all(r['status']!=0 and 'undeclared' in r['stderr'] for r in records[2:]),records
print('DEFERRED: color1/color2/color3/color4/selected require implementation-only symbols; default palette is the authorized scope')
raise SystemExit(1)
