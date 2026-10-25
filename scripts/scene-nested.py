#!/usr/bin/env python3
"""Exercise native repaint, layer shell and xdg popups in a private nested Kiln."""
# Requires Pillow (PIL).
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
sys.dont_write_bytecode = True
import subprocess
import time
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('capture', ROOT / 'scripts/scene-readback.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
evaluate = capture.evaluate


def handles(sock):
    return set(evaluate(sock, "local t={};for _,c in ipairs(client.all()) do if c.app_id=='kiln' then t[#t+1]=c.handle end end;return table.concat(t,',')").strip().split(',')) - {''}


def reveal(sock, handle):
    evaluate(sock, f"for _,c in ipairs(client.all()) do if c.handle=={int(handle)} then c.tag=screen.focused.selected_tag;c.floating=true;c.float={{x=160,y=100,width=1000,height=700}} end end")


def wait_for(test, processes, timeout=15):
    deadline = time.monotonic() + timeout
    while not test():
        if time.monotonic() > deadline or any(p.poll() is not None for p in processes):
            raise RuntimeError('timeout or child exited')
        time.sleep(.05)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--parent-display', required=True)
    parser.add_argument('--parent-sock', required=True)
    parser.add_argument('--layer-client', type=Path, required=True)
    parser.add_argument('--popup-client', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    runtime = out / 'runtime'
    runtime.mkdir(mode=0o700, exist_ok=True)
    config = out / 'rc.lua'
    config.write_text("""local kiln=require('kiln')
screen.on('added',function(s)
    local t=tag.new{name='scene',screen=s,layout=kiln.layout.tile};t:view()
end)
""")
    sock = out / 'eval.sock'
    env = dict(os.environ, KILN_TEST_BACKEND='nested', KILN_BACKEND='nested',
               WAYLAND_DISPLAY=args.parent_display, XDG_RUNTIME_DIR=str(runtime),
               KILN_SOCK=str(sock), KILN_PAINT_DEBUG='1', KILN_RC=str(config),
               HOME=str(out/'home'), XDG_CONFIG_HOME=str(out/'config'),
               XDG_CACHE_HOME=str(out/'cache'), XDG_DATA_HOME=str(out/'data'),
               DBUS_SESSION_BUS_ADDRESS=f'unix:path={runtime}/absent')
    processes, logs = [], []

    def launch(command, name, child_env):
        log = (out / f'{name}.log').open('w')
        logs.append(log)
        p = subprocess.Popen(command, cwd=ROOT, env=child_env, stdout=log, stderr=log)
        processes.append(p)
        (out / f'{name}.pid').write_text(str(p.pid))
        return p

    try:
        before = handles(args.parent_sock)
        kiln = launch([str(ROOT/'build/kiln')], 'kiln', env)
        wait_for(lambda: bool(handles(args.parent_sock)-before), [kiln])
        new = handles(args.parent_sock)-before
        assert len(new) == 1, f'ambiguous new windows: {new}'
        reveal(args.parent_sock, next(iter(new)))
        wait_for(lambda: sock.exists() and 'First frame committed' in (out/'kiln.log').read_text(), [kiln])
        child_env = dict(env, WAYLAND_DISPLAY=f'kiln-{kiln.pid}')
        child_env.pop('KILN_BACKEND', None)
        bar = launch([str(args.layer_client), '--namespace', 'own-scene-bar', '--keyboard', 'none',
                      '--anchor', 'top,left,right', '--size', '0,32', '--exclusive-zone', '32',
                      '--color', 'ff358879', '--configure-report', str(out/'bar-size.txt')], 'bar', child_env)
        # A fixed title keeps terminal repaint independent of compositor layout.
        foot = launch(['foot', '--config=/dev/null', '--app-id=own-scene-foot', '--title=Own scene repaint',
                       'sh', '-c', "i=0; while [ $i -lt 240 ]; do printf '\\033[H\\033[2JNative client repaint: %04d\\nFrame callbacks drive this terminal.\\n' $i; i=$((i+1)); sleep 0.05; done; sleep 60"], 'foot', child_env)
        popup = launch([str(args.popup_client)], 'popup', child_env)
        wait_for(lambda: evaluate(sock, 'return #client.all()').strip() == '2', processes)
        evaluate(sock, "for _,c in ipairs(client.all()) do if c.app_id=='popup_test' then c.floating=true;c.float={x=100,y=120,width=260,height=220} end end")
        time.sleep(.4)
        popup.send_signal(signal.SIGUSR1)
        wait_for(lambda: 'popup configured' in (out/'popup.log').read_text(), processes)
        time.sleep(1)
        facts = evaluate(sock, "local t={};for _,c in ipairs(client.all()) do t[#t+1]=tostring(c.handle)..':'..tostring(c.app_id)..':'..tostring(c.mapped) end;return table.concat(t,'\\n')")
        (out/'clients.txt').write_text(facts)
        def shot(name):
            path = out/f'{name}.png'
            evaluate(sock, f'local o=core.output.list()[1];return core.screenshot(o.name,{json.dumps(str(path))})')
            return Image.open(path).convert('RGBA')
        output_name=evaluate(sock,'return core.output.list()[1].name').strip()
        subprocess.run(['grim','-o',output_name,str(out/'screencopy.png')],env=child_env,check=True,timeout=10)
        first = shot('repaint-before')
        log_before = (out/'kiln.log').read_text()
        time.sleep(1)
        second = shot('repaint-after')
        log_after = (out/'kiln.log').read_text()
        differences = sum(a != b for a,b in zip(first.get_flattened_data(),second.get_flattened_data()))
        count = lambda text,prefix: sum(line.startswith(prefix) for line in text.splitlines())
        result = dict(differing_pixels=differences,
                      passes_before=count(log_before,'Render '),passes_after=count(log_after,'Render '),
                      layouts_before=count(log_before,'Layout '),layouts_after=count(log_after,'Layout '),
                      bar_before=first.getpixel((10,10)),bar_after=second.getpixel((10,10)),
                      popup_log=(out/'popup.log').read_text())
        (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result,indent=2),flush=True)
        assert Image.open(out/'screencopy.png').size==first.size, 'screencopy dimensions'
        popup_pixels=sum(pixel[:3]==(64,128,192) for pixel in second.get_flattened_data())
        print(f'Popup color pixels: {popup_pixels}',flush=True)
        assert popup_pixels == 120*120, 'unexpected popup coverage'
        assert differences>0, 'client did not repaint'
        assert result['passes_after']>result['passes_before'], 'no render passes'
        assert result['layouts_after']==result['layouts_before'], 'client repaint repeated Clay solve'
        assert result['bar_before']==result['bar_after']==(53,136,121,255), 'layer-shell bar was not displayed'
        assert 'Assertion' not in log_after and 'Failed to' not in log_after, log_after
        # Exercise child teardown before the compositor, including the popup. The bar exits on compositor disconnect.
        for p in [popup,foot]:
            p.terminate()
            p.wait(timeout=5)
        time.sleep(.3)
        assert kiln.poll() is None, (out/'kiln.log').read_text()
        evaluate(sock, 'core.dirty()')
        time.sleep(.2)
        idle_before = (out/'kiln.log').read_text()
        time.sleep(1)
        idle_after = (out/'kiln.log').read_text()
        paints = [line for line in idle_after.splitlines() if line.startswith('Paint ')]
        idle = paints[-1] + f'\nPasses before/after 1s idle: {count(idle_before,"Render ")}/{count(idle_after,"Render ")}\n'
        (out/'idle.txt').write_text(idle)
        print(idle, flush=True)
        assert count(idle_before,'Render ')==count(idle_after,'Render '), 'render passes continued at idle'
        assert 'mutations 0, rasters 0' in paints[-1], paints[-1]
        evaluate(sock,'core.quit()')
        assert kiln.wait(timeout=5)==0, (out/'kiln.log').read_text()
        assert bar.wait(timeout=5)==0, (out/'bar.log').read_text()
    finally:
        for p in reversed(processes):
            if p.poll() is None:
                p.terminate()
                try: p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill();p.wait()
        for log in logs: log.close()


if __name__=='__main__':
    main()
