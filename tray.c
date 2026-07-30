/* The StatusNotifierWatcher and the per-item proxy. Every handler answers what
 * the protocol demands and reports the facts; it decides nothing. The watcher
 * owns the name because clients hard-require it to exist (owning a name is
 * wiring); the proxy reads an item's properties because that is the only way to
 * learn them (reading is translation). What a tray shows, where, and how a name
 * resolves to a theme icon are Lua's, every one. */

#include "tray.h"

#ifdef KILN_DBUS

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/util/log.h>

#include "core.h"
#include "dbus.h"
#include "queue.h"
#include "ui.h"

#define WATCHER_SERVICE "org.kde.StatusNotifierWatcher"
#define WATCHER_PATH "/StatusNotifierWatcher"
#define ITEM_IFACE "org.kde.StatusNotifierItem"
#define ITEM_PATH "/StatusNotifierItem"

struct kiln_tray {
	struct kiln_dbus *dbus;
	struct queue *queue;
	struct ui *ui;
	sd_bus_slot *watcher_slot;
	sd_bus_slot *owner_slot; /* one NameOwnerChanged match for every item */
	struct wl_list items;    /* struct tray_item.link */
};

/* The whole of what C remembers about an item: how to reach it, and a slot for
 * the signal match. Its icon, title, and status are read from the bus on demand
 * and forwarded, never cached here: an item struct that outlived its facts
 * would serve stale answers the bus no longer backs, the same trap a cached
 * notification would be. */
struct tray_item {
	struct kiln_tray *tray;
	char *service; /* the item's bus name (well-known or unique) */
	char *path;    /* its object path */
	sd_bus_slot *watch_slot;
	struct wl_list link;
};

static struct tray_item *item_find(struct kiln_tray *tray, const char *service) {
	struct tray_item *it;
	wl_list_for_each(it, &tray->items, link) {
		if (strcmp(it->service, service) == 0) {
			return it;
		}
	}
	return NULL;
}

/* --- reading the item back (the client half) --- */

static char *item_string(struct tray_item *it, const char *prop) {
	char *val = NULL;
	if (sd_bus_get_property_string(kiln_dbus_bus(it->tray->dbus), it->service,
			it->path, ITEM_IFACE, prop, NULL, &val) < 0) {
		return NULL;
	}
	return val;
}

/* IconPixmap is a(iiay): an array of sizes, each ARGB32 in network (big-endian)
 * byte order, so a pixel's bytes are A,R,G,B. ui_image_put wants gdk-pixbuf's
 * R,G,B,A, so the one thing C does to the pixels is reorder them, the same
 * category of translation notify.c does for the image-data hint. The largest
 * size wins; the pixels stop here and the caller forwards only the cache key. */
static bool put_pixmap(struct tray_item *it, const char *key) {
	sd_bus_message *reply = NULL;
	if (sd_bus_get_property(kiln_dbus_bus(it->tray->dbus), it->service, it->path,
			ITEM_IFACE, "IconPixmap", NULL, &reply, "a(iiay)") < 0) {
		return false;
	}

	int32_t best_w = 0, best_h = 0;
	uint8_t *best = NULL;
	if (sd_bus_message_enter_container(reply, 'a', "(iiay)") > 0) {
		while (sd_bus_message_enter_container(reply, 'r', "iiay") > 0) {
			int32_t w = 0, h = 0;
			sd_bus_message_read(reply, "ii", &w, &h);
			const void *px = NULL;
			size_t len = 0;
			sd_bus_message_read_array(reply, 'y', &px, &len);
			sd_bus_message_exit_container(reply);
			if (w <= 0 || h <= 0 || len != (size_t)w * h * 4 ||
					(int64_t)w * h <= (int64_t)best_w * best_h) {
				continue;
			}
			uint8_t *rgba = malloc(len);
			const uint8_t *s = px;
			for (size_t i = 0; i < (size_t)w * h; i++) {
				rgba[i * 4 + 0] = s[i * 4 + 1];
				rgba[i * 4 + 1] = s[i * 4 + 2];
				rgba[i * 4 + 2] = s[i * 4 + 3];
				rgba[i * 4 + 3] = s[i * 4 + 0];
			}
			free(best);
			best = rgba;
			best_w = w;
			best_h = h;
		}
		sd_bus_message_exit_container(reply);
	}

	bool ok = false;
	if (best != NULL) {
		ok = ui_image_put(it->tray->ui, key, best_w, best_h, best_w * 4, true, 8,
			4, best, (size_t)best_w * best_h * 4);
		free(best);
	}
	sd_bus_message_unref(reply);
	return ok;
}

/* The pixmap wins when the item ships one (it becomes a cache key); an item that
 * ships only an IconName passes the name through, and the theme lookup over it
 * is Lua's. NULL when it offered neither. */
static char *item_icon(struct tray_item *it) {
	char key[288];
	snprintf(key, sizeof(key), "tray:%s", it->service);
	if (put_pixmap(it, key)) {
		return strdup(key);
	}
	return item_string(it, "IconName");
}

static void item_emit(struct tray_item *it) {
	char *id = item_string(it, "Id");
	char *title = item_string(it, "Title");
	char *status = item_string(it, "Status");
	char *icon = item_icon(it);
	struct queue_tray_facts facts = {
		.service = it->service,
		.id = id,
		.title = title,
		.status = status,
		.icon = icon,
	};
	queue_tray_item(it->tray->queue, &facts);
	free(id);
	free(title);
	free(status);
	free(icon);
}

/* Any of the item's change signals (NewIcon, NewTitle, NewStatus, ...) means
 * "read me again": the upsert re-reports every fact, so one match on all of them
 * is enough and Lua updates in place. */
static int on_item_signal(sd_bus_message *m, void *data, sd_bus_error *err) {
	(void)m;
	(void)err;
	item_emit(data);
	return 0;
}

/* --- the item list --- */

static void item_add(struct kiln_tray *tray, const char *service,
		const char *path) {
	struct tray_item *existing = item_find(tray, service);
	if (existing != NULL) {
		/* Registering the same service twice is the same item; re-report it. */
		item_emit(existing);
		return;
	}
	struct tray_item *it = calloc(1, sizeof(*it));
	it->tray = tray;
	it->service = strdup(service);
	it->path = strdup(path);
	wl_list_insert(&tray->items, &it->link);
	sd_bus_match_signal(kiln_dbus_bus(tray->dbus), &it->watch_slot, service,
		path, ITEM_IFACE, NULL, on_item_signal, it);
	item_emit(it);
}

static void item_remove(struct tray_item *it) {
	struct kiln_tray *tray = it->tray;
	queue_tray_gone(tray->queue, it->service);
	sd_bus_emit_signal(kiln_dbus_bus(tray->dbus), WATCHER_PATH, WATCHER_SERVICE,
		"StatusNotifierItemUnregistered", "s", it->service);
	kiln_dbus_wake(tray->dbus);
	wl_list_remove(&it->link);
	sd_bus_slot_unref(it->watch_slot);
	free(it->service);
	free(it->path);
	free(it);
}

/* An item is gone when its bus name loses its owner: one NameOwnerChanged match
 * covers every item, well-known name or unique. */
static int on_owner_changed(sd_bus_message *m, void *data, sd_bus_error *err) {
	(void)err;
	struct kiln_tray *tray = data;
	const char *name = NULL, *old_owner = NULL, *new_owner = NULL;
	if (sd_bus_message_read(m, "sss", &name, &old_owner, &new_owner) < 0) {
		return 0;
	}
	if (new_owner != NULL && new_owner[0] != '\0') {
		return 0; /* still owned */
	}
	struct tray_item *it = item_find(tray, name);
	if (it != NULL) {
		item_remove(it);
	}
	return 0;
}

/* --- the watcher interface --- */

static int method_register_item(sd_bus_message *m, void *data,
		sd_bus_error *err) {
	struct kiln_tray *tray = data;
	const char *arg = NULL;
	int ret = sd_bus_message_read(m, "s", &arg);
	if (ret < 0) {
		return sd_bus_error_set_errno(err, -ret);
	}
	/* The argument is either an object path (the item's bus name is the message
	 * sender) or a bus name (the path is the well-known one). Both are in the
	 * wild; this is the whole of the ambiguity. */
	const char *service, *path;
	if (arg[0] == '/') {
		path = arg;
		service = sd_bus_message_get_sender(m);
	} else {
		service = arg;
		path = ITEM_PATH;
	}
	if (service != NULL) {
		item_add(tray, service, path);
		sd_bus_emit_signal(kiln_dbus_bus(tray->dbus), WATCHER_PATH,
			WATCHER_SERVICE, "StatusNotifierItemRegistered", "s", service);
		kiln_dbus_wake(tray->dbus);
	}
	return sd_bus_reply_method_return(m, "");
}

/* We are the host, so a client registering one is a courtesy we acknowledge. */
static int method_register_host(sd_bus_message *m, void *data,
		sd_bus_error *err) {
	struct kiln_tray *tray = data;
	(void)err;
	sd_bus_emit_signal(kiln_dbus_bus(tray->dbus), WATCHER_PATH, WATCHER_SERVICE,
		"StatusNotifierHostRegistered", "");
	kiln_dbus_wake(tray->dbus);
	return sd_bus_reply_method_return(m, "");
}

static int prop_items(sd_bus *bus, const char *path, const char *iface,
		const char *property, sd_bus_message *reply, void *data,
		sd_bus_error *err) {
	(void)bus;
	(void)path;
	(void)iface;
	(void)property;
	(void)err;
	struct kiln_tray *tray = data;
	int ret = sd_bus_message_open_container(reply, 'a', "s");
	if (ret < 0) {
		return ret;
	}
	struct tray_item *it;
	wl_list_for_each(it, &tray->items, link) {
		sd_bus_message_append(reply, "s", it->service);
	}
	return sd_bus_message_close_container(reply);
}

/* A host exists (we are it) and the protocol version is 0: clients gate their
 * display on the first, so it answers true, statically. */
static int prop_host_registered(sd_bus *bus, const char *path,
		const char *iface, const char *property, sd_bus_message *reply,
		void *data, sd_bus_error *err) {
	(void)bus;
	(void)path;
	(void)iface;
	(void)property;
	(void)data;
	(void)err;
	return sd_bus_message_append(reply, "b", 1);
}

static int prop_protocol(sd_bus *bus, const char *path, const char *iface,
		const char *property, sd_bus_message *reply, void *data,
		sd_bus_error *err) {
	(void)bus;
	(void)path;
	(void)iface;
	(void)property;
	(void)data;
	(void)err;
	return sd_bus_message_append(reply, "i", 0);
}

static const sd_bus_vtable watcher_vtable[] = {
	SD_BUS_VTABLE_START(0),
	SD_BUS_METHOD("RegisterStatusNotifierItem", "s", "", method_register_item,
		SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("RegisterStatusNotifierHost", "s", "", method_register_host,
		SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_PROPERTY("RegisteredStatusNotifierItems", "as", prop_items, 0,
		SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
	SD_BUS_PROPERTY("IsStatusNotifierHostRegistered", "b", prop_host_registered,
		0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("ProtocolVersion", "i", prop_protocol, 0,
		SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_SIGNAL("StatusNotifierItemRegistered", "s", 0),
	SD_BUS_SIGNAL("StatusNotifierItemUnregistered", "s", 0),
	SD_BUS_SIGNAL("StatusNotifierHostRegistered", "", 0),
	SD_BUS_VTABLE_END,
};

/* --- the verb: one method call on the item, and nothing else --- */

static void tray_op_activate(void *data, const char *service, const char *kind,
		int a, const char *b) {
	struct kiln_tray *tray = data;
	struct tray_item *it = item_find(tray, service);
	if (it == NULL) {
		return; /* a name that no longer names anything; nothing to call */
	}
	const char *method;
	bool scroll = strcmp(kind, "scroll") == 0;
	if (scroll) {
		method = "Scroll";
	} else if (strcmp(kind, "secondary") == 0) {
		method = "SecondaryActivate";
	} else {
		method = "Activate";
	}

	sd_bus_message *msg = NULL;
	if (sd_bus_message_new_method_call(kiln_dbus_bus(tray->dbus), &msg,
			it->service, it->path, ITEM_IFACE, method) < 0) {
		return;
	}
	if (scroll) {
		sd_bus_message_append(msg, "is", a, b != NULL ? b : "vertical");
	} else {
		/* Activate/SecondaryActivate take pointer x,y; a is x and most items
		 * ignore both, using them only to place their own menu. */
		sd_bus_message_append(msg, "ii", a, 0);
	}
	/* Fire and forget: the item's reply, if any, is nothing Lua asked for. */
	sd_bus_message_set_expect_reply(msg, 0);
	sd_bus_send(kiln_dbus_bus(tray->dbus), msg, NULL);
	sd_bus_message_unref(msg);
	kiln_dbus_wake(tray->dbus);
}

/* --- lifecycle --- */

struct kiln_tray *kiln_tray_create(struct kiln_dbus *dbus, struct core *core,
		struct queue *queue, struct ui *ui) {
	sd_bus *bus = kiln_dbus_bus(dbus);
	if (bus == NULL) {
		return NULL;
	}

	struct kiln_tray *tray = calloc(1, sizeof(*tray));
	tray->dbus = dbus;
	tray->queue = queue;
	tray->ui = ui;
	wl_list_init(&tray->items);

	int ret = sd_bus_add_object_vtable(bus, &tray->watcher_slot, WATCHER_PATH,
		WATCHER_SERVICE, watcher_vtable, tray);
	if (ret < 0) {
		wlr_log(WLR_ERROR, "tray: cannot publish %s: %s", WATCHER_PATH,
			strerror(-ret));
		free(tray);
		return NULL;
	}

	ret = sd_bus_request_name(bus, WATCHER_SERVICE, 0);
	if (ret < 0) {
		/* Another watcher holds the name. Theirs, then: a compositor without a
		 * tray, not a broken one. */
		wlr_log(WLR_INFO, "tray: %s is taken (%s); systray is off",
			WATCHER_SERVICE, strerror(-ret));
		sd_bus_slot_unref(tray->watcher_slot);
		free(tray);
		return NULL;
	}

	/* Own a host name too, so a client that looks for one rather than reading
	 * the property is satisfied. Best effort; the property is the real answer. */
	char host[64];
	snprintf(host, sizeof(host), "org.kde.StatusNotifierHost-%d", getpid());
	sd_bus_request_name(bus, host, 0);

	sd_bus_match_signal(bus, &tray->owner_slot, "org.freedesktop.DBus",
		"/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged",
		on_owner_changed, tray);
	kiln_dbus_wake(dbus);

	struct core_tray_ops ops = {
		.activate = tray_op_activate,
		.data = tray,
	};
	core_set_tray_ops(core, &ops);
	wlr_log(WLR_INFO, "tray: serving %s", WATCHER_SERVICE);
	return tray;
}

void kiln_tray_destroy(struct kiln_tray *tray) {
	if (tray == NULL) {
		return;
	}
	struct tray_item *it, *tmp;
	wl_list_for_each_safe(it, tmp, &tray->items, link) {
		wl_list_remove(&it->link);
		sd_bus_slot_unref(it->watch_slot);
		free(it->service);
		free(it->path);
		free(it);
	}
	sd_bus_slot_unref(tray->owner_slot);
	sd_bus_slot_unref(tray->watcher_slot);
	free(tray);
}

#else /* !KILN_DBUS */

#include <stddef.h>

struct kiln_tray *kiln_tray_create(struct kiln_dbus *dbus, struct core *core,
		struct queue *queue, struct ui *ui) {
	(void)dbus;
	(void)core;
	(void)queue;
	(void)ui;
	return NULL;
}

void kiln_tray_destroy(struct kiln_tray *tray) {
	(void)tray;
}

#endif /* KILN_DBUS */
