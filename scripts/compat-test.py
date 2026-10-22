#!/usr/bin/env python3
"""Run Kiln's compatibility checks against private compositor instances."""
import c_baseline
import argparse
import contextlib
import json
import os
from pathlib import Path
import signal
import shutil
import socket
import stat
import subprocess
import tempfile
import time

import inspector_checks
import public_contract_checks
import clay_parity_checks
import cli_checks
import completion_checks
import screenshot_checks
import capture_lifecycle_checks
import install_checks
import lock_checks
import lock_native_checks
import authentication_checks
import lock_protocol_checks
import lock_lifecycle_checks
import lock_input_checks
import idle_checks
import dbus_checks
import declaration_checks
import model_checks
import policy_checks
import paint_checks
import image_checks
import clip_checks
import float_checks
import ui_checks
import layout_checks
import window_state_checks
import input_checks
import async_checks
import reload_checks
import desktop_checks
import stock_checks
import stock_native_checks
import stock_lifetime_checks
import layer_checks
import layer_native_checks
import protocol_checks
import popup_native_checks
import activation_checks
import foreign_checks
import data_checks
import constraint_checks
import cursor_checks
import interaction_lifetime_checks
import output_checks
import density_checks
import output_input_checks
import output_power_checks
import output_lifetime_checks
import xwayland_checks
import xwayland_metadata_checks
import xwayland_transient_checks
import xwayland_bridge_checks
import xwayland_transfer_checks
import xwayland_selection_lifetime_checks
import xwayland_owner_death_checks
import xwayland_drag_checks
import xwayland_game_checks
import xwayland_application_checks
import xwayland_combined_lifetime_checks
import xwayland_active_crash_checks

ROOT = Path(__file__).resolve().parents[1]


def wait_for(predicate, message, server=None):
    end = time.monotonic() + 10
    while time.monotonic() < end:
        if predicate():
            return
        if server is not None and server.poll() is not None:
            raise AssertionError(f'{message}: server exited {server.returncode}')
        time.sleep(.025)
    raise AssertionError(f'timeout: {message}')


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    process.wait(timeout=5)


class Harness:
    def __init__(self, binary, original, out, implementation='odin'):
        self.binary, self.original, self.out = binary, original, out
        self.implementation = implementation
        self.count = 0

    @contextlib.contextmanager
    def boot(self, config='SESSION_VALUE=73', overrides=None, cwd=None, startup=None,
             ready=True, socket_path=None):
        self.count += 1
        work = self.out / f'run-{self.count:02d}'
        work.mkdir()
        runtime = work / 'runtime'
        runtime.mkdir(mode=0o700)
        env = dict(os.environ, WLR_BACKENDS='headless', WLR_LIBINPUT_NO_DEVICES='1',
                   XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
                   XDG_DATA_HOME=str(work / 'data'), XDG_CACHE_HOME=str(work / 'cache'),
                   HOME=str(work / 'home'), KILN_SOCK=str(socket_path or work / 'eval.sock'))
        env['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path=' + str(runtime / 'bus-unavailable')
        if config is not None:
            rc = work / 'rc.lua'
            rc.write_text(config)
            env['KILN_RC'] = str(rc)
        else:
            env.pop('KILN_RC', None)
        for key, value in (overrides or {}).items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = str(value)
        log_path = work / 'server.log'
        with log_path.open('w') as log:
            command = [str(self.binary)]
            if startup is not None:
                command += ['-s', startup]
            server = subprocess.Popen(command, env=env, cwd=cwd or (self.original if self.implementation == 'c' else ROOT), stdout=log, stderr=log)
            env.setdefault('KILN_SOCK', str(runtime / 'kiln.sock'))
            wl_name = f'kiln-{server.pid}'
            env['WAYLAND_DISPLAY'] = wl_name
            try:
                if ready:
                    wait_for(lambda: 'Running Wayland compositor' in log_path.read_text(),
                             'server ready: ' + str(log_path), server)
                    # Ask the owned process so alternate socket naming cannot attach
                    # a fixture to a different compositor.
                    wl_name = self.ev(env, 'return os.getenv("WAYLAND_DISPLAY")').decode().strip()
                    assert wl_name and '/' not in wl_name, wl_name
                    assert (runtime / wl_name).is_socket(), wl_name
                    env['WAYLAND_DISPLAY'] = wl_name
                    (work / 'launch.json').write_text(json.dumps(dict(
                        binary=str(self.binary), pid=server.pid, implementation=self.implementation,
                        runtime=str(runtime), socket=wl_name, ipc=env['KILN_SOCK'],
                        outer=env.get('DISPLAY'), inner=self.ev(env, 'return os.getenv("DISPLAY")').decode().strip(),
                        loaded_libraries=Path(f'/proc/{server.pid}/maps').read_text()), indent=2)+'\n')
                    declaration_checks.settle(log_path)
                yield server, env, work, log_path
            finally:
                stop(server)
            assert not (runtime / wl_name).exists(), 'Wayland socket leaked'

    def ev(self, env, source, timeout=2):
        return subprocess.check_output([str(self.original / 'scripts/kiln-eval'), source],
                                       env=env, timeout=timeout)

    def healthy(self, env):
        assert self.ev(env, '6*7') == b'42\n'

    def connect(self, env, source=None, eof=True):
        peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        peer.settimeout(2)
        peer.connect(env['KILN_SOCK'])
        if source is not None:
            peer.sendall(source)
        if eof:
            peer.shutdown(socket.SHUT_WR)
        return peer

    def quit(self, server, env, log):
        assert self.ev(env, 'core.quit()') == b'\n'
        assert server.wait(timeout=5) == 0, log.read_text()
        assert 'Assertion' not in log.read_text()
        assert 'handle_display_destroy' not in log.read_text()
        assert not Path(env['KILN_SOCK']).exists()

    def protocol(self):
        with self.boot() as (server, env, work, log):
            assert stat.S_IMODE(Path(env['KILN_SOCK']).stat().st_mode) == 0o600
            assert self.ev(env, 'SESSION_VALUE') == b'73\n'
            assert self.ev(env, 'local l = core.output.list(); return (l ~= nil and #l >= 1) and l[1].name or "none"') == b'HEADLESS-1\n'
            assert self.ev(env, 'return #core.output.list()') == b'1\n'
            assert self.ev(env, 'local o = core.output.list()[1]; return type(o.modes)') == b'table\n'
            assert self.ev(env, "local o = core.output.list()[1]; return type(o.scale)..' '..type(o.x)..' '..type(o.y)..' '..type(o.enabled)") == b'number number number boolean\n'
            geometry = self.ev(env, 'local o=core.output.list()[1]; return o.width,o.height,o.refresh,o.scale,o.x,o.y,o.enabled,#o.modes')
            assert geometry == b'1280\t720\t0\t1\t0\t0\ttrue\t0\n', geometry
            print('Output:', geometry.decode().strip())
            assert self.ev(env, 'SESSION_VALUE=SESSION_VALUE+1') == b'\n'
            assert self.ev(env, 'SESSION_VALUE') == b'74\n'
            assert self.ev(env, 'return 1, 2') == b'1\t2\n'
            assert self.ev(env, 'return 1,nil,false,"end",nil') == b'1\tnil\tfalse\tend\tnil\n'
            assert self.ev(env, 'return setmetatable({}, { __tostring = function() error("boom") end }), "after"') == b'?\tafter\n'
            for source in ['return (', 'return nosuchglobal()', 'error({})',
                           'core.spawn(false)']:
                assert self.ev(env, source).startswith(b'ERROR: '), source
                self.healthy(env)
            for argument in ['{}', '{"true",false}']:
                assert self.ev(env, 'return select("#",core.spawn('+argument+'))') == b'0\n'
                self.healthy(env)
            for _ in range(40):
                self.healthy(env)
            with self.connect(env, b'PARTIAL=', eof=False) as partial:
                self.healthy(env)
                assert self.ev(env, 'PARTIAL') == b'nil\n'
                partial.sendall(b'91; return PARTIAL')
                partial.shutdown(socket.SHUT_WR)
                assert partial.recv(100) == b'91\n'
            self.healthy(env)
            with self.connect(env):
                pass
            with self.connect(env, b'EARLY=true', eof=False):
                pass
            self.healthy(env)
            assert self.ev(env, 'return string.rep("x",100000)') == b'x' * 100000 + b'\n'
            assert self.ev(env, 'return "a"..string.char(0).."b"') == b'a\x00b\n'
            request = '--' + 'x' * 100000 + '\nreturn 42'
            assert self.ev(env, request) == b'42\n'
            with self.connect(env, b'return string.rep("x",10000000)'):
                time.sleep(.05)
            self.healthy(env)
            with self.connect(env, b'return string.rep("x",10000000)') as slow:
                time.sleep(.5)
                self.healthy(env)
                start = time.monotonic()
                subprocess.run(['grim', str(work / 'slow-reader.png')], env=env, check=True, timeout=2)
                assert time.monotonic() - start < 2
            self.healthy(env)
            # Drain a large reply to verify writable-event continuation byte for byte.
            with self.connect(env, b'return string.rep("z",1000000)') as peer:
                chunks = []
                while data := peer.recv(16384):
                    chunks.append(data)
                assert b''.join(chunks) == b'z' * 1000000 + b'\n'
            self.healthy(env)
            # A broken reply helper must still answer through the protected boundary.
            assert self.ev(env, 'saved_eval=kiln_eval; kiln_eval=function() kiln_eval=saved_eval; error("reply helper") end') == b'\n'
            assert self.ev(env, '1').startswith(b'ERROR: ')
            self.healthy(env)
            self.quit(server, env, log)
        print('PASS: wire framing, errors, recovery, repeated peers, long replies and nonblocking I/O')

    def configs(self):
        base = self.out / 'precedence'
        base.mkdir()
        # Missing-datadir cases must not discover a real installation on the host.
        binary = base / 'kiln'
        subprocess.run(['odin', 'build', '.', '-collection:deps=build',
                        '-define:KILN_DATADIR='+str(base/'absent-datadir'),
                        '-out:'+str(binary), '-extra-linker-flags:-Wl,--export-dynamic'],
                       cwd=ROOT, check=True, timeout=60)
        suite = type(self)(binary.resolve(), self.original, base)
        xdg, home, cwd = base / 'xdg', base / 'home', base / 'cwd'
        for path in [xdg / 'kiln', home / '.config/kiln', cwd]:
            path.mkdir(parents=True)
        (xdg / 'kiln/rc.lua').write_text('ORIGIN="xdg"')
        (home / '.config/kiln/rc.lua').write_text('ORIGIN="home"')
        (cwd / 'kilnrc.lua').write_text('ORIGIN="cwd"')
        cases = [({'KILN_RC': None, 'XDG_CONFIG_HOME': xdg}, b'xdg\n'),
                 ({'KILN_RC': '', 'XDG_CONFIG_HOME': xdg}, b'xdg\n'),
                 ({'KILN_RC': None, 'XDG_CONFIG_HOME': None}, b'home\n'),
                 ({'KILN_RC': None, 'XDG_CONFIG_HOME': ''}, b'home\n'),
                 ({'KILN_RC': None, 'XDG_CONFIG_HOME': base / 'absent'}, b'cwd\n')]
        for overrides, expected in cases:
            overrides['HOME'] = home
            with suite.boot(config=None, overrides=overrides, cwd=cwd) as (server, env, work, log):
                assert suite.ev(env, 'ORIGIN') == expected
                suite.quit(server, env, log)
        with suite.boot('ORIGIN="explicit"', overrides={'HOME': home, 'XDG_CONFIG_HOME': xdg}, cwd=cwd) as (server, env, work, log):
            assert suite.ev(env, 'ORIGIN') == b'explicit\n'
            suite.quit(server, env, log)
        for config, overrides in [(None, {'KILN_RC': base / 'missing.lua'}),
                                  ('ORIGIN="before error"; error("config failure")', {}),
                                  ('return (', {})]:
            with suite.boot(config, overrides=overrides, cwd=cwd) as (server, env, work, log):
                assert 'cannot load' in log.read_text()
                assert suite.ev(env, 'ORIGIN') == (b'before error\n' if config and 'config failure' in config else b'nil\n')
                suite.healthy(env)
                suite.quit(server, env, log)
        (cwd / 'helper.lua').write_text('return 57')
        explicit = cwd / 'module-config.lua'
        explicit.write_text('ORIGIN=require("helper")')
        with suite.boot(None, overrides={'KILN_RC': explicit}) as (server, env, work, log):
            assert suite.ev(env, 'ORIGIN') == b'57\n'
            suite.quit(server, env, log)
        for _ in range(3):
            with suite.boot() as (server, env, work, log):
                suite.quit(server, env, log)
        with suite.boot('core.quit(); core.quit()', ready=False) as (server, env, work, log):
            assert server.wait(timeout=5) == 0, log.read_text()
            assert 'loaded ' in log.read_text()
            assert not Path(env['KILN_SOCK']).exists()
        print('PASS: isolated config precedence, missing/broken configs, require path, three clean quits, startup quit')

    def spawning(self):
        with self.boot((ROOT / "kilnrc.lua").read_text()) as (server, env, work, log):
            for table in [False, True]:
                receipt = work / ('argv.txt' if table else 'shell.txt')
                command = 'printf "%s\\n%s\\n" "$WAYLAND_DISPLAY" "$KILN_SOCK" > ' + str(receipt)
                argument = '{"sh","-c",' + json.dumps(command) + '}' if table else json.dumps(command)
                assert self.ev(env, 'return select("#",core.spawn(' + argument + '))') == b'0\n'
                wait_for(receipt.exists, 'spawn receipt', server)
                wait_for(lambda: len(receipt.read_text().splitlines()) == 2, 'spawn receipt complete', server)
                assert receipt.read_text().splitlines() == [env['WAYLAND_DISPLAY'], env['KILN_SOCK']]
            numeric = work / 'numeric-argv.txt'
            command = f'printf %s "$1" > {numeric}'
            assert self.ev(env, 'core.spawn({"sh","-c",'+json.dumps(command)+',"sh",42})') == b'\n'
            wait_for(lambda: numeric.exists() and numeric.read_text() == '42', 'numeric argv', server)
            pidfile = work / 'foot.pid'
            command = f'echo $$ > {pidfile}; exec foot --title=IPC-FOOT --font=monospace:size=14 sh -c \'printf "\\n  Lua IPC spawn\\n\\n  Clay layout preserved\\n"; exec sh\''
            assert self.ev(env, 'core.spawn('+json.dumps(command)+')') == b'\n'
            wait_for(lambda: 'Mapped toplevel: IPC-FOOT' in log.read_text(), 'IPC foot mapped', server)
            foot_fd = os.pidfd_open(int(pidfile.read_text()))
            try:
                time.sleep(.4)
                subprocess.run(['grim', str(work / 'ipc-foot.png')], env=env, check=True, timeout=5)
                assert '1 clients' in log.read_text()
                # An incomplete request must not prevent another client mapping or a frame capture.
                with self.connect(env, b'return ', eof=False):
                    subprocess.run(['grim', str(work / 'partial-request.png')], env=env, check=True, timeout=2)
                    self.healthy(env)
                self.quit(server, env, log)
            finally:
                try:
                    signal.pidfd_send_signal(foot_fd, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                os.close(foot_fd)
            print('Screenshot:', (work / 'ipc-foot.png').resolve())
        receipt = self.out / 'startup-command.txt'
        with self.boot(startup=f'printf startup > {receipt}') as (server, env, work, log):
            wait_for(receipt.exists, '-s command', server)
            assert receipt.read_text() == 'startup'
            self.quit(server, env, log)
        config_receipt = self.out / 'config-spawn.txt'
        command = f'printf "%s\\n%s\\n" "$WAYLAND_DISPLAY" "$KILN_SOCK" > {config_receipt}'
        with self.boot('core.spawn('+json.dumps(command)+'); core.quit()', ready=False) as (server, env, work, log):
            assert server.wait(timeout=5) == 0
            wait_for(lambda: config_receipt.exists() and len(config_receipt.read_text().splitlines()) == 2,
                     'config spawn environment')
            assert config_receipt.read_text().splitlines() == [env['WAYLAND_DISPLAY'], env['KILN_SOCK']]
            assert not Path(env['KILN_SOCK']).exists()
        print('PASS: string/argv spawn, child environment, foot maps, -s and config-time spawn')

    def ownership(self):
        with self.boot() as (server, env, work, log):
            path = Path(env['KILN_SOCK'])
            inode = path.stat().st_ino
            with self.boot(socket_path=path, ready=False) as (other, _, _, other_log):
                assert other.wait(timeout=5) == 1
                assert 'Cannot create IPC socket' in other_log.read_text()
            assert path.stat().st_ino == inode
            self.healthy(env)
            # Hold a peer open through teardown, then replace the path independently.
            with self.connect(env, b'42', eof=False):
                moved = path.with_suffix('.owned')
                path.rename(moved)
                replacement = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                try:
                    replacement.bind(str(path))
                    server.terminate()
                    assert server.wait(timeout=5) == 0
                    assert path.exists(), 'removed replacement socket'
                finally:
                    replacement.close()
                    path.unlink()
                    moved.unlink()
        with self.boot(overrides={'KILN_SOCK': None}) as (server, env, work, log):
            assert env['KILN_SOCK'] == str(work / 'runtime/kiln.sock')
            assert self.ev(env, 'os.getenv("KILN_SOCK")') == env['KILN_SOCK'].encode() + b'\n'
            self.quit(server, env, log)
        for bad_path in ['', '/tmp/' + 'x' * 110]:
            with self.boot(overrides={'KILN_SOCK': bad_path}, ready=False) as (server, env, work, log):
                assert server.wait(timeout=5) == 1
                assert 'Cannot create IPC socket' in log.read_text()
        stale = self.out / 'stale.sock'
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
            peer.bind(str(stale))
        inode = stale.stat().st_ino
        with self.boot(socket_path=stale, ready=False) as (server, env, work, log):
            assert server.wait(timeout=5) == 1
            assert stale.stat().st_ino == inode
        stale.unlink()
        print('PASS: socket defaults, invalid paths, collisions, pending-peer cleanup and replacement inode preservation')


def check_installed(original, out):
    work = out / 'installed'
    work.mkdir()
    datadir = work / 'share'
    (datadir / 'lua').mkdir(parents=True)
    (datadir / 'rc.lua').write_text('ORIGIN="installed"')
    (datadir / 'lua/installed_helper.lua').write_text('return 83')
    binary = work / 'kiln'
    command = ['odin', 'build', '.', '-collection:deps=build', '-out:'+str(binary),
               '-define:KILN_DATADIR='+str(datadir), '-extra-linker-flags:-Wl,--export-dynamic']
    print('Installed-config build:', ' '.join(command), flush=True)
    subprocess.run(command, cwd=ROOT, check=True, timeout=60)
    suite = Harness(binary, original, work)
    with suite.boot(None) as (server, env, _, log):
        assert suite.ev(env, 'ORIGIN') == b'installed\n'
        suite.quit(server, env, log)
    with suite.boot('ORIGIN=require("installed_helper")') as (server, env, _, log):
        assert suite.ev(env, 'ORIGIN') == b'83\n'
        suite.quit(server, env, log)
    xdg = work / 'xdg/kiln'
    xdg.mkdir(parents=True)
    (xdg / 'rc.lua').write_text('ORIGIN="xdg"')
    with suite.boot(None, overrides={'XDG_CONFIG_HOME': xdg.parent}) as (server, env, _, log):
        assert suite.ev(env, 'ORIGIN') == b'xdg\n'
        suite.quit(server, env, log)
    shutil.copytree(ROOT / 'lua/kiln', datadir / 'lua/kiln')
    (datadir / 'rc.lua').write_text((ROOT / 'kilnrc.lua').read_text())
    with suite.boot(None, cwd=work) as (server, env, _, log):
        declaration_checks.wait(suite, env, 'return #screen.all()[1].tags', b'5\n', server)
        assert suite.ev(env, 'return type(require("kiln").on)') == b'function\n'
        path=suite.ev(env,'return package.path')
        (datadir/'rc.lua').write_text((ROOT/'kilnrc.lua').read_text()+"\nINSTALLED_RELOAD=true\n")
        assert suite.ev(env, 'require("kiln").reload();return true') == b'true\n'
        declaration_checks.wait(suite,env,'return INSTALLED_RELOAD',b'true\n',server)
        declaration_checks.wait(suite,env,'return #screen.all()[1].tags',b'5\n',server)
        assert suite.ev(env,'return package.path')==path
        suite.quit(server, env, log)
    (datadir / 'rc.lua').write_text('error("installed broken")')
    with suite.boot(None) as (server, env, _, log):
        assert 'installed broken' in log.read_text()
        assert 'stack traceback:' in log.read_text()
        suite.healthy(env)
        suite.quit(server, env, log)
    (datadir / 'rc.lua').unlink()
    cwd = work / 'cwd'
    cwd.mkdir()
    (cwd / 'kilnrc.lua').write_text('ORIGIN="cwd"')
    with suite.boot(None, cwd=cwd) as (server, env, _, log):
        assert suite.ev(env, 'ORIGIN') == b'cwd\n'
        suite.quit(server, env, log)
    print('PASS: compiled datadir precedence, module path, broken installed config and source fallback')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=os.environ.get('KILN_BINARY', ROOT / 'build/kiln'))
    parser.add_argument('--original', type=Path, default=c_baseline.source())
    parser.add_argument('--output', type=Path, default=ROOT / 'build/verification/runtime')
    parser.add_argument('--check-installed', action='store_true', help='also build and test an isolated KILN_DATADIR variant')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='session-', dir=args.output.resolve()))
    # Socket names stay below sockaddr_un.sun_path even with a deep checkout.
    with tempfile.TemporaryDirectory(prefix='ko-', dir='/tmp') as short:
        alias = Path(short) / 'evidence'
        alias.symlink_to(out, target_is_directory=True)
        suite = Harness(args.binary.resolve(), args.original.resolve(), alias)
        print('Artifacts:', out, flush=True)
        clay_parity_checks.run(suite)
        public_contract_checks.run(suite)
        inspector_checks.run(suite)
        cli_checks.run(suite)
        completion_checks.run(suite)
        screenshot_checks.run(suite)
        capture_lifecycle_checks.run(suite)
        suite.protocol()
        suite.configs()
        suite.spawning()
        suite.ownership()
        declaration_checks.run(suite)
        model_checks.run(suite)
        policy_checks.run(suite)
        paint_checks.run(suite)
        image_checks.run(suite)
        clip_checks.run(suite)
        float_checks.run(suite)
        ui_checks.run(suite)
        layout_checks.run(suite)
        window_state_checks.run(suite)
        input_checks.run(suite)
        async_checks.run(suite)
        reload_checks.run(suite)
        desktop_checks.run(suite)
        stock_checks.run(suite)
        stock_native_checks.run(suite)
        stock_lifetime_checks.run(suite)
        layer_checks.run(suite)
        layer_native_checks.run(suite)
        protocol_checks.run(suite)
        popup_native_checks.run(suite)
        activation_checks.run(suite)
        foreign_checks.run(suite)
        data_checks.run(suite)
        constraint_checks.run(suite)
        cursor_checks.run(suite)
        interaction_lifetime_checks.run(suite)
        output_checks.run(suite)
        density_checks.run(suite)
        output_input_checks.run(suite)
        output_power_checks.run(suite)
        output_lifetime_checks.run(suite)
        xwayland_checks.run(suite)
        xwayland_metadata_checks.run(suite)
        xwayland_transient_checks.run(suite)
        if args.check_installed:
            check_installed(args.original.resolve(), alias)
            install_checks.run(suite)
        idle_checks.run(suite)
        lock_checks.run(suite)
        authentication_checks.run(suite)
        lock_protocol_checks.run(suite)
        lock_native_checks.run(suite)
        lock_lifecycle_checks.run(suite)
        lock_input_checks.run(suite)
        dbus_checks.run(suite)
        xwayland_bridge_checks.run(suite, known_limitation=True)
        xwayland_transfer_checks.run(suite, known_bug=True)
        xwayland_selection_lifetime_checks.run(suite)
        xwayland_drag_checks.run(suite)
        xwayland_owner_death_checks.run(suite, known_bug=True)
        xwayland_game_checks.run(suite)
        xwayland_combined_lifetime_checks.run(suite)
        xwayland_active_crash_checks.run(suite)
        xwayland_application_checks.run(suite)
    print('PASS: compatibility subset; artifacts:', out)


if __name__ == '__main__':
    main()
