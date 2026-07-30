# Meson build system wrapper.
#
#   make                 # build (configures build/ if needed)
#   make run             # build + run the DAILY session: default IPC socket,
#                        # log at ~/.cache/kiln.log (previous run kept as .old)
#   make dev             # build + run a nested dev instance: auto-picks a free
#                        # /tmp/kiln-dev-N.sock and matching log, prints both
#   make headless        # build + run an invisible instance for IPC-driven
#                        # tests, same auto-pick on /tmp/kiln-headless-N.*
#   make measure         # RSS breakdown + timing rollup + latest gauges for
#                        # every running kiln (log recovered from its stderr)
#   make soak            # the #30 regression soaks: cache-soak + sweep-soak
#   sudo make install    # install to $(prefix) (default /usr/local)
#   make uninstall       # remove the installed files
#   make clean           # remove build/
#   make reconfigure     # wipe and reconfigure build/
#
# Convention the targets encode: the daily session owns the default socket so
# every script works against it with no env vars; dev/headless instances get
# private sockets so they can never steal the live session's.
#
# Override prefix/buildtype/MESON_OPTS on the command line or in .local.mk,
# e.g. `make prefix=$HOME/.local` or `echo 'buildtype := debug' > .local.mk`.
# prefix and buildtype are fixed at configure time; change them before the
# first build, or `make reconfigure`.

-include .local.mk

prefix ?= /usr/local
buildtype ?= release

.PHONY: all run dev headless measure soak install uninstall clean setup reconfigure

all:
	@test -d build || meson setup build --prefix=$(prefix) -Dbuildtype=$(buildtype) $(MESON_OPTS)
	ninja -C build

run: all
	@mkdir -p $(HOME)/.cache
	@mv -f $(HOME)/.cache/kiln.log $(HOME)/.cache/kiln.log.old 2>/dev/null || true
	dbus-run-session ./build/kiln 2>$(HOME)/.cache/kiln.log

dev: all
	@n=1; while [ -e /tmp/kiln-dev-$$n.sock ]; do n=$$((n+1)); done; \
	echo "dev instance: KILN_SOCK=/tmp/kiln-dev-$$n.sock  log=/tmp/kiln-dev-$$n.log"; \
	KILN_SOCK=/tmp/kiln-dev-$$n.sock ./build/kiln 2>/tmp/kiln-dev-$$n.log

headless: all
	@n=1; while [ -e /tmp/kiln-headless-$$n.sock ]; do n=$$((n+1)); done; \
	echo "headless instance: KILN_SOCK=/tmp/kiln-headless-$$n.sock  log=/tmp/kiln-headless-$$n.log"; \
	WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
		KILN_SOCK=/tmp/kiln-headless-$$n.sock ./build/kiln 2>/tmp/kiln-headless-$$n.log

measure:
	@scripts/measure.sh

soak: all
	scripts/cache-soak.sh
	scripts/sweep-soak.sh

install: all
	meson install -C build

uninstall:
	ninja -C build uninstall

clean:
	rm -rf build

setup:
	meson setup build --prefix=$(prefix) -Dbuildtype=$(buildtype) $(MESON_OPTS)

reconfigure:
	rm -rf build
	meson setup build --prefix=$(prefix) -Dbuildtype=$(buildtype) $(MESON_OPTS)
