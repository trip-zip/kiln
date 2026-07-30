#!/usr/bin/env python3
# A scripted StatusNotifierItem, for the systray battery (scripts/tray-test.sh).
# It is a real SNI item on a real bus: it exports org.kde.StatusNotifierItem,
# registers with the watcher kiln owns, and answers Activate/Scroll for real.
# gdbus can only CALL a
# bus, never EXPORT an object with properties, so the fixture that kiln reads
# back has to be a program, and this is the smallest one (Gio, the same GLib
# gdbus already links).
#
#   sni-item.py <busname> <mode> <markerfile>
#
# mode is "pixmap" (ship a 2x2 ARGB IconPixmap, exercising the pixels -> cache
# key path) or "name" (ship an IconName, exercising the passthrough). Every
# method call the item receives is appended to <markerfile>, so the battery can
# prove tray_activate forwarded a real call. A tiny control interface at /Control
# lets the battery flip the status (emitting NewStatus) and quit.

import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

busname, mode, marker = sys.argv[1], sys.argv[2], sys.argv[3]

# A 2x2 opaque image, ARGB32 in network byte order (A,R,G,B per pixel): red,
# green, blue, white. Distinctive, and the numbers describe the buffer exactly.
PIXELS = [
    0xFF, 0xFF, 0x00, 0x00,
    0xFF, 0x00, 0xFF, 0x00,
    0xFF, 0x00, 0x00, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF,
]

state = {
    "Category": "ApplicationStatus",
    "Id": "test-item",
    "Title": "Test Tray Item",
    "Status": "Active",
    "IconName": "network-wireless" if mode == "name" else "",
    "Menu": "/NO_DBUSMENU",
}

ITEM_XML = """
<node>
  <interface name="org.kde.StatusNotifierItem">
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconPixmap" type="a(iiay)" access="read"/>
    <property name="Menu" type="o" access="read"/>
    <method name="Activate">
      <arg name="x" type="i" direction="in"/>
      <arg name="y" type="i" direction="in"/>
    </method>
    <method name="SecondaryActivate">
      <arg name="x" type="i" direction="in"/>
      <arg name="y" type="i" direction="in"/>
    </method>
    <method name="Scroll">
      <arg name="delta" type="i" direction="in"/>
      <arg name="orientation" type="s" direction="in"/>
    </method>
    <signal name="NewIcon"/>
    <signal name="NewTitle"/>
    <signal name="NewStatus"><arg name="status" type="s"/></signal>
  </interface>
</node>
"""

CTRL_XML = """
<node>
  <interface name="test.Fixture">
    <method name="SetStatus"><arg name="s" type="s" direction="in"/></method>
    <method name="Quit"/>
  </interface>
</node>
"""

ITEM_IFACE = "org.kde.StatusNotifierItem"
loop = GLib.MainLoop()


def record(text):
    with open(marker, "a") as f:
        f.write(text + "\n")


def item_get_property(conn, sender, path, iface, prop):
    if prop == "IconPixmap":
        rows = [(2, 2, PIXELS)] if mode == "pixmap" else []
        return GLib.Variant("a(iiay)", rows)
    if prop == "Menu":
        return GLib.Variant("o", state["Menu"])
    return GLib.Variant("s", state.get(prop, ""))


def item_method(conn, sender, path, iface, method, params, invocation):
    record(method + " " + " ".join(str(a) for a in params.unpack()))
    invocation.return_value(None)


def ctrl_method(conn, sender, path, iface, method, params, invocation):
    if method == "SetStatus":
        state["Status"] = params.unpack()[0]
        conn.emit_signal(None, "/StatusNotifierItem", ITEM_IFACE, "NewStatus",
                         GLib.Variant("(s)", [state["Status"]]))
    invocation.return_value(None)
    if method == "Quit":
        loop.quit()


conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
item_info = Gio.DBusNodeInfo.new_for_xml(ITEM_XML).interfaces[0]
ctrl_info = Gio.DBusNodeInfo.new_for_xml(CTRL_XML).interfaces[0]
conn.register_object("/StatusNotifierItem", item_info, item_method,
                     item_get_property, None)
conn.register_object("/Control", ctrl_info, ctrl_method, None, None)

conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
               "org.freedesktop.DBus", "RequestName",
               GLib.Variant("(su)", [busname, 0]), GLib.VariantType("(u)"),
               Gio.DBusCallFlags.NONE, -1, None)

# Register ASYNC, not sync: the watcher reads our properties BACK while handling
# this call, so we must be able to answer during it, which means our own loop has
# to be running. A synchronous register here would block before loop.run() and
# deadlock against the watcher's readback.
conn.call("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
          "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
          GLib.Variant("(s)", [busname]), None,
          Gio.DBusCallFlags.NONE, -1, None, None)
loop.run()
