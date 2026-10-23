#!/usr/bin/env python3
"""Compare committed headless frames, keeping logs and every differing pixel."""
# Uses GLES for the baseline; the branch owns its renderer and ignores WLR_RENDERER.
# Requires Pillow (PIL).
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def evaluate(sock, source):
    with socket.socket(socket.AF_UNIX) as stream:
        stream.settimeout(5)
        stream.connect(str(sock))
        stream.sendall(source.encode())
        stream.shutdown(socket.SHUT_WR)
        chunks = []
        while data := stream.recv(65536):
            chunks.append(data)
    reply = b''.join(chunks).decode()
    if reply.startswith('ERROR:'):
        raise RuntimeError(reply)
    return reply


CONFIG = r'''
local kiln = require('kiln')
local ui = kiln.ui
PHASE = 0
core.set_frame_handler(function(name, width, height)
    ui.column({id='root', w='grow', h='grow', color='#192334', pad=13, gap=11},function()
        ui.row({id='shapes',w='grow',h=98,gap=9},function()
            ui.box({id='rect',w=73,h=61,color=PHASE==1 and '#ec6941' or '#38ac82'})
            ui.box({id='alpha',w=77,h=67,color='#dd446688',radius=17})
            ui.box({id='circle',w=80,h=80,color='#96c1ef',radius=40})
            ui.box({id='ring',w=89,h=83,border={width=7,color='#f7bc5588'},radius=36})
            ui.box({id='square-border',w=71,h=79,border={width=3,color='#cc88ff'}})
        end)
        ui.box({id='text',w=337,h=54,color='#243f56',radius=9,pad=5,clip={horizontal=true}},function()
            ui.text('Kiln: AV fi ffi / Ελληνικά / café / مرحبا', {size=23,font='Sans',color='#f7e8c3'})
        end)
        ui.row({id='images',w='grow',h=89,gap=12},function()
            ui.image(os.getenv('SCENE_IMAGE'),{id='image',w=113,h=83,radius=15})
            ui.image(os.getenv('SCENE_IMAGE'),{id='tinted',w=79,h=67,recolor='#ed9c4477',radius=21})
        end)
        ui.row({id='crop',w=173,h=53,clip={horizontal=true,vertical=true},gap=7},function()
            ui.box({id='cropped-round',w=96,h=77,color='#61bbcc99',radius=26})
            ui.box({id='cropped-border',w=123,h=83,border={width=5,color='#f4bbdd'},radius=33})
        end)
        if PHASE~=2 then ui.box({id='moving',w=PHASE==1 and 143 or 81,h=29,color='#fba366',radius=8}) end
    end)
end)
'''


def capture(binary, destination, scale, image):
    destination.mkdir(parents=True, exist_ok=True)
    runtime = destination / 'runtime'
    runtime.mkdir(mode=0o700, exist_ok=True)
    config = destination / 'rc.lua'
    config.write_text(CONFIG)
    sock = destination / 'eval.sock'
    env = dict(os.environ, KILN_SOCK=str(sock), KILN_PAINT_DEBUG='1', KILN_RC=str(config),
               XDG_RUNTIME_DIR=str(runtime), HOME=str(destination / 'home'),
               XDG_CONFIG_HOME=str(destination / 'config'),
               XDG_CACHE_HOME=str(destination / 'cache'),
               XDG_DATA_HOME=str(destination / 'data'),
               DBUS_SESSION_BUS_ADDRESS=f'unix:path={runtime}/absent',
               WLR_BACKENDS='headless', WLR_RENDERER='gles2',
               SCENE_IMAGE=str(image))
    logfile = destination / 'kiln.log'
    with logfile.open('w') as log:
        process = subprocess.Popen([str(binary)], cwd=ROOT, env=env, stdout=log, stderr=log)
        (destination / 'pid').write_text(str(process.pid))
        try:
            deadline = time.monotonic() + 15
            while not sock.exists() or 'First frame committed' not in logfile.read_text():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError(logfile.read_text())
                time.sleep(.025)
            evaluate(sock, f"local o=core.output.list()[1];core.output.set_mode(o.name,{640*scale},{480*scale},60000);core.output.set_scale(o.name,{scale})")
            time.sleep(.4)
            for phase in [0, 1, 2, 0]:
                evaluate(sock, f'PHASE={phase};core.dirty()')
                time.sleep(.2)
                path = destination / f'phase-{phase}.png'
                evaluate(sock, f'local o=core.output.list()[1];return core.screenshot(o.name,{json.dumps(str(path))})')
                assert path.exists(), logfile.read_text()
            evaluate(sock, 'core.dirty()')
            time.sleep(.2)
            before = logfile.read_text()
            time.sleep(1)
            after = logfile.read_text()
            passes = lambda text: sum(line.startswith('Render ') for line in text.splitlines())
            paints = [line for line in after.splitlines() if line.startswith('Paint ')]
            assert passes(before) == passes(after), 'render passes continued at idle'
            assert 'mutations 0, rasters 0' in paints[-1], paints[-1]
            (destination / 'idle.txt').write_text(paints[-1] + f'\nPasses before/after 1s idle: {passes(before)}/{passes(after)}\n')
            evaluate(sock, 'core.quit()')
            assert process.wait(timeout=5) == 0, logfile.read_text()
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--main', type=Path, required=True)
    parser.add_argument('--branch', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    image = Image.new('RGBA', (64, 64))
    image.putdata([(x * 4, y * 4, 192, (x * 13 + y * 7) % 256) for y in range(64) for x in range(64)])
    asset = out / 'fixture.png'
    image.save(asset)
    results = []
    for scale in (1, 2):
        for label, binary in [('main', args.main), ('branch', args.branch)]:
            capture(binary.resolve(), out / f'{label}-{scale}', scale, asset)
        for phase in (0, 1, 2):
            a = Image.open(out / f'main-{scale}/phase-{phase}.png').convert('RGBA')
            b = Image.open(out / f'branch-{scale}/phase-{phase}.png').convert('RGBA')
            assert a.size == b.size
            differences = [(i % a.width, i // a.width, aa, bb) for i, (aa, bb) in enumerate(zip(a.get_flattened_data(), b.get_flattened_data())) if aa != bb]
            result = dict(scale=scale, phase=phase, pixels=a.width*a.height, differing_pixels=len(differences))
            if differences:
                (out / f'differences-{scale}-{phase}.json').write_text(json.dumps(differences))
            results.append(result)
            print(json.dumps(result), flush=True)
    (out / 'comparison.json').write_text(json.dumps(results, indent=2) + '\n')
    assert not any(row['differing_pixels'] for row in results), 'pixel differences recorded'


if __name__ == '__main__':
    main()
