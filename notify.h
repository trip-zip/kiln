#ifndef KILN_NOTIFY_H
#define KILN_NOTIFY_H

/* org.freedesktop.Notifications, the whole of it that is C.
 * Four methods answered and two signals emitted; the answers are
 * an id and two static facts, and the id is minted only because the Notify
 * reply is synchronous DBus and Lua cannot be consulted before it goes out.
 *
 * What is NOT here, by construction: timeouts, queueing, placement, urgency
 * ranking, and any notification struct outliving the event that reported it.
 * A C leg that expires, places, or ranks a notification would be C deciding
 * what was left to policy. The
 * only state this file keeps is a monotonic id counter.
 *
 * NULL dbus (no bus, or -Ddbus=disabled) means no service: notifications are
 * absent, and core.notify_* stay the no-ops an unset op table already is. */

struct kiln_dbus;
struct core;
struct queue;
struct ui;
struct kiln_notify;

struct kiln_notify *kiln_notify_create(struct kiln_dbus *dbus,
	struct core *core, struct queue *queue, struct ui *ui);
void kiln_notify_destroy(struct kiln_notify *notify);

#endif
