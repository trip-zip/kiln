/* kiln-client: the command line onto a running compositor.
 *
 *   kiln-client client list
 *   kiln-client tag view web
 *   kiln-client --json screen list
 *   kiln-client set client focused floating true
 *
 * A dumb pipe by design. Every verb is resolved by the compositor, so this
 * program knows no verb names: it quotes its arguments into one command,
 * wraps that in the dispatch call, writes it, and prints what comes back.
 * Adding a verb never means touching this file.
 *
 * The socket answers one request per connection and closes, so EOF frames
 * the reply and no terminator has to be scanned for. A reply holding a blank
 * line is therefore still read whole.
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* Matches the compositor's own discovery: an explicit socket first, so a
 * nested or headless instance is addressable without disturbing the session
 * that owns the default path. */
static int connect_socket(const char *override)
{
	struct sockaddr_un addr = { 0 };
	char path[sizeof(addr.sun_path)];
	int n;

	if (override != NULL && override[0] != '\0') {
		n = snprintf(path, sizeof(path), "%s", override);
	} else {
		const char *dir = getenv("XDG_RUNTIME_DIR");
		n = snprintf(path, sizeof(path), "%s/kiln.sock",
			dir != NULL ? dir : "/tmp");
	}
	/* Said here rather than let through, because the truncated path would
	 * then be what the connect error names: a path the caller never gave. */
	if (n < 0 || (size_t)n >= sizeof(path)) {
		fprintf(stderr, "kiln-client: socket path is longer than the %zu "
			"bytes a unix socket allows\n", sizeof(path) - 1);
		return -1;
	}

	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		perror("kiln-client: socket");
		return -1;
	}
	addr.sun_family = AF_UNIX;
	snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		fprintf(stderr, "kiln-client: cannot connect to %s: %s\n",
			path, strerror(errno));
		fprintf(stderr, "kiln-client: is kiln running? (set KILN_SOCK to "
			"address another instance)\n");
		close(fd);
		return -1;
	}
	return fd;
}

/* Growable byte buffer, used for both the request and the reply. */
struct buf {
	char *data;
	size_t len, cap;
};

static void buf_add(struct buf *b, const char *src, size_t n)
{
	if (b->len + n + 1 > b->cap) {
		b->cap = (b->len + n + 1) * 2;
		b->data = realloc(b->data, b->cap);
		if (b->data == NULL) {
			fprintf(stderr, "kiln-client: out of memory\n");
			exit(2);
		}
	}
	memcpy(b->data + b->len, src, n);
	b->len += n;
	b->data[b->len] = '\0';
}

static void buf_str(struct buf *b, const char *s)
{
	buf_add(b, s, strlen(s));
}

/* One argument, quoted only when it has to be. Quoting is not cosmetic and
 * this cannot become quote-everything: on the far side a quoted word stays a
 * string while a bare one is read as the value it looks like, which is what
 * lets a title of "42" be set without arriving as the number 42, and equally
 * what lets a width of 40 arrive as a number rather than as text. So a word
 * gets quotes exactly when leaving it bare would lose it: when it holds a
 * byte the tokenizer splits on or a quote of its own, or when it is empty and
 * would vanish entirely.
 *
 * Which means the set below has to agree with the character class that
 * tokenizer splits on, in another language, in another file, with nothing but
 * a battery assertion holding the two together. */
static void append_arg(struct buf *b, const char *arg)
{
	int needs = arg[0] == '\0';
	for (const char *p = arg; *p != '\0' && !needs; p++) {
		if (strchr(" \t\n\r\v\f\"'\\", *p) != NULL) {
			needs = 1;
		}
	}
	if (!needs) {
		buf_str(b, arg);
		return;
	}
	buf_str(b, "\"");
	for (const char *p = arg; *p != '\0'; p++) {
		if (*p == '"' || *p == '\\') {
			char esc[2] = { '\\', *p };
			buf_add(b, esc, 2);
		} else {
			buf_add(b, p, 1);
		}
	}
	buf_str(b, "\"");
}

/* The command as a Lua string literal. Escaping every byte rather than using
 * a long bracket means no delimiter can collide with the payload, whatever a
 * title or a pattern happens to contain. */
static void append_lua_string(struct buf *b, const char *s, size_t n)
{
	buf_str(b, "\"");
	for (size_t i = 0; i < n; i++) {
		unsigned char c = (unsigned char)s[i];
		char tmp[8];
		if (c == '"' || c == '\\') {
			snprintf(tmp, sizeof(tmp), "\\%c", c);
		} else if (c == '\n') {
			snprintf(tmp, sizeof(tmp), "\\n");
		} else if (c == '\r') {
			snprintf(tmp, sizeof(tmp), "\\r");
		} else if (c < 0x20 || c == 0x7f) {
			snprintf(tmp, sizeof(tmp), "\\%03u", c);
		} else {
			tmp[0] = (char)c;
			tmp[1] = '\0';
		}
		buf_str(b, tmp);
	}
	buf_str(b, "\"");
}

static void usage(FILE *out, const char *prog)
{
	fprintf(out,
"Usage: %s [OPTIONS] COMMAND [ARGS...]\n"
"\n"
"OPTIONS:\n"
"  --json                 reply as one JSON object\n"
"  -s, --socket PATH      address a specific instance (else $KILN_SOCK)\n"
"  -h, --help             this text\n"
"\n"
"The verb list lives in the compositor, not here:\n"
"  %s help                every verb, with what it takes\n"
"  %s help VERB           one verb, or one namespace\n"
"  %s commands            every verb name, one per line\n"
"  %s reflect [CLASS]     every method, getter, setter, and property\n"
"\n"
"REFLECTION (reaches the whole object API):\n"
"  get  <class> <selector> <property>\n"
"  set  <class> <selector> <property> <value>\n"
"  call <class> <selector> <method> [args...]\n"
"\n"
"  class     client, screen, tag, layer, notification\n"
"  selector  a handle, a name, `focused`, `all`, `previous`,\n"
"            or a <field>:<pattern> filter such as app_id:firefox\n"
"  an argument written @<class>:<selector> resolves to that object\n"
"\n"
"EXAMPLES:\n"
"  %s client list\n"
"  %s tag view web\n"
"  %s set client focused floating true\n"
"  %s call client focused toggle_fullscreen\n"
"  %s call client focused swap @client:app_id:foot\n"
"  %s --json screen list\n"
"  %s eval 'return #client.all()'\n",
		prog, prog, prog, prog, prog, prog,
		prog, prog, prog, prog, prog, prog);
}

int main(int argc, char *argv[])
{
	const char *prog = "kiln-client";
	const char *sock_path = getenv("KILN_SOCK");
	int json = 0;
	int i = 1;

	for (; i < argc; i++) {
		if (strcmp(argv[i], "--json") == 0) {
			json = 1;
		} else if (strcmp(argv[i], "-h") == 0 ||
				strcmp(argv[i], "--help") == 0) {
			usage(stdout, prog);
			return 0;
		} else if (strcmp(argv[i], "-s") == 0 ||
				strcmp(argv[i], "--socket") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "kiln-client: --socket needs a path\n");
				return 2;
			}
			sock_path = argv[++i];
		} else if (argv[i][0] == '-' && argv[i][1] == '-' &&
				argv[i][2] != '\0') {
			/* Anything else long-dashed is the verb's own flag (notify
			 * --title), so argument parsing stops here. */
			break;
		} else {
			break;
		}
	}

	if (i >= argc) {
		usage(stderr, prog);
		return 2;
	}

	struct buf cmd = { 0 };
	if (json) {
		buf_str(&cmd, "--json ");
	}
	for (int a = i; a < argc; a++) {
		if (a > i) {
			buf_str(&cmd, " ");
		}
		append_arg(&cmd, argv[a]);
	}

	/* Wrapped, never sent bare: a verb is frequently valid Lua on its own
	 * (`quit` evaluates to nil), so a socket that had to guess which of the
	 * two it was reading would sometimes guess wrong and succeed silently. */
	struct buf req = { 0 };
	buf_str(&req, "return kiln_ipc(");
	append_lua_string(&req, cmd.data, cmd.len);
	buf_str(&req, ")");
	free(cmd.data);

	int fd = connect_socket(sock_path);
	if (fd < 0) {
		free(req.data);
		return 2;
	}

	size_t off = 0;
	while (off < req.len) {
		ssize_t n = write(fd, req.data + off, req.len - off);
		if (n > 0) {
			off += (size_t)n;
		} else if (n < 0 && errno == EINTR) {
			continue;
		} else {
			perror("kiln-client: write");
			free(req.data);
			close(fd);
			return 2;
		}
	}
	free(req.data);
	/* Half close: the compositor evaluates on EOF, and the read side stays
	 * open for the reply. */
	shutdown(fd, SHUT_WR);

	struct buf reply = { 0 };
	for (;;) {
		char chunk[4096];
		ssize_t n = read(fd, chunk, sizeof(chunk));
		if (n > 0) {
			buf_add(&reply, chunk, (size_t)n);
		} else if (n == 0) {
			break;
		} else if (errno == EINTR) {
			continue;
		} else {
			perror("kiln-client: read");
			free(reply.data);
			close(fd);
			return 2;
		}
	}
	close(fd);

	int status = 0;
	if (reply.data == NULL) {
		fprintf(stderr, "kiln-client: empty reply\n");
		free(reply.data);
		return 2;
	}

	/* Only a reply that is actually an object gets read as JSON. Anything
	 * escaping the dispatcher comes back in the eval layer's own plain
	 * `ERROR:` form, and classifying that by a substring search would put an
	 * error on stdout under exit 0 for a caller that asked for JSON
	 * precisely so it could tell the two apart. */
	if (json && reply.data[0] == '{') {
		/* The encoder sorts its keys, so an error object always carries
		 * this pair verbatim. */
		status = strstr(reply.data, "\"status\":\"error\"") != NULL;
		fputs(reply.data, status ? stderr : stdout);
	} else if (strncmp(reply.data, "OK\n", 3) == 0) {
		/* A verb that did its work and had nothing to say prints nothing:
		 * the header is the whole reply. */
		fputs(reply.data + 3, stdout);
	} else {
		/* Both the dispatcher's `ERROR msg` and the eval layer's own
		 * `ERROR: msg` land here, as does anything unrecognized. */
		fputs(reply.data, stderr);
		status = 1;
	}

	free(reply.data);
	return status;
}
