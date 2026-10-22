"""Focused raw declaration checks, including applicable ffi-test assertions."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def geometry_config():
    # Keep the bare equal-row fixture independent of desktop defaults.
    return (ROOT / 'scripts/fixtures/strip.lua').read_text() + """
local k=require('kiln')
k.theme.gap=16
k.widgets.client=function(c) core.surface(c.handle) end
screen.on('added',function(s)
 for _,t in ipairs(s.tags) do
  t.layout=function(cs)
   k.ui.row({w='grow',h='grow',gap=16},function()
    for _,c in ipairs(cs) do k.widgets.client(c) end
   end)
  end
 end
end)
client.off('request::fullscreen',k.defaults.fullscreen)
"""

PROBE = '''
ANCHOR_N=0
function good(sn,w,h)
  ANCHOR_N=ANCHOR_N+1
  PREVIOUS=core.box('p-root')
  P={}
  core.open({id='p-root',layout={sizing={width=400,height=200},
    padding={left=10,right=20,top=5,bottom=15},childGap=7,
    childAlignment={x='right',y='top'},layoutDirection='ttb'},
    backgroundColor={r=10,g=20,b=30,a=255}})
  core.open({id='p-grow',layout={sizing={width={type='grow'},height=30}}})
  core.open({layout={sizing={width=5,height=5}}});core.close()
  core.close()
  core.open({id='p-pct',layout={sizing={width={type='percent',percent=.5},height=20}}})
  core.close()
  core.open({id='p-fit',layout={sizing={width={type='fit',min=44,max=88},height=24}}})
  core.close()
  core.close()
  core.open({id={'p-idx',7},layout={sizing={width=11,height=13}}})
  core.close()
  core.open({id='p-anchor-'..ANCHOR_N,layout={sizing={width=9,height=9}}})
  core.close()
  P.badidx=select(2,pcall(core.open,{id={'bad','notanumber'}}))
  P.unmatched=select(2,pcall(core.close))
  P.badhandle=select(2,pcall(core.surface,'notanumber'))
  P.nontable=select(2,pcall(core.open,42))
  P.openrets=select('#',core.open({layout={sizing={width=5,height=5}}}))
  P.closerets=select('#',core.close())
end
core.set_frame_handler(good)
'''

CAPTURE = '''
events={}; handles={}
local set_event=core.set_event_handler
core.set_event_handler=function(fn)
  set_event(function(e)
    if e.class=='client' and (e.name=='map' or e.name=='unmap' or e.name=='destroy') then events[#events+1]=e end
    if e.class=='client' then
      if e.name=='map' then handles[#handles+1]=e.handle
      elseif e.name=='unmap' then
        for i,h in ipairs(handles) do if h==e.handle then table.remove(handles,i);break end end
      end
    end
    fn(e)
  end)
end
local set_frame=core.set_frame_handler
core.set_frame_handler=function(fn) default_frame=fn;set_frame(fn) end
'''


def wait(h, env, expression, expected, server):
    deadline = time.monotonic() + 10
    last = None
    while time.monotonic() < deadline:
        assert server.poll() is None, 'compositor exited'
        last = h.ev(env, expression)
        if last == expected:
            return
        time.sleep(.03)
    raise AssertionError((expression, expected, last))


def check(h, env, expression, expected):
    result = h.ev(env, expression)
    assert result == expected, (expression, expected, result)


def settle(log, quiet=.22, timeout=5):
    """Wait for a measured quiet interval after the last successful solve."""
    deadline = time.monotonic()+timeout
    previous = None
    since = time.monotonic()
    while time.monotonic()<deadline:
        count = log.read_text().count('Layout ')
        if count!=previous:
            previous=count
            since=time.monotonic()
        if time.monotonic()-since>=quiet:
            return
        time.sleep(.02)
    raise AssertionError('layout never settled: '+str(log))


def capture(env, path):
    subprocess.run(['grim', str(path)], env=env, check=True, timeout=5)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rectangles(h):
    with h.boot(PROBE) as (server, env, work, log):
        wait(h, env, 'return core.box("p-root")~=nil', b'true\n', server)
        prefix = "core.hits('HEADLESS-1',0,0);local root=core.box('p-root');local function b(id) return core.box(id) end;"
        # These expected values and expressions come from ffi-test.sh section 9.
        for expression, expected in [
            ("return root.width..'|'..root.height", b'400|200\n'),
            ("local c=b('p-grow');return (c.x-root.x)..'|'..(c.y-root.y)..'|'..c.width..'|'..c.height", b'10|5|370|30\n'),
            ("local c=b('p-pct');return (c.x-root.x)..'|'..(c.y-root.y)..'|'..c.width..'|'..c.height", b'195|42|185|20\n'),
            ("local c=b('p-fit');return c.width>=44 and c.width<=88 and c.height==24 and c.y-root.y==69", b'true\n'),
            ("local c=b({'p-idx',7});return c.width..'|'..c.height", b'11|13\n'),
            ("local t=b({'p-root',0});return t.x==root.x and t.y==root.y and t.width==root.width and t.height==root.height", b'true\n'),
            ("return b('no-such-element-ever')", b'nil\n'),
            ("return P.openrets..'|'..P.closerets", b'0|0\n'),
            ("return tostring(P.badidx):match('table id index must be a number')~=nil", b'true\n'),
            ("return tostring(P.unmatched):match('core%.close without matching core%.open')~=nil", b'true\n'),
            ("return tostring(P.badhandle):match('core%.surface')~=nil", b'true\n'),
            ("return tostring(P.nontable):match('core%.open')~=nil", b'true\n'),
        ]:
            check(h, env, prefix + expression, expected)
        for expression in ["core.open({})", "core.close()", "core.surface(1)",
                           "core.open(false)", "core.box(nil)", "core.box(42)",
                           "core.box({'x','1'})", "core.hits(42,0,0)",
                           "core.hits('HEADLESS-1','0','0')", "core.dirty(false)",
                           "core.set_frame_handler(nil)", "core.set_event_handler({})"]:
            assert h.ev(env, expression).startswith(b'ERROR:'), expression
            before = int(h.ev(env, 'return ANCHOR_N'))
            check(h, env, 'core.set_frame_handler(good);core.dirty()', b'\n')
            wait(h, env, 'return ANCHOR_N', f'{before+1}\n'.encode(), server)
            check(h, env, "return core.box('p-root').width", b'400\n')
        check(h, env, '''collectgarbage('collect');local c=core.box('p-anchor-'..ANCHOR_N)
for _,v in ipairs(core.hits('HEADLESS-1',c.x+c.width/2,c.y+c.height/2)) do
  if v.name=='p-anchor-'..ANCHOR_N then return true end
end;return false''', b'true\n')
        check(h, env, '''local c=core.box({'p-idx',7});local a=core.hits('HEADLESS-1',c.x+1,c.y+1)
return a[1].name,a[1].index,type(a[1].index)''', b'p-idx\t7\tnumber\n')
        check(h, env, '''local a=core.hits('HEADLESS-1',11,6);local anon=false
for _,v in ipairs(a) do assert(type(v.name)=='string');if v.name=='' then anon=true end end
return #a>1 and anon''', b'true\n')
        initial = capture(env, work / 'rectangles.png')
        bad = ["core.close()", "core.open({})", "core.open({});core.open({});error('nested')",
               "core.open(false)", "core.open({id={'bad','index'}})",
               "core.surface(999999)", "core.open({id='dup'});core.open({id='dup'})",
               "core.open({image={path='no'}})", "core.open({border={width={left=-1}}})",
               "core.open({cornerRadius={topLeft=-1}})", "core.text('unsupported',{wrapMode=9})",
               "core.open({layout={sizing={width=0/0}}})",
               "core.open({layout={sizing={width={type='percent',percent=2}}}})"]
        for cycle in range(2):
            for i, body in enumerate(bad):
                token = cycle * len(bad) + i + 1
                check(h, env, f"core.set_frame_handler(function() ATTEMPT={token};{body} end);core.dirty()", b'\n')
                wait(h, env, 'return ATTEMPT', f'{token}\n'.encode(), server)
                check(h, env, "return core.box('p-root').width,core.hits('HEADLESS-1',20,10)[1].name", b'400\tp-grow\n')
                assert capture(env, work / 'failed-frame.png') == initial, body
                before = int(h.ev(env, 'return ANCHOR_N'))
                check(h, env, "collectgarbage('collect');core.set_frame_handler(good);core.dirty()", b'\n')
                wait(h, env, 'return ANCHOR_N', f'{before+1}\n'.encode(), server)
                check(h, env, 'return PREVIOUS.width,PREVIOUS.height', b'400\t200\n')
        assert log.read_text().count('Lua frame:') == 2 * len(bad), log.read_text()
        check(h, env, '''core.set_frame_handler(function()
core.open({id='rounded',layout={sizing={width=101.5,height=40.5}},backgroundColor={r=255}});core.close()
end);core.dirty()''', b'\n')
        wait(h, env, "local b=core.box('rounded');return b and b.width", b'102\n', server)
        check(h, env, "return core.box('rounded').height", b'41\n')
        check(h, env, "return core.box('p-root').width", b'400\n')
        check(h, env, "for _,v in ipairs(core.hits('HEADLESS-1',20,10)) do if v.name=='p-root' then return false end end;return true", b'true\n')
        check(h, env, '''calls=0;inside=false
core.set_frame_handler(function()
  assert(not inside);inside=true;calls=calls+1
  core.open({id='repeat',layout={sizing={width=20,height=20}}});core.close()
  if calls==1 then core.dirty() end
  inside=false
end);core.dirty()''', b'\n')
        wait(h, env, 'return calls', b'2\n', server)
        time.sleep(.15)
        check(h, env, 'return calls', b'2\n')
        check(h, env, '''core.set_frame_handler(function()
  core.set_frame_handler(good);collectgarbage('collect');core.dirty();error('replaced self')
end);core.dirty()''', b'\n')
        wait(h, env, "return core.hits('HEADLESS-1',20,10)[1].name", b'p-grow\n', server)
        h.quit(server, env, log)
    print('PASS: declaration spellings, readback, original subset assertions, failed frames, screenshots, GC and repeated recovery')


def outputs(h):
    config = '''counts={};previous={}
core.set_frame_handler(function(s,w,h)
  counts[s]=(counts[s] or 0)+1
  previous[s]=core.box('shared')
  local size=s=='HEADLESS-1' and 100 or 200
  core.open({id='shared',layout={sizing={width=size,height=50}},backgroundColor={g=100}})
  core.open({layout={sizing={width=10,height=10}}});core.close();core.close()
end)
'''
    with h.boot(config, overrides={'WLR_HEADLESS_OUTPUTS': '2'}) as (server, env, work, log):
        wait(h, env, "return counts['HEADLESS-1'],counts['HEADLESS-2']", b'1\t1\n', server)
        check(h, env, 'return #core.output.list()', b'2\n')
        for name, width in [('HEADLESS-1', 100), ('HEADLESS-2', 200)]:
            check(h, env, f'''for _,o in ipairs(core.output.list()) do if o.name=='{name}' then
local hits=core.hits(o.name,o.x+20,o.y+20)
return core.box('shared').width,hits[1].name,#hits end end''', f'{width}\tshared\t2\n'.encode())
        check(h, env, "core.dirty('HEADLESS-1')", b'\n')
        wait(h, env, "return counts['HEADLESS-1'],counts['HEADLESS-2']", b'2\t1\n', server)
        check(h, env, "return previous['HEADLESS-1'].width,previous['HEADLESS-2']", b'100\tnil\n')
        check(h, env, "core.dirty('missing')", b'\n')
        time.sleep(.15)
        check(h, env, "return counts['HEADLESS-1'],counts['HEADLESS-2']", b'2\t1\n')
        check(h, env, "return #core.hits('missing',0,0)", b'0\n')
        check(h, env, "core.dirty()", b'\n')
        wait(h, env, "return counts['HEADLESS-1'],counts['HEADLESS-2']", b'3\t2\n', server)
        check(h, env, "return previous['HEADLESS-1'].width,previous['HEADLESS-2'].width", b'100\t200\n')
        h.quit(server, env, log)
    print('PASS: two headless outputs, independent boxes, global hit coordinates and per-output dirty scheduling')


def clients(h):
    config = CAPTURE + geometry_config()
    with h.boot(config) as (server, env, work, log):
        descriptors = []
        try:
            for label in ['LEFT', 'RIGHT']:
                pidfile = work / f'{label}.pid'
                command = f"echo $$ > {pidfile}; exec foot --title=LUA-{label} --font=monospace:size=14 sh -c 'printf \"\\n  Lua declares {label}\\n\\n\"; while :; do printf \"\\r  repaint %s\" \"$(date +%s)\"; sleep .1; done'"
                check(h, env, 'core.spawn(' + json.dumps(command) + ')', b'\n')
                wait(h, env, 'return #handles', f'{len(descriptors)+1}\n'.encode(), server)
                descriptors.append(os.pidfd_open(int(pidfile.read_text())))
            wait(h, env, "local b=core.box({'core.surface',handles[1]});return b and b.width", b'616\n', server)
            check(h, env, '''local a=core.box({'core.surface',handles[1]});local b=core.box({'core.surface',handles[2]})
return a.x,a.y,a.width,a.height,b.x,b.y,b.width,b.height''', b'16\t52\t616\t652\t648\t52\t616\t652\n')
            check(h, env, '''local a=core.hits('HEADLESS-1',100,100)[1];local b=core.hits('HEADLESS-1',1000,100)[1]
return a.name,a.index==handles[1],b.name,b.index==handles[2]''', b'core.surface\ttrue\tcore.surface\ttrue\n')
            check(h, env, '''local a=events[1];return a.class,a.name,a.handle==handles[1],a.app_id,a.title,
type(a.x),type(a.y),a.width>0,a.height>0,a.wm_class,a.fullscreen''', b'client\tmap\ttrue\tfoot\tLUA-LEFT\tnumber\tnumber\ttrue\ttrue\tnil\tnil\n')
            time.sleep(.4)
            baseline = [line for line in log.read_text().splitlines() if line.startswith('Layout ')]
            time.sleep(.8)
            assert baseline == [line for line in log.read_text().splitlines() if line.startswith('Layout ')], 'client repaint caused a solve/configure loop'
            capture(env, work / 'lua-two.png')
            # Reinstalling the same policy must retain cached configure requests.
            check(h, env, 'saved_default=default_frame;core.set_frame_handler(saved_default);core.dirty()', b'\n')
            time.sleep(.15)
            latest = [line for line in log.read_text().splitlines() if line.startswith('Layout ')][-1]
            assert latest.split('size requests ')[1] == baseline[-1].split('size requests ')[1]
            check(h, env, '''core.set_frame_handler(function()
core.open({id='screen',layout={sizing={width={type='grow'},height={type='grow'}},layoutDirection='ttb'},backgroundColor={r=24,g=28,b=36}})
core.open({id='strip',layout={sizing={width={type='grow'},height=64}},backgroundColor={r=55,g=131,b=151}});core.close()
core.open({id='clients',layout={sizing={width={type='grow'},height={type='grow'}},layoutDirection='ttb',padding={left=24,right=24,top=24,bottom=24},childGap=12}})
for _,h in ipairs(handles) do core.surface(h) end
core.close();core.close()
end);core.dirty()''', b'\n')
            wait(h, env, "return core.box({'core.surface',handles[1]}).width", b'1232\n', server)
            check(h, env, '''local a=core.box({'core.surface',handles[1]});local b=core.box({'core.surface',handles[2]})
return a.x,a.y,a.width,a.height,b.x,b.y,b.width,b.height''', b'24\t88\t1232\t298\t24\t398\t1232\t298\n')
            time.sleep(.3)
            capture(env, work / 'lua-column.png')
            # A duplicate surface cannot replace the valid column scene.
            check(h, env, '''saved_column=default_frame;FAILED=false
core.set_frame_handler(function() FAILED=true;core.surface(handles[1]);core.surface(handles[1]) end);core.dirty()''', b'\n')
            wait(h, env, 'return FAILED', b'true\n', server)
            check(h, env, "return core.box({'core.surface',handles[1]}).width", b'1232\n')
            check(h, env, "core.set_frame_handler(saved_column);core.dirty()", b'\n')
            time.sleep(.15)
            # Omitted clients remain alive and can be placed again.
            check(h, env, '''core.set_frame_handler(function()
core.open({id='only',layout={sizing={width={type='grow'},height={type='grow'}}}})
core.surface(handles[1]);core.close()
end);core.dirty()''', b'\n')
            wait(h, env, "return core.box({'core.surface',handles[1]}).width", b'1280\n', server)
            check(h, env, '''for _,v in ipairs(core.hits('HEADLESS-1',100,500)) do
if v.name=='core.surface' and v.index==handles[2] then return false end end
return core.box({'core.surface',handles[2]})~=nil and #handles==2''', b'true\n')
            wait(h, env, 'return client.focus,core.client.focused()', b'nil\tnil\n', server)
            capture(env, work / 'lua-omitted.png')
            check(h, env, "core.set_frame_handler(saved_default);core.dirty()", b'\n')
            wait(h, env, "return core.box({'core.surface',handles[1]}).width", b'616\n', server)
            check(h, env, '''stale=handles[2];UNMAP_FAILURES=0
core.set_frame_handler(function() UNMAP_FAILURES=UNMAP_FAILURES+1;error('fail across unmap') end)
core.dirty()''', b'\n')
            wait(h, env, 'return UNMAP_FAILURES', b'1\n', server)
            signal.pidfd_send_signal(descriptors[1], signal.SIGTERM)
            wait(h, env, 'return #handles', b'1\n', server)
            wait(h, env, 'return UNMAP_FAILURES>=2', b'true\n', server)
            check(h, env, '''for _,v in ipairs(core.hits('HEADLESS-1',1000,100)) do
if v.name=='core.surface' and v.index==stale then return false end end;return true''', b'true\n')
            check(h, env, "core.set_frame_handler(saved_default);core.dirty()", b'\n')
            wait(h, env, "return core.box({'core.surface',handles[1]}).width", b'1248\n', server)
            check(h, env, '''return events[#events-1].name,events[#events].name,
events[#events].handle==stale,events[#events].width,events[#events].app_id''', b'unmap\tdestroy\ttrue\tnil\tnil\n')
            time.sleep(.2)
            capture(env, work / 'lua-survivor.png')
            check(h, env, '''STALE_ATTEMPT=false;core.set_frame_handler(function()
STALE_ATTEMPT=true;core.surface(stale) end);core.dirty()''', b'\n')
            wait(h, env, 'return STALE_ATTEMPT', b'true\n', server)
            check(h, env, '''for _,v in ipairs(core.hits('HEADLESS-1',1000,100)) do
if v.name=='core.surface' and v.index==stale then return false end end;return true''', b'true\n')
            check(h, env, "collectgarbage('collect');core.set_frame_handler(saved_default);core.dirty()", b'\n')
            wait(h, env, "return core.box({'core.surface',handles[1]}).width", b'1248\n', server)
            h.quit(server, env, log)
        finally:
            for fd in descriptors:
                try:
                    signal.pidfd_send_signal(fd, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                os.close(fd)
    print('PASS: two IPC-spawned foot clients, event envelopes, changed layout, omitted/stale leaves, survivor growth and repaint stability')
    print('Screenshots:', work.resolve())


def run(h):
    rectangles(h)
    outputs(h)
    clients(h)
