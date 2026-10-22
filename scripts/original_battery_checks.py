"""Run reviewed original shell batteries in an isolated disposable checkout."""
import c_baseline
import argparse
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
REVIEWED={'quit','bar','widget','popup','launcher','pipe','poll','model','cache-soak','sweep-soak'}


def run(original,binary,names,implementation='odin'):
    assert set(names)<=REVIEWED, 'review process ownership and external effects before extending the list'
    out=Path(tempfile.mkdtemp(prefix='kiln-original-batteries-'))
    print(out,flush=True)
    checkout=out/'checkout';checkout.mkdir()
    (checkout/'build').mkdir();(checkout/'scripts').mkdir()
    shutil.copy2(binary,checkout/'build/kiln')
    library=original if implementation=='c' else ROOT
    (checkout/'lua').symlink_to(library/'lua',target_is_directory=True)
    (checkout/'kilnrc.lua').symlink_to(library/'kilnrc.lua')
    (checkout/'scripts/kiln-eval').symlink_to(original/'scripts/kiln-eval')
    (checkout/'scripts/soak-cache.lua').symlink_to(original/'scripts/soak-cache.lua')
    receipts=[]
    for name in names:
        work=out/name;work.mkdir()
        runtime=work/'runtime';runtime.mkdir(mode=0o700)
        filename=name+'.sh' if name.endswith('-soak') else name+'-test.sh'
        source=original/'scripts'/filename
        script=checkout/'scripts'/filename
        text=source.read_text()
        assert 'rm -rf "$work"' in text
        adaptations=['executable/library checkout','private environment','retain work directory']
        if name=='sweep-soak':
            text=text.replace('kiln_real=$(pgrep -nx kiln)','kiln_real=$kiln_pid')
            text=text.replace('"$repo/scripts/solve-rollup.sh" "$log"',': # Metrics already printed above.')
            adaptations+=['owned compositor PID, never process-name lookup','omit C-only reporting helper']
            if implementation=='odin':
                text=text.replace("'solve #'","'^Layout '")
                adaptations+=['count Odin Layout lines instead of C solve lines']
        if name=='cache-soak' and implementation=='odin':
            old="gauge() { grep 'solve #' \"$log\" | tail -1 | sed 's/.*rnodes=/rnodes=/'; }"
            # Both implementations report residency in bytes; the original checks use KiB.
            new='''gauge() { python3 - "$log" <<'PY'
import re,sys
text=open(sys.argv[1]).read()
images=int(re.findall(r'Images: decodes \\d+, resident (\\d+)',text)[-1])
raster=int(re.findall(r'Paint HEADLESS-1:.*live bytes (\\d+)',text)[-1])
print('images_kb='+str(images//1024)+' raster_kb='+str(raster//1024))
PY
}'''
            assert old in text
            text=text.replace(old,new)
            text=text.replace("grep 'solve #' \"$log\" | tail -1 | sed 's/.*, \\([0-9]*\\) mutations.*/\\1/'", "grep '^Paint HEADLESS-1:' \"$log\" | tail -1 | sed 's/.*mutations \\([0-9]*\\),.*/\\1/'")
            adaptations+=['read Odin image/raster residency and mutation diagnostics, preserve thresholds']
        # Preserve every assertion and the script's PID-owned cleanup, retaining artifacts.
        text=text.replace('rm -rf "$work"','printf "%s\\n" "$work" > "$AUDIT_WORK"')
        script.write_text(text)
        env=dict(os.environ,HOME=str(work/'home'),XDG_CONFIG_HOME=str(work/'config'),
                 XDG_DATA_HOME=str(work/'data'),XDG_CACHE_HOME=str(work/'cache'),
                 XDG_RUNTIME_DIR=str(runtime),DBUS_SESSION_BUS_ADDRESS='unix:path='+str(runtime/'absent-bus'),
                 AUDIT_WORK=str(work/'artifacts.txt'))
        for key in ('DISPLAY','WAYLAND_DISPLAY','KILN_RC','KILN_SOCK'):env.pop(key,None)
        with (work/'battery.log').open('w') as log:
            result=subprocess.run(['timeout','--kill-after=5','180','sh',str(script)],env=env,cwd=checkout,stdout=log,stderr=log)
        receipts.append(dict(battery=name,status=result.returncode,log=str(work/'battery.log'),
                             source=str(source),adaptation=adaptations))
        (out/'receipts.json').write_text(json.dumps(receipts,indent=2)+'\n')
        print(name,result.returncode,flush=True)
    return all(r['status']==0 for r in receipts)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('names',nargs='+',choices=sorted(REVIEWED))
    parser.add_argument('--original',type=Path,default=c_baseline.source())
    parser.add_argument('--binary',type=Path,default=ROOT/'build/kiln')
    parser.add_argument('--implementation',choices=['odin','c'],default='odin')
    args=parser.parse_args()
    raise SystemExit(0 if run(args.original.resolve(),args.binary.resolve(),args.names,args.implementation) else 1)
