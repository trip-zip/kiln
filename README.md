# Kiln

A Wayland compositor in Odin, configured in Lua. Each output is one Clay
layout tree: windows, bars, widgets, menus and notifications all live in it.
Lua declares the tree when something changes, Clay solves it, and the
renderer reconciles the result into the scene.

Documentation, including the Lua API, is at [somewm.org/kiln](https://somewm.org/kiln/).

## Build

Needs Odin (nightly), GNU make, gcc and ar, plus wlroots 0.20, LuaJIT 2.1,
cairo, pango, gdk-pixbuf, libsystemd, PAM and xcb. Clay is vendored.

```sh
make
```

Try it as a window inside your current desktop:

```sh
make run
```

## Install

```sh
sudo make install
```

Then start `kiln` from a TTY. The default config is `kilnrc.lua`; copy it to
`~/.config/kiln/rc.lua` to make it yours. `make uninstall` removes everything
`make install` put down. `prefix` and `DESTDIR` work as usual.

## Test

```sh
make check        # vet every package
make test         # unit tests, then drive the built compositor headless
make test-nested  # the same, visible as a window in your desktop
```

See [TESTING.md](TESTING.md).

## Licence

MIT, see [LICENSE](LICENSE). Clay is zlib licensed (`clay/LICENSE`); the
LuaJIT binding keeps its notice in `luajit/LICENSE`.
