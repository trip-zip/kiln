#!/usr/bin/env python3
"""Private SNI peer with controllable, asynchronous property replies and receipts."""
import argparse
import os
import gi

gi.require_version('Gio','2.0')
from gi.repository import Gio, GLib

p=argparse.ArgumentParser()
p.add_argument('service');p.add_argument('mode',choices=['pixmap','name','malformed','missing','hold'])
p.add_argument('marker');p.add_argument('--delay',type=int,default=0)
p.add_argument('--path',default='/StatusNotifierItem');p.add_argument('--replace',action='store_true')
a=p.parse_args()
assert os.environ.get('DBUS_SESSION_BUS_ADDRESS','').startswith('unix:path='), 'explicit private address required'
ITEM='org.kde.StatusNotifierItem'
WATCHER='org.kde.StatusNotifierWatcher'
conn=Gio.bus_get_sync(Gio.BusType.SESSION,None)
loop=GLib.MainLoop()
state=dict(Id='test-item',Title='Test Tray Item',Status='Active',IconName='network-wireless' if a.mode=='name' else '')
mode=a.mode
delay=a.delay
PIXELS=[255,255,0,0, 128,0,255,0, 255,0,0,255, 255,255,255,255]
item_xml='''<node><interface name="org.kde.StatusNotifierItem">
<method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
<signal name="NewIcon"/><signal name="NewTitle"/><signal name="NewStatus"><arg type="s"/></signal>
</interface></node>'''
properties_xml='''<node><interface name="org.freedesktop.DBus.Properties">
<method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
</interface></node>'''
control_xml='''<node><interface name="test.Fixture">
<method name="SetStatus"><arg type="s" direction="in"/></method>
<method name="SetTitle"><arg type="s" direction="in"/></method>
<method name="SetIcon"><arg type="s" direction="in"/></method>
<method name="SetDelay"><arg type="i" direction="in"/></method>
<method name="Register"><arg type="s" direction="in"/></method>
<method name="Quit"/>
</interface></node>'''


def record(line):
    with open(a.marker,'a') as f:f.write(line+'\n')


def register(arg=None):
    conn.call(WATCHER,'/StatusNotifierWatcher',WATCHER,'RegisterStatusNotifierItem',GLib.Variant('(s)',[arg or (a.path if a.path!='/StatusNotifierItem' else a.service)]),None,Gio.DBusCallFlags.NONE,2000,None,None)


def item_method(conn,sender,path,iface,method,params,inv):
    record(method+' '+' '.join(str(x) for x in params.unpack()))
    inv.return_value(None)


def property_method(conn,sender,path,iface,method,params,inv):
    _,prop=params.unpack()
    record('Get '+prop)
    value=None
    if mode!='missing' or prop=='Id':
        if prop=='IconPixmap':
            frames=[]
            if mode in ('pixmap','blue'):
                px=PIXELS if mode=='pixmap' else [255,30,80,230]*4
                frames=[(1,1,[255,240,100,10]),(2,2,px)]
            elif mode=='malformed':frames=[(-1,2,[1,2,3,4]),(2147483647,2147483647,[1,2,3,4]),(2,2,[255])]
            value=GLib.Variant('a(iiay)',frames)
        elif prop in state:value=GLib.Variant('s',state[prop])
    def finish():
        if value is None:inv.return_dbus_error('org.freedesktop.DBus.Error.UnknownProperty',prop)
        else:inv.return_value(GLib.Variant('(v)',[value]))
        record('Reply '+prop)
        return False
    if delay:GLib.timeout_add(delay,finish)
    else:finish()


def control(conn,sender,path,iface,method,params,inv):
    global delay,mode
    v=params.unpack()
    if method in ('SetStatus','SetTitle'):
        field=method[3:];state[field]=v[0]
        conn.emit_signal(None,a.path,ITEM,'New'+field,GLib.Variant('(s)',v) if field=='Status' else None)
    elif method=='SetIcon':
        mode=v[0];state['IconName']='network-wireless' if mode in ('name','malformed') else ''
        conn.emit_signal(None,a.path,ITEM,'NewIcon',None)
    elif method=='SetDelay':delay=v[0]
    elif method=='Register':register(v[0])
    inv.return_value(None)
    if method=='Quit':loop.quit()

for path,xml,fn in [(a.path,item_xml,item_method),(a.path,properties_xml,property_method),('/Control',control_xml,control)]:
    conn.register_object(path,Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0],fn,None,None)
flags=1|4|(2 if a.replace else 0)
r=conn.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','RequestName',GLib.Variant('(su)',[a.service,flags]),GLib.VariantType('(u)'),Gio.DBusCallFlags.NONE,2000,None)
assert r.unpack()[0]==1,r
record('Owner '+conn.get_unique_name())
if mode!='hold':register()
loop.run()
