/* The shared DBus connection. It owns the bus and its place on the wayland
 * event loop, and nothing else: what interfaces exist on it is the services'
 * business (notify.c today, the SNI watcher next).
 *
 * On the loop, never on a thread. sd_bus hands out an fd, so the bus is just
 * another event source alongside the IPC socket, and every service callback
 * therefore runs on the main thread. That is what makes calling queue_* from a
 * DBus handler legal at all: the origin queue's enqueue is an unlocked list
 * insert plus an idle arm. A bus on its own thread would need an eventfd hop
 * back to the loop before it could touch the queue, and kiln has no threads. */

#include <stddef.h>

#include "dbus.h"

#ifndef KILN_DBUS

/* -Ddbus=disabled: no bus exists. Not a stub, an absence. */
struct kiln_dbus *kiln_dbus_create(struct wl_event_loop *loop) {
	(void)loop;
	return NULL;
}

void kiln_dbus_destroy(struct kiln_dbus *dbus) {
	(void)dbus;
}

#else

#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <time.h>
#include <wayland-server-core.h>
#include <wlr/util/log.h>

struct kiln_dbus {
	sd_bus *bus;
	struct wl_event_source *fd_source;
	struct wl_event_source *timer_source;
};

sd_bus *kiln_dbus_bus(struct kiln_dbus *dbus) {
	return dbus != NULL ? dbus->bus : NULL;
}

static uint64_t now_usec(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000 + (uint64_t)ts.tv_nsec / 1000;
}

/* Re-arm both sources from what the bus says it wants now. sd_bus decides
 * whether it is waiting to read, to write, or on a timeout; we only translate. */
static void dbus_rearm(struct kiln_dbus *dbus) {
	int events = sd_bus_get_events(dbus->bus);
	if (events < 0) {
		return;
	}
	uint32_t mask = 0;
	if (events & POLLIN) {
		mask |= WL_EVENT_READABLE;
	}
	if (events & POLLOUT) {
		mask |= WL_EVENT_WRITABLE;
	}
	wl_event_source_fd_update(dbus->fd_source, mask);

	uint64_t deadline = 0;
	if (sd_bus_get_timeout(dbus->bus, &deadline) < 0 ||
			deadline == UINT64_MAX) {
		wl_event_source_timer_update(dbus->timer_source, 0);
		return;
	}
	uint64_t now = now_usec();
	uint64_t delay_us = deadline > now ? deadline - now : 0;
	/* A 0 disarms a wl timer, so a deadline already past must round up to 1ms
	 * rather than silently never firing. */
	int delay_ms = (int)(delay_us / 1000);
	wl_event_source_timer_update(dbus->timer_source,
		delay_ms > 0 ? delay_ms : 1);
}

/* Drain everything the bus has: one sd_bus_process call handles at most one
 * message, and returns >0 while more remain. */
static int dbus_drain(struct kiln_dbus *dbus) {
	int ret;
	while ((ret = sd_bus_process(dbus->bus, NULL)) > 0) {
		/* the vtable handlers ran */
	}
	if (ret < 0) {
		wlr_log(WLR_ERROR, "dbus: process failed: %s", strerror(-ret));
		return ret;
	}
	dbus_rearm(dbus);
	return 0;
}

static int dbus_readable(int fd, uint32_t mask, void *data) {
	(void)fd;
	(void)mask;
	dbus_drain(data);
	return 0;
}

static int dbus_timeout(void *data) {
	dbus_drain(data);
	return 0;
}

void kiln_dbus_wake(struct kiln_dbus *dbus) {
	if (dbus != NULL) {
		dbus_rearm(dbus);
	}
}

struct kiln_dbus *kiln_dbus_create(struct wl_event_loop *loop) {
	sd_bus *bus = NULL;
	int ret = sd_bus_default_user(&bus);
	if (ret < 0) {
		/* No session bus is a normal state (a TTY session, a CI box), so this
		 * is INFO and the compositor carries on without the services. */
		wlr_log(WLR_INFO, "dbus: no session bus (%s); "
			"notifications and systray are off", strerror(-ret));
		return NULL;
	}

	struct kiln_dbus *dbus = calloc(1, sizeof(*dbus));
	if (dbus == NULL) {
		sd_bus_unref(bus);
		return NULL;
	}
	dbus->bus = bus;
	dbus->fd_source = wl_event_loop_add_fd(loop, sd_bus_get_fd(bus),
		WL_EVENT_READABLE, dbus_readable, dbus);
	dbus->timer_source = wl_event_loop_add_timer(loop, dbus_timeout, dbus);
	dbus_rearm(dbus);
	wlr_log(WLR_INFO, "dbus: connected to the session bus");
	return dbus;
}

void kiln_dbus_destroy(struct kiln_dbus *dbus) {
	if (dbus == NULL) {
		return;
	}
	wl_event_source_remove(dbus->fd_source);
	wl_event_source_remove(dbus->timer_source);
	sd_bus_flush_close_unref(dbus->bus);
	free(dbus);
}

#endif /* KILN_DBUS */
