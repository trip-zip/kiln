# Testing Kiln

```sh
make check
make test
```

`make check` vets every package and checks widget API use. `make test` runs
every package's unit tests, then the `tests` package, which boots the built
`build/kiln` the way a user does and drives it over its IPC socket with Lua.
Every driven test runs in a private environment: its own runtime directory,
config, home and socket, with no bus. Nothing it does reaches your session.

## Backends

The driven tests draw with the headless backend by default. They render into
memory, and the screenshot verb reads the frame back, so pixel assertions
run without a display.

```sh
make test-nested
```

The same tests with the nested backend: Kiln opens as a window inside the
desktop you run the command from and draws with the real renderer. The
parent has to show that window. A tag or rule that hides it blocks the first
frame and the harness says so. Running tests on a physical seat is the
`run-tty` path below; point the harness at it with `KILN_SOCK` once the tests
grow a mode for an already running compositor.

Writing a driven test: `boot` gives a session, `expect_eval` compares one
reply, `expect_eventually` polls for facts that settle a frame later, and
`quit` asserts a clean exit, no assertion in the log and no leaked socket.
The harness touches only the process, the socket and the Lua API, so it
does not care what sits under the compositor.

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
