# Testing Kiln

Run from a full clone after building the pinned Clay dependency. All runtime
checks use owned private processes, sockets and test data. Never select a live
socket or kill a compositor by name.

```sh
make check
make test
make compat-test
```

`make check` vets packages, checks widget API use and asserts the exact known
Clay clipping outcomes. `make test` covers package ownership, ABI and recovery,
including the upstream/C Clay contract fingerprint. `make compat-test` exercises
native/X11 clients, rendering, input, services, CLI/completions, installation,
reload/recovery and authentication fixtures. It includes an isolated C comparison
and builds private fixture binaries. It can take around twenty minutes.

The tested workstation supplies Python 3 with Pillow and PyGObject (Gio/GLib),
OpenBSD netcat (`nc -U -N`), gcc, make, ar, pkg-config, Meson/Ninja, Xvfb,
XWayland, xterm, xprop, xwininfo, xdotool, wev, foot, grim, rsvg-convert,
ImageMagick, desktop-file-validate, D-Bus tools, bash and zsh. Fish adds actual
fish completion coverage. Missing required providers fail their checks; read
explicit NOT RUN or UNAVAILABLE records rather than counting skipped checks as
passes. System libraries and fonts must match the comparison receipts when
reproducing exact pixels or provider-specific defects.

The full application group runs zenity (GTK), VLC (Qt), Firefox and FreeCol
(Java). Its package-version receipts currently use Arch's `pacman`; the full
suite has been verified on that workstation, not every distribution. Prepare
the hash-pinned Java/FreeCol packages in the private cache when absent:

```sh
python3 scripts/prepare-xwayland-apps.py
```

That helper downloads and extracts two pinned Arch packages using `bsdtar`,
without host installation. `KILN_APP_ROOT` selects an alternate extracted root;
the default is `~/.cache/kiln-session16-apps/root`. Preserve its `packages.json`
and package archives with the test receipts. It does not install zenity, VLC
or Firefox. `KILN_APP_CASES` can select a subset for focused debugging, but a
subset is not a full compatibility pass.

## Final C comparison source

`c-baseline-82ad185` identifies
`82ad185fad98bcebf191df047494a9561ffb043b`, the retired C implementation.
`scripts/c_baseline.py` extracts that exact commit from Git into the ignored
`build/c-baseline` directory on first use. It does not consult `~/tools/kiln`
or download another product. Do not edit the extracted fixture. It can be
regenerated from history after cleaning the build directory.

```sh
make c-baseline
python3 scripts/original_battery_checks.py quit bar widget popup launcher pipe poll
python3 scripts/original_battery_checks.py quit bar widget popup launcher pipe poll \
  --binary "$PWD/build/c-baseline/build/kiln" --implementation c
```

The baseline build uses its original Meson configuration and vendored Clay
v0.14. Kiln itself uses unmodified upstream Clay `e6cc369` with its official
Odin binding. Do not unify the dependencies or patch either to change the
comparison result. `--original` remains available on comparison entry points
when an explicit baseline source directory is useful.

A shallow clone may lack the C commit. Fetch full history before tests:

```sh
git fetch --unshallow origin
```

That command is only for shallow clones. Source tarballs do not contain the
history needed for C comparison tests; use a Git clone for those tests.

## Focused checks

```sh
python3 scripts/verify-layout.py
python3 scripts/verify-clay-clips.py
python3 scripts/install_checks.py --config /path/to/reviewed/rc.lua \
  --theme /path/to/reviewed/theme
make audit-soak
```

The install check copies the selected config/theme into a disposable installed
runtime and exercises daily actions with native input; it does not overwrite the
originals. Review a custom config's external effects before passing it. The
combined soak uses fixture authentication, never real credentials.

Ideal-behaviour probes such as
`python3 scripts/verify-clay-clips.py --strict` still fail on the documented
shared defects. Normal gates assert their exact fingerprints, not a claim that
those bugs are fixed. The expected observations are stored in
`scripts/clay-contract-baseline.json` and `scripts/clay-live-baseline.json`.

## Physical sessions

Run `./run-tty` from a free physical TTY after ending the previous desktop.
It uses your real config, home, application data and cache. Config actions
have their normal effects. The launcher records its log, PID and private IPC
socket in the directory named by `build/last-tty-trial`.

From a separate console in the same checkout, inspect that session explicitly:

```sh
read -r kiln_trial < build/last-tty-trial
./build/kiln-client -s "$kiln_trial/eval.sock" ping
./build/kiln-client -s "$kiln_trial/eval.sock" output list
```

Super+Shift+q quits normally. If input fails, use the same private socket with
`eval 'core.quit()'`. Lock policy suppresses IPC quit and compositor VT shortcuts;
establish an independent SSH recovery connection before lock testing. If needed,
signal only the PID recorded in `compositor.pid`, after verifying its executable
is this checkout's `build/kiln`. Never kill a compositor by name.

Check ordinary rendering, input and VT return before output power, hotplug or
locking. Record monitor modes, scales, GPU/driver and renderer when reporting
failures. Enter passwords only in the lock UI. Screenshots and fixture
authentication do not establish physical scanout or real-seat lock correctness.
