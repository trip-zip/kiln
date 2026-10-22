"""Supported Wayland-to-X drag actions and lifetimes with real outer input."""
from protocol_client import Client,u
from xwayland_scenario import scenario,main


def run(h):
    with scenario(h) as s:
        x=s.x;n=s.n
        def arrange():
            s.pick();s.ev('N:move_to(T);X:move_to(T)');s.pump()
            x.prop(s.w,'XdndAware','ATOM',u(5),32);x.sync()
        arrange()
        def messages(name,start):return [r for r in x.records[start:] if r['event']==33 and r['type']==x.atom(name)]
        def begin():
            arrange();s.point('N');s.xdo('mousedown',1);start=len(x.records)
            source=n.data_source({'text/plain;charset=utf-8':b'drag bytes\0\xff','text/uri-list':b'file:///tmp/kiln-fixture-only\r\n'},actions=7)
            icon=n.start_drag(source,s.a,s.serial());s.pump();s.point('X')
            s.until(lambda:bool(messages('XdndEnter',start)),'real X drag enter')
            return source,icon,start,messages('XdndEnter',start)[-1]['data'][0]
        def status(proxy,action,accept=True):
            x.message(proxy,'XdndStatus',[s.w,int(accept),0,0,x.atom('XdndAction'+action) if accept else 0],destination=proxy,mask=0)
            s.pump()
        def retire(icon):n.send(icon['surface'],0);n.roundtrip();s.pump()
        for action,number in [('Copy',1),('Move',2),('Ask',4)]:
            source,icon,start,proxy=begin();status(proxy,action)
            s.until(lambda:n.objects[source][1].get('action')==number,'negotiated '+action)
            for mime,payload in [('UTF8_STRING',b'drag bytes\0\xff'),('text/uri-list',b'file:///tmp/kiln-fixture-only\r\n')]:
                assert x.receive(s.w,'XdndSelection',mime,s.pump)==payload
            if action=='Copy':s.shot('drag-mixed-scale')
            s.xdo('mouseup',1);s.until(lambda:bool(messages('XdndDrop',start)),'XdndDrop')
            x.message(proxy,'XdndFinished',[s.w,1,x.atom('XdndAction'+action)],destination=proxy,mask=0)
            s.until(lambda:n.objects[source][1].get('finished'),'source finished')
            s.rows.append(dict(case='accepted',action=action,exact_bytes=True,finished=True,output='X11-2',scale=1.5,origin=[1161,91]))
            retire(icon)
        source,icon,start,proxy=begin();status(proxy,'Copy',False)
        assert x.receive(s.w,'XdndSelection','application/x-unsupported',s.pump) is None
        s.xdo('mouseup',1);s.until(lambda:n.objects[source][1].get('cancelled'),'rejected source cancellation')
        assert not messages('XdndDrop',start);retire(icon);s.rows.append(dict(case='rejection',cancelled=True))
        source,icon,start,proxy=begin();status(proxy,'Copy');s.point('N')
        s.until(lambda:bool(messages('XdndLeave',start)),'target leave')
        s.xdo('mouseup',1);s.until(lambda:n.objects[source][1].get('cancelled'),'leave cancellation');retire(icon)
        s.rows.append(dict(case='leave',cancelled=True))
        source,icon,start,proxy=begin();status(proxy,'Copy');s.reload();arrange();s.point('X');status(proxy,'Copy')
        assert not n.objects[source][1].get('cancelled')
        assert x.receive(s.w,'XdndSelection','UTF8_STRING',s.pump)==b'drag bytes\0\xff'
        s.xdo('mouseup',1);s.until(lambda:bool(messages('XdndDrop',start)),'drop after reload')
        x.message(proxy,'XdndFinished',[s.w,1,x.atom('XdndActionCopy')],destination=proxy,mask=0)
        s.until(lambda:n.objects[source][1].get('finished'),'finished after reload');retire(icon)
        s.rows.append(dict(case='reload active drag',finished=True))
        source,icon,start,proxy=begin();status(proxy,'Copy');x.destroy(s.w);s.pump();s.xdo('mouseup',1)
        s.until(lambda:n.objects[source][1].get('cancelled'),'dead target cancels');retire(icon)
        s.rows.append(dict(case='target destruction',cancelled=True))
        s.w=x.create(instance='scenario-x');s.wait('#client.all()==2');arrange()
        source,icon,start,proxy=begin();status(proxy,'Copy');ends=int(s.val('ENDS'))
        n.close();n.closed=True;s.pump();s.xdo('mouseup',1);s.wait('ENDS=='+str(ends+1));s.wait('#client.all()==1')
        s.rows.append(dict(case='source disconnect',drag_ended=True))
        n=Client(s.env);s.n=n;s.clients.append(n);s.a=n.toplevel('scenario-native');s.wait('#client.all()==2');n.data_device();arrange()
        source,icon,start,proxy=begin();status(proxy,'Copy');s.xdo('mouseup',1)
        s.until(lambda:bool(messages('XdndDrop',start)),'fresh drop after deaths')
        x.message(proxy,'XdndFinished',[s.w,1,x.atom('XdndActionCopy')],destination=proxy,mask=0)
        s.until(lambda:n.objects[source][1].get('finished'),'fresh source completion');retire(icon)
        s.save('drag-cases.json');s.quit()
    print('PASS: Wayland->X copy/move/ask, exact text/URI bytes, rejection/leave, active reload, target destruction/source disconnect and fresh recovery on non-origin mixed-scale output',flush=True)

if __name__=='__main__':main(run,'drag-cases')
