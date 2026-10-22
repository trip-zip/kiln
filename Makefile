# make            build/kiln and build/kiln-client
# make run        build and run under a session bus
# make check      typecheck and vet
# make test       run every package's tests, then drive build/kiln headless
# make test-nested  the same driven tests inside the desktop you run this from
# make install    copy the build to $(prefix), default /usr/local
# make uninstall  remove what install copied
#
# odin does not create the -out directory, and --export-dynamic lets LuaJIT's
# ffi.C resolve procs the binary exports.

ODIN ?= odin
prefix ?= /usr/local
bindir ?= $(prefix)/bin
datadir ?= $(prefix)/share
DESTDIR ?=

DEFINES = -define:KILN_DATADIR="$(datadir)/kiln"
LDFLAGS = -extra-linker-flags:"-Wl,--export-dynamic"
CLAY = clay/linux/clay.a

.PHONY: all run check test test-nested install uninstall clean

all: build/kiln build/kiln-client

build/kiln: $(CLAY) $(shell find . -name '*.odin' -not -path './build/*')
	@mkdir -p build
	$(ODIN) build . $(DEFINES) -out:$@ $(LDFLAGS)

build/kiln-client: $(wildcard command_client/*.odin)
	@mkdir -p build
	$(ODIN) build command_client -out:$@

# Clay is a single-header C library; its archive is built once from the
# vendored header, next to the binding, the way Odin's vendor packages do.
$(CLAY): clay/clay.h
	@mkdir -p clay/linux
	gcc -x c -DCLAY_IMPLEMENTATION -fPIC -O2 -c clay/clay.h -o clay/linux/clay.o
	ar rcs $@ clay/linux/clay.o

# A private socket, so a desktop already running Kiln keeps its own.
run: all
	KILN_SOCK=$$(mktemp -u /tmp/kiln-run.XXXXXX) dbus-run-session -- ./build/kiln

check: $(CLAY)
	$(ODIN) check . -vet
	$(ODIN) check . -vet -define:KILN_OUTPUT_FIXTURE=true -define:KILN_AUTH_FIXTURE=true
	$(ODIN) check command_client -vet
	$(ODIN) check tests -vet -no-entry-point
	sh scripts/widget-lint.sh

# Clay keeps a process-global context and the D-Bus tests share one bus, so
# tests run on one thread.
test: all
	dbus-run-session -- $(ODIN) test . -all-packages -define:ODIN_TEST_THREADS=1 -out:build/kiln-test $(LDFLAGS)
	$(ODIN) test command_client -out:build/kiln-client-test
	$(ODIN) test tests -out:build/tests $(LDFLAGS)

test-nested: all
	KILN_TEST_BACKEND=nested $(ODIN) test tests -out:build/tests $(LDFLAGS)

install: all
	install -Dm755 build/kiln $(DESTDIR)$(bindir)/kiln
	install -Dm755 build/kiln-client $(DESTDIR)$(bindir)/kiln-client
	install -Dm644 kilnrc.lua $(DESTDIR)$(datadir)/kiln/rc.lua
	for f in $$(find lua -name '*.lua'); do install -Dm644 $$f $(DESTDIR)$(datadir)/kiln/$$f; done
	install -Dm644 kiln.desktop $(DESTDIR)$(datadir)/wayland-sessions/kiln.desktop
	install -Dm644 completions/kiln-client.bash $(DESTDIR)$(datadir)/bash-completion/completions/kiln-client
	install -Dm644 completions/_kiln-client $(DESTDIR)$(datadir)/zsh/site-functions/_kiln-client
	install -Dm644 completions/kiln-client.fish $(DESTDIR)$(datadir)/fish/vendor_completions.d/kiln-client.fish
	install -Dm644 LICENSE $(DESTDIR)$(datadir)/licenses/kiln/LICENSE
	install -Dm644 clay/LICENSE $(DESTDIR)$(datadir)/licenses/kiln/Clay.txt
	install -Dm644 luajit/LICENSE $(DESTDIR)$(datadir)/licenses/kiln/LuaJIT-binding.txt

uninstall:
	rm -f $(DESTDIR)$(bindir)/kiln $(DESTDIR)$(bindir)/kiln-client
	rm -rf $(DESTDIR)$(datadir)/kiln $(DESTDIR)$(datadir)/licenses/kiln
	rm -f $(DESTDIR)$(datadir)/wayland-sessions/kiln.desktop
	rm -f $(DESTDIR)$(datadir)/bash-completion/completions/kiln-client
	rm -f $(DESTDIR)$(datadir)/zsh/site-functions/_kiln-client
	rm -f $(DESTDIR)$(datadir)/fish/vendor_completions.d/kiln-client.fish

clean:
	rm -rf build clay/linux
