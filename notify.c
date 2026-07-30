/* The notification service: DBus in, origin events out, and two verbs back.
 *
 * The shape of every handler here is the same as every other C leg in the tree:
 * answer what the protocol demands an answer to, report the facts, decide
 * nothing. Notify must reply with an id synchronously, so the id is minted
 * here; that is the entire extent of what C knows about a notification, and it
 * forgets it on the next line. Whether the thing is shown, where, for how long,
 * in what order, and whether the id still names anything are Lua's, every one.
 *
 * The hint treatment: two hints
 * are typed because two need code (urgency, a byte that becomes a name; and
 * image-data, a container whose pixels go to the image cache with the event
 * carrying the key). Everything else scalar passes through untouched and
 * containers are dropped. There is no variant decoder in Lua, and no policy
 * here. */

#include "notify.h"

#ifdef KILN_DBUS

#include <stdlib.h>
#include <string.h>
#include <wlr/util/log.h>

#include "core.h"
#include "dbus.h"
#include "queue.h"
#include "ui.h"

#define NOTIFY_SERVICE "org.freedesktop.Notifications"
#define NOTIFY_PATH "/org/freedesktop/Notifications"

struct kiln_notify {
	struct kiln_dbus *dbus;
	struct queue *queue;
	struct ui *ui;
	sd_bus_slot *slot;
	/* The only state in the file. Monotonic, never reused, like a handle. */
	uint32_t next_id;
};

/* --- growable lists, filled while walking one message --- */

struct action_list {
	struct queue_action *items;
	size_t len, cap;
};

struct hint_list {
	struct queue_hint *items;
	size_t len, cap;
};

static struct queue_action *action_add(struct action_list *l) {
	if (l->len == l->cap) {
		l->cap = l->cap ? l->cap * 2 : 4;
		l->items = realloc(l->items, l->cap * sizeof(*l->items));
	}
	struct queue_action *a = &l->items[l->len++];
	memset(a, 0, sizeof(*a));
	return a;
}

static struct queue_hint *hint_add(struct hint_list *l, const char *key) {
	if (l->len == l->cap) {
		l->cap = l->cap ? l->cap * 2 : 8;
		l->items = realloc(l->items, l->cap * sizeof(*l->items));
	}
	struct queue_hint *h = &l->items[l->len++];
	memset(h, 0, sizeof(*h));
	h->key = strdup(key);
	return h;
}

/* --- the two typed hints --- */

/* The byte the spec fixes: 0 low, 1 normal, 2 critical. Anything else is a
 * client lying about the enum, and an absent urgency is not our default to
 * pick, so both come out as nothing and Lua decides. */
static const char *urgency_name(uint8_t level) {
	switch (level) {
	case 0:
		return "low";
	case 1:
		return "normal";
	case 2:
		return "critical";
	default:
		return NULL;
	}
}

/* image-data: (iiibiiay), which is gdk-pixbuf's layout, which is what the image
 * cache already takes. The pixels stop here; the event carries the key. */
static bool image_data_put(struct kiln_notify *n, sd_bus_message *m,
		uint32_t id, char **image_key) {
	int32_t width, height, rowstride, bits, channels;
	int has_alpha;
	int ret = sd_bus_message_enter_container(m, 'r', "iiibiiay");
	if (ret < 0) {
		return false;
	}
	ret = sd_bus_message_read(m, "iiibii", &width, &height, &rowstride,
		&has_alpha, &bits, &channels);
	if (ret < 0) {
		sd_bus_message_exit_container(m);
		return false;
	}
	const void *pixels = NULL;
	size_t pixels_len = 0;
	ret = sd_bus_message_read_array(m, 'y', &pixels, &pixels_len);
	sd_bus_message_exit_container(m);
	if (ret < 0 || pixels == NULL) {
		return false;
	}

	char key[64];
	snprintf(key, sizeof(key), "notify:%u", id);
	if (!ui_image_put(n->ui, key, width, height, rowstride, has_alpha != 0,
			bits, channels, pixels, pixels_len)) {
		wlr_log(WLR_INFO, "notify: %s sent image-data we cannot read", key);
		return false;
	}
	free(*image_key);
	*image_key = strdup(key);
	return true;
}

/* --- the hints dictionary --- */

static bool is_image_data_hint(const char *key) {
	/* The name changed twice across spec versions and clients still send all
	 * three. Same hint, same treatment. */
	return strcmp(key, "image-data") == 0 ||
		strcmp(key, "image_data") == 0 ||
		strcmp(key, "icon_data") == 0;
}

/* One scalar out of a variant, into the passthrough table. Every basic DBus type
 * is one of these ten, and sd_bus writes each into the union member its type
 * character names, so the read is one call and the only branch left is how Lua
 * wants to see the result: a string, a boolean, or a number. Containers we did
 * not type never reach here; the caller skips them, which is what "dropped"
 * means to a parser. */
static void hint_scalar(sd_bus_message *m, struct hint_list *hints,
		const char *key, char type) {
	union {
		const char *s;
		int b;
		uint8_t y;
		int16_t n;
		uint16_t q;
		int32_t i;
		uint32_t u;
		int64_t x;
		uint64_t t;
		double d;
	} v = {0};
	if (sd_bus_message_read_basic(m, type, &v) < 0) {
		return;
	}

	double num;
	switch (type) {
	case 's':
	case 'o':
	case 'g': {
		if (v.s == NULL) {
			return;
		}
		struct queue_hint *h = hint_add(hints, key);
		h->type = QUEUE_HINT_STRING;
		h->str = strdup(v.s);
		return;
	}
	case 'b': {
		struct queue_hint *h = hint_add(hints, key);
		h->type = QUEUE_HINT_BOOL;
		h->boolean = v.b != 0;
		return;
	}
	case 'y': num = v.y; break;
	case 'n': num = v.n; break;
	case 'q': num = v.q; break;
	case 'i': num = v.i; break;
	case 'u': num = v.u; break;
	case 'x': num = (double)v.x; break;
	case 't': num = (double)v.t; break;
	case 'd': num = v.d; break;
	default:
		/* Not a basic type at all: nothing was read, so nothing is owed. */
		return;
	}
	struct queue_hint *h = hint_add(hints, key);
	h->type = QUEUE_HINT_NUMBER;
	h->num = num;
}

static int read_hints(struct kiln_notify *n, sd_bus_message *m, uint32_t id,
		struct hint_list *hints, char **urgency, char **image_key) {
	int ret = sd_bus_message_enter_container(m, 'a', "{sv}");
	if (ret < 0) {
		return ret;
	}
	while ((ret = sd_bus_message_enter_container(m, 'e', "sv")) > 0) {
		const char *key = NULL;
		if (sd_bus_message_read_basic(m, 's', &key) < 0 || key == NULL) {
			sd_bus_message_exit_container(m);
			continue;
		}
		const char *contents = NULL;
		char type = 0;
		if (sd_bus_message_peek_type(m, &type, &contents) < 0 ||
				contents == NULL) {
			sd_bus_message_exit_container(m);
			continue;
		}
		if (sd_bus_message_enter_container(m, 'v', contents) < 0) {
			sd_bus_message_exit_container(m);
			continue;
		}

		if (strcmp(key, "urgency") == 0 && strcmp(contents, "y") == 0) {
			uint8_t level = 0;
			if (sd_bus_message_read_basic(m, 'y', &level) >= 0) {
				const char *name = urgency_name(level);
				if (name != NULL) {
					free(*urgency);
					*urgency = strdup(name);
				}
			}
		} else if (is_image_data_hint(key) &&
				strcmp(contents, "(iiibiiay)") == 0) {
			image_data_put(n, m, id, image_key);
		} else if (strlen(contents) == 1) {
			hint_scalar(m, hints, key, contents[0]);
		} else {
			/* A container we did not type. Dropped. */
			sd_bus_message_skip(m, NULL);
		}

		sd_bus_message_exit_container(m); /* v */
		sd_bus_message_exit_container(m); /* e */
	}
	sd_bus_message_exit_container(m); /* a */
	return ret < 0 ? ret : 0;
}

/* --- the methods --- */

static int method_notify(sd_bus_message *m, void *data, sd_bus_error *err) {
	struct kiln_notify *n = data;
	const char *app_name = NULL, *app_icon = NULL;
	const char *summary = NULL, *body = NULL;
	uint32_t replaces_id = 0;
	int ret = sd_bus_message_read(m, "susss", &app_name, &replaces_id,
		&app_icon, &summary, &body);
	if (ret < 0) {
		return sd_bus_error_set_errno(err, -ret);
	}

	/* The client's own id when it is replacing, ours when it is not. Protocol
	 * arithmetic: C does not look up whether the id still names anything, and
	 * what replacing MEANS is Lua's. */
	uint32_t id = replaces_id != 0 ? replaces_id : ++n->next_id;

	/* actions is a flat list of alternating key and label. */
	struct action_list actions = {0};
	ret = sd_bus_message_enter_container(m, 'a', "s");
	if (ret < 0) {
		return sd_bus_error_set_errno(err, -ret);
	}
	const char *s = NULL;
	while (sd_bus_message_read_basic(m, 's', &s) > 0) {
		const char *label = NULL;
		if (sd_bus_message_read_basic(m, 's', &label) <= 0) {
			/* An odd-length list: the trailing key has no label. Keep the key,
			 * since that is what gets invoked, and let the display show it. */
			struct queue_action *a = action_add(&actions);
			a->key = strdup(s);
			a->label = strdup(s);
			break;
		}
		struct queue_action *a = action_add(&actions);
		a->key = strdup(s);
		a->label = strdup(label);
	}
	sd_bus_message_exit_container(m);

	struct hint_list hints = {0};
	char *urgency = NULL, *image_key = NULL;
	ret = read_hints(n, m, id, &hints, &urgency, &image_key);
	if (ret < 0) {
		return sd_bus_error_set_errno(err, -ret);
	}

	int32_t expire_timeout = -1;
	ret = sd_bus_message_read(m, "i", &expire_timeout);
	if (ret < 0) {
		return sd_bus_error_set_errno(err, -ret);
	}

	struct queue_notify_facts facts = {
		.id = id,
		.replaces_id = replaces_id,
		.app_name = app_name,
		.app_icon = app_icon,
		.summary = summary,
		.body = body,
		.urgency = urgency,
		.image = image_key,
		.expire_timeout = expire_timeout,
		.actions = actions.items,
		.actions_len = actions.len,
		.hints = hints.items,
		.hints_len = hints.len,
	};
	/* The queue takes the two lists whole; the two typed strings it copies. */
	queue_notify(n->queue, &facts);
	free(urgency);
	free(image_key);

	/* Answered now, before Lua has seen a thing: the reply is synchronous and
	 * the event does not drain until the next idle. */
	return sd_bus_reply_method_return(m, "u", id);
}

static int method_close(sd_bus_message *m, void *data, sd_bus_error *err) {
	struct kiln_notify *n = data;
	uint32_t id = 0;
	int ret = sd_bus_message_read(m, "u", &id);
	if (ret < 0) {
		return sd_bus_error_set_errno(err, -ret);
	}
	/* Reported, not obeyed. C closes nothing; Lua dismisses, and the
	 * NotificationClosed signal goes out when Lua says so. */
	queue_notify_close(n->queue, id);
	return sd_bus_reply_method_return(m, "");
}

/* Static, zero freedom. An honest claim about what the default display does:
 * it renders a body and it renders action buttons, and an icon it is given
 * rather than one it animates. */
static int method_capabilities(sd_bus_message *m, void *data,
		sd_bus_error *err) {
	(void)data;
	(void)err;
	return sd_bus_reply_method_return(m, "as", 3, "body", "actions",
		"icon-static");
}

static int method_server_info(sd_bus_message *m, void *data,
		sd_bus_error *err) {
	(void)data;
	(void)err;
	return sd_bus_reply_method_return(m, "ssss", "kiln", "kiln", "0.1", "1.2");
}

static const sd_bus_vtable notify_vtable[] = {
	SD_BUS_VTABLE_START(0),
	SD_BUS_METHOD("Notify", "susssasa{sv}i", "u", method_notify,
		SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("CloseNotification", "u", "", method_close,
		SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("GetCapabilities", "", "as", method_capabilities,
		SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("GetServerInformation", "", "ssss", method_server_info,
		SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_SIGNAL("NotificationClosed", "uu", 0),
	SD_BUS_SIGNAL("ActionInvoked", "us", 0),
	SD_BUS_VTABLE_END,
};

/* --- the two verbs: one signal emission each, and nothing else --- */

static void notify_op_closed(void *data, uint32_t id, int reason) {
	struct kiln_notify *n = data;
	sd_bus_emit_signal(kiln_dbus_bus(n->dbus), NOTIFY_PATH, NOTIFY_SERVICE,
		"NotificationClosed", "uu", id, (uint32_t)reason);
	kiln_dbus_wake(n->dbus);
}

static void notify_op_action(void *data, uint32_t id, const char *key) {
	struct kiln_notify *n = data;
	sd_bus_emit_signal(kiln_dbus_bus(n->dbus), NOTIFY_PATH, NOTIFY_SERVICE,
		"ActionInvoked", "us", id, key);
	kiln_dbus_wake(n->dbus);
}

struct kiln_notify *kiln_notify_create(struct kiln_dbus *dbus,
		struct core *core, struct queue *queue, struct ui *ui) {
	sd_bus *bus = kiln_dbus_bus(dbus);
	if (bus == NULL) {
		return NULL;
	}

	struct kiln_notify *n = calloc(1, sizeof(*n));
	n->dbus = dbus;
	n->queue = queue;
	n->ui = ui;

	int ret = sd_bus_add_object_vtable(bus, &n->slot, NOTIFY_PATH,
		NOTIFY_SERVICE, notify_vtable, n);
	if (ret < 0) {
		wlr_log(WLR_ERROR, "notify: cannot publish %s: %s", NOTIFY_PATH,
			strerror(-ret));
		free(n);
		return NULL;
	}

	ret = sd_bus_request_name(bus, NOTIFY_SERVICE, 0);
	if (ret < 0) {
		/* Another daemon holds the name. Theirs, then: we are a compositor
		 * without notifications, not a broken compositor. */
		wlr_log(WLR_INFO, "notify: %s is taken (%s); "
			"notifications are off", NOTIFY_SERVICE, strerror(-ret));
		sd_bus_slot_unref(n->slot);
		free(n);
		return NULL;
	}
	kiln_dbus_wake(dbus);

	struct core_notify_ops ops = {
		.closed = notify_op_closed,
		.action = notify_op_action,
		.data = n,
	};
	core_set_notify_ops(core, &ops);
	wlr_log(WLR_INFO, "notify: serving %s", NOTIFY_SERVICE);
	return n;
}

void kiln_notify_destroy(struct kiln_notify *n) {
	if (n == NULL) {
		return;
	}
	sd_bus_slot_unref(n->slot);
	free(n);
}

#else /* !KILN_DBUS */

#include <stddef.h>

struct kiln_notify *kiln_notify_create(struct kiln_dbus *dbus,
		struct core *core, struct queue *queue, struct ui *ui) {
	(void)dbus;
	(void)core;
	(void)queue;
	(void)ui;
	return NULL;
}

void kiln_notify_destroy(struct kiln_notify *notify) {
	(void)notify;
}

#endif /* KILN_DBUS */
