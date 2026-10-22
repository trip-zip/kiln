#!/usr/bin/env python3
"""Exercise the Clay layout with real clients on an owned private socket."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build' / 'verification' / 'clay'


def wait_for(predicate, message, processes=()):
    end = time.monotonic() + 10
    while time.monotonic() < end:
        if predicate():
            return
        if any(p.poll() is not None for p in processes):
            raise RuntimeError(f'Process exited: {message}')
        time.sleep(0.05)
    raise RuntimeError(f'Timed out: {message}')


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    process.wait()


def main():
    global OUT
    OUT.mkdir(parents=True, exist_ok=True)
    OUT = Path(tempfile.mkdtemp(prefix='headless-', dir=OUT))
    processes = []
    files = []
    log_path = OUT / 'headless.log'
    runtime = OUT / 'runtime'
    runtime.mkdir(mode=0o700)
    config = OUT / 'rc.lua'
    config.write_text((ROOT / 'scripts/fixtures/strip.lua').read_text())
    env = dict(os.environ, DBUS_SESSION_BUS_ADDRESS="unix:path="+str(runtime / "bus-unavailable"), WLR_BACKENDS='headless', WLR_LIBINPUT_NO_DEVICES='1',
               XDG_RUNTIME_DIR=str(runtime), KILN_RC=str(config), KILN_SOCK=str(OUT / 'eval.sock'))
    try:
        log = log_path.open('w')
        files.append(log)
        server = subprocess.Popen([str(ROOT / 'build/kiln')], env=env, stdout=log, stderr=log)
        processes.append(server)
        socket = f'kiln-{server.pid}'
        socket_path = Path(env['XDG_RUNTIME_DIR']) / socket
        wait_for(socket_path.exists, 'Wayland socket', processes)
        env['WAYLAND_DISPLAY'] = socket
        for label in ('LEFT', 'RIGHT'):
            client_log = (OUT / f'headless-{label.lower()}.log').open('w')
            files.append(client_log)
            command = f'printf "\\n  {label} terminal\\n\\n  Laid out by Clay\\n\\n"; exec bash --noprofile --norc'
            client = subprocess.Popen(['foot', f'--title=Clay {label}', '--font=monospace:size=14',
                                       'sh', '-c', command], env=dict(env, WAYLAND_DEBUG='client'),
                                      stdout=client_log, stderr=client_log)
            processes.append(client)
            wait_for(lambda: f"Mapped toplevel: Clay {label}" in log_path.read_text(),
                     f"{label} mapped", processes)
        wait_for(lambda: '2 clients' in log_path.read_text(), 'two clients laid out', processes)
        time.sleep(0.5)
        before = [s for s in log_path.read_text().splitlines() if s.startswith('Layout ')]
        time.sleep(1)
        assert before == [s for s in log_path.read_text().splitlines() if s.startswith('Layout ')], 'idle layout loop'
        subprocess.run(['grim', str(OUT / 'headless-two.png')], env=env, check=True, timeout=10)
        print(before[-1])
        print('Idle: no further layout solves')
        stop(processes.pop())
        wait_for(lambda: log_path.read_text().count('1 clients') >= 1 and
                 [s for s in log_path.read_text().splitlines() if s.startswith('Layout ')][-1].find('1 clients') >= 0,
                 'remaining client grows', processes)
        time.sleep(0.3)
        subprocess.run(['grim', str(OUT / 'headless-one.png')], env=env, check=True, timeout=10)
        print([s for s in log_path.read_text().splitlines() if s.startswith('Layout ')][-1])
    finally:
        for process in reversed(processes):
            stop(process)
        for file in files:
            file.close()
    assert server.returncode == 0, log_path.read_text()
    assert not socket_path.exists(), 'socket leaked'
    print('Headless compositor exit: 0; private socket removed')
    print(f'Screenshots: {OUT}')


if __name__ == '__main__':
    main()
