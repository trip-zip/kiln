# Kiln

Kiln is a Lua-configurable Wayland desktop built around one Clay layout tree
per output. Windows, bars, widgets, menus and notifications share that tree.
Lua declares it when something changes; Clay solves the layout; an Odin
renderer reconciles the result into wlroots' retained scene.

Kiln is developed at [trip-zip/kiln](https://github.com/trip-zip/kiln). The
maintainer uses it as a real desktop. The Lua API remains experimental.

## Desktop controls

Open two terminals, switch tags, cycle layouts, then open the inspector to see
the same tree that places the clients and bar. The stock config uses Super as
`mod`; Super+s shows the live binding sheet.

| Control | Action |
| --- | --- |
| Super+Return | Terminal, `$TERMINAL` or foot |
| Super+p / Super+r / Super+x | Application launcher / command prompt / Lua prompt |
| Super+1 through 5 | Select dev, web, chat, files or media |
| Super+Shift+number | Move the focused client to that tag |
| Super+j / k; Super+Tab | Cycle focus; return to previous client |
| Super+Space / Super+Shift+Space | Next / previous layout |
| Super+f / Super+m | Toggle fullscreen / maximised |
| Super+n / Super+Ctrl+n | Minimise / restore |
| Super+Ctrl+Space | Toggle floating |
| Super+left / right mouse drag | Move / resize |
| Super+w | Main menu, including theme selection |
| Super+Shift+i | Actual Clay inspector; select rows and scroll either pane |
| Super+Ctrl+r | Reload Lua config while keeping clients |
| Super+Shift+c / Super+Shift+q | Close client / quit Kiln |
| Super+Shift+Escape | Native lock |

Tags, layouts, placement rules, titlebars, widgets and input bindings are Lua
policy. The desktop includes notifications, StatusNotifier tray items, timers,
polls, subprocess streams, native Wayland and XWayland clients, layer-shell,
clipboard/primary selection, screenshots and session locking. Audio,
brightness and screenshot shortcuts call external tools (`wpctl`,
`brightnessctl`, `grim`, `slurp`). Native locking uses PAM.

## Build and launch

```sh
git clone https://github.com/trip-zip/kiln.git
cd kiln
```

The verified compiler is Odin `dev-2026-10-nightly:779c8c0`. Build tools are
GNU make, Python 3, gcc and ar. The current binding ABI targets wlroots 0.20.2.
Linked system libraries include wlroots-0.20, wayland-server, libinput,
xkbcommon, LuaJIT 2.1, cairo, pango/pangocairo, gdk-pixbuf/GLib/GObject,
libsystemd, PAM, xcb, xcb-ewmh and xcb-icccm. wlroots also brings its graphics
and device dependencies. XWayland is needed for X11 applications. The stock
desktop uses `rsvg-convert`, fonts and a terminal such as foot.

There is no bundled wlroots fallback or Meson feature switch here. This is
Odin compositor code over C dependencies, not a pure-Odin graphics stack.

Keep an unmodified Clay checkout at the exact revision in
[clay-dependency.json](clay-dependency.json), including its official Odin
binding. If you do not already have that checkout:

```sh
git clone https://github.com/nicbarker/clay.git "$HOME/tools/clay"
git -C "$HOME/tools/clay" checkout e6cc36941ab2af5d81107617039d6f527a1c660b
```

With that pinned checkout at `~/tools/clay`:

```sh
make
```

For another location, use `make CLAY_ROOT=/absolute/path/to/clay`. The build
verifies the revision and header/binding hashes before building `clay.a`.
It produces `build/kiln` and `build/kiln-client`.

Inside an existing desktop, start a nested session with its own bus and IPC:

```sh
kiln_demo=$(mktemp -d /tmp/kiln-demo.XXXXXX)
KILN_SOCK="$kiln_demo/eval.sock" KILN_RC="$PWD/kilnrc.lua" \
  dbus-run-session -- ./build/kiln -s foot
```

The window shows the stock config. Super+Return opens another terminal;
Super+Space changes layout; Super+Shift+q exits. Host shortcuts can intercept
Super in a nested window. `make run` builds and starts Kiln under a session bus
using your normal config and default IPC path. The command above gives a nested demo its own
socket. Logs go to the terminal; `run-tty` records a private log.

From a free physical TTY, run `./run-tty`. It builds Kiln, loads your normal
config, and opens foot using DRM/libinput with a private bus and IPC socket.
Quit the previous desktop first. Logs and the compositor PID are saved in the
directory recorded by `build/last-tty-trial`. Super+Shift+q quits. Keep a
separate console or SSH connection available for hardware and lock testing;
see [TESTING.md](TESTING.md#physical-sessions).

## Install and configure

To install into a user prefix:

```sh
make install prefix="$HOME/.local"
```

This installs `kiln`, `kiln-client`, bash/zsh/fish completions, a
`kiln.desktop` session entry named **Kiln**, and the Lua runtime/default
config under `<prefix>/share/kiln`. Display managers usually discover
system session directories; a user prefix is not a promise of login-menu
visibility. `make install` defaults to `/usr/local`; use appropriate write
permissions there. `DESTDIR` stages files but does not change compiled runtime
paths. To remove this installation use the same prefix with `make uninstall`;
its manifest limits removal to its own files.

Keep your existing `~/.config/kiln/rc.lua` and `theme`. For a new config only,
copy `kilnrc.lua` there without overwriting an existing file. Config search is:
`KILN_RC`, then `$XDG_CONFIG_HOME/kiln/rc.lua` (or `~/.config/kiln/rc.lua`), then
compiled `<datadir>/kiln/rc.lua`, then `kilnrc.lua` in the working directory.

The entry point is `local kiln = require("kiln")`. Use `kiln.ui` to declare
nodes, `kiln.key` and `kiln.rule` for controls and rules, and the `client`,
`screen`, `tag`, `layer`, `drag` and `notification` globals for desktop objects.
`core` is the lower-level verb API. In the Lua prompt, try `6*7`; over IPC,
`kiln` must be required because a config's local is not a global:

```sh
./build/kiln-client -s "$kiln_demo/eval.sock" eval 'return #client.all()'
./build/kiln-client -s "$kiln_demo/eval.sock" eval 'return require("kiln").modkey'
```

Use these from another terminal while that demo is running. An explicit socket
prevents contacting a different session. The Lua API and config directory retain
the Kiln name.

## Known limitations

The exact shared Clay clipping failures remain: a visible child in a
horizontal-only clip is missed by hit testing, and a nested outer-clip hit
incorrectly succeeds. Tests pin these outcomes in
[clay-contract-baseline.json](scripts/clay-contract-baseline.json) and
[clay-live-baseline.json](scripts/clay-live-baseline.json). Inspector palette styling is
deferred; a rejected raster can advance its private selection and a rejected
toggle needs retry. Private Clay state is not patched or rolled back.

Three XWayland limits are distinct: incoming X11-to-Wayland drag-and-drop is
unsupported; a slow incoming INCR transfer can truncate on EAGAIN; owner death
during incoming INCR can leave no EOF and retain one pipe FD. Provider guards
are wlroots 0.20.2 and XWayland 24.1.14. Ordinary supported-path soaks do not
count these as passing transfers.

Physical hotplug, DPMS, VRR/gamma, external locking and systematic mixed-scale
testing remain pending. Desktop/input, native/X clients, inspector, reload,
VT return and native lock/unlock have operator-reported physical success.

The [Kiln documentation](https://somewm.org/kiln/) covers workflows and the
Lua API.

## Tests and the C baseline

```sh
make check
make test
make compat-test
```

Tests extract the final C baseline from this repository's preserved Git history
into `build/c-baseline`; no separate C source checkout is required. Use a full
clone, or fetch the baseline history if your clone is shallow. `make c-baseline`
builds it for comparisons. `make compat-test` includes private compositors,
installed-runtime and completion checks. It needs the fixture tools described
in [TESTING.md](TESTING.md). `make audit-soak` runs the longer combined exercise.
The C implementation is retired from active development and preserved at
`c-baseline-82ad185`. Its exact source and recorded defect fingerprints remain
the comparison oracle, not a second maintained product.

## Licence

MIT; see [LICENSE](LICENSE). Releases through `v0.1.0` retain their earlier
GPLv3 grant. Clay is zlib licensed; the adapted LuaJIT binding preserves its
Odin distribution notice. Copies are in [licenses](licenses/); installation
includes them under `<datadir>/licenses/kiln`. Linked dependencies retain their
own licences. Kiln shares a maintainer with [SomeWM](https://github.com/trip-zip/somewm).
