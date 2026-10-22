# Odin build wrapper.
#
#   make            # build build/kiln
#   make run        # build and run
#   make check      # typecheck and vet every package, no binary
#   make test       # run every package's tests
#   make clean      # remove build/
#
# Odin does not create the -out directory, so every target that links makes
# build/ first. --export-dynamic lets LuaJIT's ffi.C resolve procs the binary
# exports.

ODIN ?= odin
prefix ?= /usr/local
bindir ?= $(prefix)/bin
datadir ?= $(prefix)/share
DESTDIR ?=
RUNTIME_FLAGS = -define:KILN_DATADIR="$(datadir)/kiln"

CLAY_ROOT ?= $(HOME)/tools/clay
ODINFLAGS := -collection:deps=build
LDFLAGS := -extra-linker-flags:"-Wl,--export-dynamic"

.PHONY: all run check test clean compat-test clay-dependency

all: client build/clay/linux/clay.a
	@mkdir -p build
	$(ODIN) build . $(ODINFLAGS) $(RUNTIME_FLAGS) -out:build/kiln $(LDFLAGS)

run: all
	dbus-run-session -- ./build/kiln

check: build/clay/linux/clay.a
	$(ODIN) check command_client -vet
	sh scripts/widget-lint.sh
	python3 scripts/verify-clay-clips.py
	$(ODIN) check build/clay -vet -no-entry-point
	$(ODIN) check pam_raw -vet -no-entry-point
	$(ODIN) check pam -vet -no-entry-point
	$(ODIN) check authentication -vet -no-entry-point
	$(ODIN) check authentication -define:KILN_AUTH_FIXTURE=true -vet -no-entry-point
	$(ODIN) check sd_bus -vet -no-entry-point
	$(ODIN) check dbus -vet -no-entry-point
	$(ODIN) check desktop_bus $(ODINFLAGS) -vet -no-entry-point
	$(ODIN) check cairo $(ODINFLAGS) -vet -no-entry-point
	$(ODIN) check pango $(ODINFLAGS) -vet -no-entry-point
	$(ODIN) check gdk_pixbuf $(ODINFLAGS) -vet -no-entry-point
	$(ODIN) check readback $(ODINFLAGS) -vet -no-entry-point
	$(ODIN) check images $(ODINFLAGS) -vet -no-entry-point
	$(ODIN) check paint $(ODINFLAGS) -vet -no-entry-point
	$(ODIN) check scene_paint $(ODINFLAGS) -vet -no-entry-point
	$(ODIN) check layout $(ODINFLAGS) -vet -no-entry-point
	$(ODIN) check wlroots -vet -no-entry-point
	$(ODIN) check xcb_raw -vet -no-entry-point
	$(ODIN) check xcb_ewmh_raw -vet -no-entry-point
	$(ODIN) check xcb_ewmh -vet -no-entry-point
	$(ODIN) check xcb_icccm_raw -vet -no-entry-point
	$(ODIN) check xcb_icccm -vet -no-entry-point
	$(ODIN) check xcb -vet -no-entry-point
	$(ODIN) check xkbcommon -vet -no-entry-point
	$(ODIN) check libinput -vet -no-entry-point
	$(ODIN) check input_config -vet -no-entry-point
	$(ODIN) check keymap -vet -no-entry-point
	$(ODIN) check compositor $(ODINFLAGS) -vet -no-entry-point
	$(ODIN) check compositor $(ODINFLAGS) -define:KILN_OUTPUT_FIXTURE=true -vet -no-entry-point
	$(ODIN) check wayland_server -vet -no-entry-point
	$(ODIN) check wayland -vet -no-entry-point
	$(ODIN) check . $(ODINFLAGS) -vet
	$(ODIN) check luajit -vet -no-entry-point
	$(ODIN) check lua_runtime $(ODINFLAGS) -vet -no-entry-point
	$(ODIN) check ipc -vet -no-entry-point

# Clay has a process-global current context, so its tests run serially.
test: build/clay/linux/clay.a
	$(ODIN) test command_client -out:build/command-client-test
	python3 scripts/build-clay.py --root "$(CLAY_ROOT)" --test
	python3 scripts/verify-clay-clips.py
	$(ODIN) test build/clay -out:build/clay-test $(LDFLAGS)
	$(ODIN) test desktop_bus $(ODINFLAGS) -out:build/desktop-bus-test $(LDFLAGS)
	$(ODIN) test pam_raw -out:build/pam-raw-test
	$(ODIN) test pam -define:ODIN_TEST_THREADS=1 -out:build/pam-test
	$(ODIN) test authentication -out:build/authentication-test
	$(ODIN) test sd_bus -out:build/sd-bus-test
	dbus-run-session -- $(ODIN) test dbus -define:ODIN_TEST_THREADS=1 -out:build/dbus-test
	$(ODIN) test cairo $(ODINFLAGS) -define:ODIN_TEST_THREADS=1 -out:build/cairo-test $(LDFLAGS)
	$(ODIN) test pango $(ODINFLAGS) -define:ODIN_TEST_THREADS=1 -out:build/pango-test $(LDFLAGS)
	$(ODIN) test gdk_pixbuf $(ODINFLAGS) -out:build/gdk-pixbuf-test $(LDFLAGS)
	$(ODIN) test readback $(ODINFLAGS) -out:build/readback-test
	$(ODIN) test images $(ODINFLAGS) -define:ODIN_TEST_THREADS=1 -out:build/images-test $(LDFLAGS)
	$(ODIN) test paint $(ODINFLAGS) -define:ODIN_TEST_THREADS=1 -out:build/paint-test $(LDFLAGS)
	$(ODIN) test scene_paint $(ODINFLAGS) -define:ODIN_TEST_THREADS=1 -out:build/scene_paint-test $(LDFLAGS)
	$(ODIN) test layout $(ODINFLAGS) -define:ODIN_TEST_THREADS=1 -out:build/layout-test $(LDFLAGS)
	@mkdir -p build
	$(ODIN) test wlroots -out:build/wlroots-test $(LDFLAGS)
	$(ODIN) test xcb_raw -out:build/xcb-raw-test $(LDFLAGS)
	$(ODIN) test xcb_ewmh_raw -out:build/xcb_ewmh_raw-test $(LDFLAGS)
	$(ODIN) test xcb_ewmh -out:build/xcb_ewmh-test $(LDFLAGS)
	$(ODIN) test xcb_icccm_raw -out:build/xcb_icccm_raw-test $(LDFLAGS)
	$(ODIN) test xcb_icccm -out:build/xcb_icccm-test $(LDFLAGS)
	$(ODIN) test xcb -out:build/xcb-test $(LDFLAGS)
	$(ODIN) test xkbcommon -out:build/xkbcommon-test $(LDFLAGS)
	$(ODIN) test libinput -out:build/libinput-test $(LDFLAGS)
	$(ODIN) test input_config -out:build/input-config-test $(LDFLAGS)
	$(ODIN) test keymap -out:build/keymap-test $(LDFLAGS)
	$(ODIN) test compositor $(ODINFLAGS) -define:ODIN_TEST_THREADS=1 -out:build/compositor-test $(LDFLAGS)
	$(ODIN) test wayland_server -out:build/wayland-server-test $(LDFLAGS)
	$(ODIN) test wayland -out:build/wayland-test $(LDFLAGS)
	$(ODIN) test luajit -out:build/luajit-test $(LDFLAGS)
	$(ODIN) test lua_runtime $(ODINFLAGS) -define:ODIN_TEST_THREADS=1 -out:build/lua-runtime-test $(LDFLAGS)
	$(ODIN) test ipc -out:build/ipc-test $(LDFLAGS)

clean:
	rm -rf build

# The manifest checks root, commit and content even when source timestamps go backwards.
clay-dependency:
	python3 scripts/build-clay.py --root "$(CLAY_ROOT)"

build/clay/linux/clay.a: clay-dependency

compat-test: all
	python3 scripts/compat-test.py --check-installed

.PHONY: audit-soak
audit-soak: all
	python3 scripts/audit_soak.py --cycles 10 --seconds 600

.PHONY: auth-fixture
auth-fixture: build/clay/linux/clay.a
	$(ODIN) build . $(ODINFLAGS) -define:KILN_AUTH_FIXTURE=true -define:KILN_OUTPUT_FIXTURE=true -out:build/kiln-auth-fixture $(LDFLAGS)

.PHONY: client
client:
	@mkdir -p build
	$(ODIN) build command_client -out:build/kiln-client

.PHONY: install uninstall
install: all
	python3 scripts/install.py install --bindir "$(bindir)" --datadir "$(datadir)" --destdir "$(DESTDIR)"

uninstall:
	python3 scripts/install.py uninstall --bindir "$(bindir)" --datadir "$(datadir)" --destdir "$(DESTDIR)"

.PHONY: c-baseline
c-baseline:
	python3 scripts/c_baseline.py --build
