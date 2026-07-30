#ifndef KILN_TRAY_H
#define KILN_TRAY_H

/* The SNI systray watcher. kiln owns
 * org.kde.StatusNotifierWatcher, the name a tray applet hard-requires to exist
 * before it will show, and proxies each StatusNotifierItem that registers: it
 * reads the item's properties, reports them as tray::item, watches for the
 * item's own change signals to report them again, and reports tray::gone when
 * the item's bus name vanishes. One verb, tray_activate, forwards a click back
 * as a single method call on the item.
 *
 * This is the one service that is also a DBus CLIENT: the notification service
 * only ever answers and emits, but the watcher must read an item back and call
 * methods on it. Reading an item's icon pixels into the image cache is protocol
 * translation, not policy; ranking, placement, theme lookup, and whether an item
 * is drawn are all Lua's, downstream of the events.
 *
 * XEmbed is dropped (X11-legacy), and there is no dbusmenu: ContextMenu is a
 * named absence until a fixture forces it.
 *
 * NULL dbus (no bus, or -Ddbus=disabled) means no watcher: the tray is absent,
 * not stubbed, and core.tray_activate stays the no-op an unset op table is. */

struct kiln_dbus;
struct core;
struct queue;
struct ui;
struct kiln_tray;

struct kiln_tray *kiln_tray_create(struct kiln_dbus *dbus,
	struct core *core, struct queue *queue, struct ui *ui);
void kiln_tray_destroy(struct kiln_tray *tray);

#endif
