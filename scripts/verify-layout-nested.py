#!/usr/bin/env python3
"""Verify nested resize and click focus; temporarily takes focus and moves the pointer."""
import os
import re
import shlex
import subprocess
import tempfile
import time
from pathlib import Path
from importlib.util import spec_from_file_location, module_from_spec

spec = spec_from_file_location('verify', Path(__file__).with_name('verify-layout.py'))
verify = module_from_spec(spec)
spec.loader.exec_module(verify)
ROOT, OUT = verify.ROOT, verify.OUT
host = dict(os.environ, SOMEWM_SOCKET=os.environ.get('SOMEWM_SOCKET', '/run/user/1000/somewm-socket'))


def ipc(code):
    result = subprocess.run(['somewm-client', 'eval', ' '.join(code.splitlines())], env=host,
                            capture_output=True, text=True)
    if result.returncode != 0 or not result.stdout.startswith('OK\n'):
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout.removeprefix('OK\n').strip()


GUARD = '''local s=_kiln_clay_verify; local m=mouse.coords();
assert(m.x==s.pointer.x and m.y==s.pointer.y,"pointer changed");
assert(client.focus==s.window,"focus changed"); '''


def main():
    global OUT
    OUT.mkdir(parents=True, exist_ok=True)
    OUT = Path(tempfile.mkdtemp(prefix='nested-', dir=OUT))
    print(f'Artifacts: {OUT}')
    processes, files = [], []
    log_path = OUT / 'nested.log'
    print(ipc('assert(_kiln_clay_verify==nil); _kiln_clay_verify={previous=client.focus,pointer=mouse.coords()}; return "Saved host focus"'))
    try:
        log = log_path.open('w')
        files.append(log)
        env = dict(os.environ, DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent/kiln-private-bus", WLR_BACKENDS='wayland', WLR_LIBINPUT_NO_DEVICES='1',
                   KILN_RC=str(ROOT / 'kilnrc.lua'), KILN_SOCK=str(OUT / 'eval.sock'))
        server = subprocess.Popen([str(ROOT / 'build/kiln')], env=env, stdout=log, stderr=log)
        processes.append(server)
        socket = f'kiln-{server.pid}'
        socket_path = Path(env['XDG_RUNTIME_DIR']) / socket
        verify.wait_for(lambda: 'Running Wayland compositor' in log_path.read_text(), 'nested output ready', processes)
        print(ipc('''local s=_kiln_clay_verify; local m=mouse.coords();
assert(m.x==s.pointer.x and m.y==s.pointer.y,"pointer changed");
local target=screen[1]; for out in screen do if out.geometry.x>target.geometry.x then target=out end end;
for _,c in ipairs(client.get()) do if c.pid==''' + str(server.pid) + ''' then
assert(client.focus==s.previous or client.focus==c,"focus changed");
s.window=c; c.floating=true; c.screen=target; c:tags({target.selected_tag});
c:geometry({x=target.geometry.x+300,y=target.geometry.y+200,width=1280,height=720});
c:raise(); client.focus=c; return "Nested window on screen "..target.index end end; error("missing nested window")'''))
        env['WAYLAND_DISPLAY'] = socket
        for label in ('LEFT', 'RIGHT'):
            receipt = OUT / f'nested-{label.lower()}-receipt.txt'
            receipt.write_text('')
            command = (f'printf "\\n  {label} terminal\\n\\n  Waiting for click and keyboard input...\\n\\n"; '
                       'while IFS= read -r line; do printf "Received: %s\\n" "$line"; '
                       f'printf "%s\\n" "$line" >> {shlex.quote(str(receipt))}; done')
            client_log = (OUT / f'nested-{label.lower()}.log').open('w')
            files.append(client_log)
            client = subprocess.Popen(['foot', f'--title=Clay {label}', '--font=monospace:size=14',
                                       'sh', '-c', command], env=dict(env, WAYLAND_DEBUG='client'),
                                      stdout=client_log, stderr=client_log)
            processes.append(client)
            verify.wait_for(lambda: f'Mapped toplevel: Clay {label}' in log_path.read_text(), label, processes)
        verify.wait_for(lambda: '2 clients' in log_path.read_text(), 'two clients', processes)
        time.sleep(0.3)
        print(ipc(GUARD + 's.window:geometry({width=1000,height=600}); return "Resized nested window to 1000x600"'))
        verify.wait_for(lambda: re.search(r'Layout WL-1: 1000x[0-9]+, 2 clients', log_path.read_text()) is not None, 'resized layout', processes)
        time.sleep(0.3)
        stable = [line for line in log_path.read_text().splitlines() if line.startswith('Layout ')]
        for label, x, word in [('LEFT', 200, 'alpha'), ('RIGHT', 750, 'beta')]:
            print(ipc(GUARD + f'''local g=s.window:geometry();
root.fake_input("motion_notify",false,g.x+{x},g.y+200); s.pointer=mouse.coords();
root.fake_input("button_press",1); root.fake_input("button_release",1);
return "Clicked {label} cell"'''))
            time.sleep(0.15)
            keys = ','.join('"' + c + '"' for c in word) + ',"Return"'
            print(ipc(GUARD + f'''for _,k in ipairs({{{keys}}}) do
root.fake_input("key_press",k); root.fake_input("key_release",k) end; return "Typed {word}"'''))
            receipt = OUT / f'nested-{label.lower()}-receipt.txt'
            verify.wait_for(lambda: receipt.read_text() == word + '\n', f'{label} keyboard receipt', processes)
            print(f'{label} received: {receipt.read_text().strip()}')
        time.sleep(0.3)
        assert stable == [line for line in log_path.read_text().splitlines() if line.startswith('Layout ')], 'client repaint triggered layout'
        print('Client repaints and focus changes caused no layout solves')
        subprocess.run(['grim', str(OUT / 'nested-two.png')], env=env, check=True, timeout=10)
        geometry = ipc('local g=_kiln_clay_verify.window:geometry(); return string.format("%d,%d %dx%d",g.x,g.y,g.width,g.height)')
        subprocess.run(['grim', '-g', geometry, str(OUT / 'nested-visible.png')], env=host, check=True, timeout=10)
        verify.stop(processes.pop())
        verify.wait_for(lambda: [line for line in log_path.read_text().splitlines() if line.startswith('Layout ')][-1].find('1 clients') >= 0,
                        'one client fills row', processes)
        time.sleep(0.3)
        subprocess.run(['grim', str(OUT / 'nested-one.png')], env=env, check=True, timeout=10)
        print([line for line in log_path.read_text().splitlines() if line.startswith('Layout ')][-1])
    finally:
        try:
            print(ipc('''local s=_kiln_clay_verify;
if s and s.window and s.window.valid and client.focus==s.window and s.previous and s.previous.valid then client.focus=s.previous end;
_kiln_clay_verify=nil; return "Released test focus"'''))
        finally:
            for process in reversed(processes):
                verify.stop(process)
            for file in files:
                file.close()
    assert server.returncode == 0, log_path.read_text()
    assert not socket_path.exists(), 'socket leaked'
    print('Nested compositor exit: 0; private socket removed')


if __name__ == '__main__':
    main()
