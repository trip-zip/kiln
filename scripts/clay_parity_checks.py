"""Compare clipping and floating behavior in private C/Odin compositor instances."""
import c_baseline
import importlib.util
import json
from pathlib import Path
import tempfile
import time
from paint_checks import screenshot
from float_checks import CONFIG
ROOT=Path(__file__).resolve().parents[1]

def probe(h):
    rows=[]
    with h.boot("require('kiln')\n"+CONFIG) as (server,env,work,log):
        for label,change in [('inherited-pass',''),('inherited-capture','PASS=false'),('escaped','INHERIT=false')]:
            h.ev(env,change+';core.dirty()' if change else 'core.dirty()');time.sleep(.15)
            im=screenshot(env,work/(label+'.png'))
            points=[(70,70),(70,150),(145,70),(145,150),(250,130)]
            rows.append(dict(case=label,pixels=[list(im.getpixel(p)) for p in points],hits=[h.ev(env,f'local a={{}};for _,v in ipairs(core.hits("HEADLESS-1",{x},{y})) do if v.name~="" then a[#a+1]=v.name end end;return table.concat(a,",")').decode().strip() for x,y in points]))
        h.quit(server,env,log)
    return rows

def run(h):
    out=h.out/'clay-parity';out.mkdir()
    results={}
    if h.original.resolve()==c_baseline.source():c_baseline.build()
    for impl,binary in [('c',h.original/'build/kiln'),('odin',h.binary)]:
        folder=out/impl;folder.mkdir()
        results[impl]=probe(type(h)(binary,h.original,folder,implementation=impl))
    (out/'comparison.json').write_text(json.dumps(results,indent=2)+'\n')
    expected=json.loads((ROOT/'scripts/clay-live-baseline.json').read_text())
    assert results==expected,(results,expected)
    print('PASS: C/Odin inherited float scissors, capture/passthrough, escape, attachment and paint/hit observations:',out)

def main():
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    out=Path(tempfile.mkdtemp(prefix='kiln-clay-parity-',dir='/tmp'));print(out,flush=True)
    run(m.Harness(ROOT/'build/kiln',c_baseline.source(),out))
if __name__=='__main__':main()
