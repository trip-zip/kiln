"""Execute completion functions against distinct private compositor instances."""
import c_baseline
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
from cli_checks import CONFIG,ROOT


def run(h,client=None,completions=None):
    client=client or ROOT/'build/kiln-client'
    completions=completions or ROOT/'completions'
    records=[]
    with h.boot(CONFIG) as (_,env,_,_),h.boot(CONFIG.replace("name='code'","name='two words'")) as (_,env2,_,_):
        for shell,file in [('bash','kiln-client.bash'),('zsh','_kiln-client'),('fish','kiln-client.fish')]:
            if not shutil.which(shell):
                records.append(dict(shell=shell,status='NOT RUN: shell unavailable'))
                print('NOT RUN:',shell,'syntax and behavior: shell unavailable');continue
            subprocess.run([shell,'-n',str(completions/file)],check=True)
            # Once the verb starts, flags are its own arguments, including --socket.
            for words,want in [(['--json','-s',env2['KILN_SOCK'],'tag','view',''], 'two words'),
                               (['--socket',env2['KILN_SOCK'],'tag','view','tw'],'two words'),
                               (['--json','tag','view',''],'code'),
                               (['-s',env2['KILN_SOCK'],'get','tag',''],'two words'),
                               (['call','client','focused','toggle_'],'toggle_fullscreen'),
                               (['notify','--socket','anything',''],None),
                               (['-s',str(h.out/'absent.sock'),'tag','view',''],None)]:
                args=[str(client),*words]
                quoted=shlex.join(args)
                if shell=='bash':
                    source=f'source {shlex.quote(str(completions/file))}\nCOMP_WORDS=({quoted}); COMP_CWORD={len(args)-1}; _kiln_client; printf "%s\\n" "${{COMPREPLY[@]}}"'
                elif shell=='zsh':
                    # compadd is only valid inside ZLE; capture its real candidate array.
                    source=f'''compadd() {{ if [[ "$1" == -a ]]; then printf '%s\\n' "${{(@P)2}}"; fi }}
words=({quoted}); CURRENT={len(args)}
source {shlex.quote(str(completions/file))}'''
                else:
                    source=f'set -g fish_complete_path; source {shlex.quote(str(completions/file))}; complete -C {shlex.quote(quoted[:-2] if words[-1]=="" else quoted)}'
                p=subprocess.run([shell,'-c',source],env=env,capture_output=True,text=True,timeout=10)
                records.append(dict(shell=shell,words=words,status=p.returncode,stdout=p.stdout,stderr=p.stderr))
                assert p.returncode==0 and not p.stderr,(shell,p.stdout,p.stderr)
                if want:
                    expected=want.replace(' ','\\ ') if shell=='bash' else want
                    assert expected in p.stdout.splitlines(),(shell,words,p.stdout,expected)
                    if want=='two words':assert 'code' not in p.stdout.splitlines(),p.stdout
                else:assert not p.stdout.strip(),(shell,words,p.stdout)
    (h.out/'completion-receipts.json').write_text(json.dumps(records,indent=2)+'\n')
    print('PASS: available shell completion functions, leading options/socket routing, spaces, reflection and quiet absent instance')

if __name__=='__main__':
    import importlib.util
    spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/compat-test.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    out=Path(tempfile.mkdtemp(prefix='kiln-completion-',dir='/tmp'));print(out,flush=True)
    run(mod.Harness(ROOT/'build/kiln',c_baseline.source(),out))
