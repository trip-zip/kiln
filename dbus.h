#ifndef KILN_DBUS_H
#define KILN_DBUS_H

/* The one DBus connection in the tree. It carries the
 * notification service today and the SNI watcher next; both hang off this same
 * bus, which is why the connection is its own file and knows about neither.
 *
 * Absent, not stubbed: with -Ddbus=disabled kiln_dbus_create returns NULL, no
 * name is owned, and no service ever registers. Callers check for NULL; there
 * is no fake bus. */

struct wl_event_loop;
struct kiln_dbus;

/* Connects to the session bus and drives it from the wayland event loop. NULL
 * if there is no bus to reach (no DBUS_SESSION_BUS_ADDRESS, no daemon) or the
 * build has no sd-bus: a desktop with no session bus is a desktop without
 * notifications, not a broken compositor. */
struct kiln_dbus *kiln_dbus_create(struct wl_event_loop *loop);
void kiln_dbus_destroy(struct kiln_dbus *dbus);

#ifdef KILN_DBUS

#ifdef KILN_SDBUS_SYSTEMD
#include <systemd/sd-bus.h>
#else
#include <basu/sd-bus.h>
#endif

/* The raw connection, for a service registering its vtable and emitting its
 * signals. Every send must be followed by kiln_dbus_wake so the loop learns the
 * bus wants to write: sd_bus queues outgoing messages, and nothing flushes them
 * until we ask the fd source to watch for writability. */
sd_bus *kiln_dbus_bus(struct kiln_dbus *dbus);
void kiln_dbus_wake(struct kiln_dbus *dbus);

#endif /* KILN_DBUS */

#endif
