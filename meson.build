project(
  'kiln',
  'c',
  version: '0.1.0',
  default_options: [
    'c_std=c11',
    'warning_level=2',
  ],
)

# Where the packaged rc.lua and lua/ library land on install.
# Baked into the binary so an installed kiln finds its config and library from
# any working directory (see resolve_rc_path in kiln.c, add_package_path in
# core.c).
kiln_datadir = get_option('prefix') / get_option('datadir') / 'kiln'

add_project_arguments(
  [
    '-DWLR_USE_UNSTABLE',
    '-D_POSIX_C_SOURCE=200809L',
    '-Wno-unused-parameter',
    '-DKILN_DATADIR="' + kiln_datadir + '"',
  ],
  language: 'c',
)

cc = meson.get_compiler('c')

# XWayland is a build-time choice: wlroots must be compiled with it, kiln
# gains the WM-side XCB connection, and KILN_XWAYLAND guards every X11 line.
xwayland_enabled = get_option('xwayland').enabled()
wlr_xwayland_opt = xwayland_enabled ? 'xwayland=enabled' : 'xwayland=disabled'

# wlroots 0.20, pinned: use the system package when it satisfies the pin,
# otherwise build the vendored subproject (subprojects/wlroots.wrap, wrap-git
# at the pinned revision), so any machine builds reproducibly. A system
# wlroots only counts if it was itself built with xwayland when we need it
# (WLR_HAS_XWAYLAND in wlr/config.h); otherwise the subproject provides it.
wlroots = dependency(
  'wlroots-0.20',
  version: '>=0.20.1',
  required: false,
  default_options: ['examples=false', wlr_xwayland_opt],
)
wlroots_usable = wlroots.found()
if wlroots_usable and xwayland_enabled
  wlroots_usable = cc.compiles(
    '#include <wlr/config.h>\n#if !WLR_HAS_XWAYLAND\n#error no xwayland\n#endif\n',
    dependencies: wlroots,
    name: 'system wlroots has xwayland',
  )
endif
if not wlroots_usable
  message('System wlroots 0.20 not found or unusable, building from subproject...')
  wlroots_proj = subproject('wlroots', default_options: [
    'examples=false',
    wlr_xwayland_opt,
  ])
  wlroots = wlroots_proj.get_variable('wlroots')
endif
wayland_server = dependency('wayland-server')
# wayland-client: only the test fixtures link it (scripts/wl-activate.c), never kiln.
wayland_client = dependency('wayland-client')
xkbcommon = dependency('xkbcommon')
# libinput is the device config set_pointer writes; pixman is the region
# a confined pointer is clamped into.
libinput = dependency('libinput')
pixman = dependency('pixman-1')

luajit = dependency('luajit')
cairo = dependency('cairo')
pangocairo = dependency('pangocairo')
gdk_pixbuf = dependency('gdk-pixbuf-2.0')
libm = meson.get_compiler('c').find_library('m')

wayland_protocols = dependency('wayland-protocols')
wayland_scanner = find_program('wayland-scanner', native: true)
protocols_dir = wayland_protocols.get_variable('pkgdatadir')

# PAM gates the native lockscreen's unlock. It ships no pkg-config, so probe
# the library directly; -Dpam=disabled swaps in the build-time test stub.
kiln_deps_extra = []
kiln_args_extra = []
if get_option('pam').enabled()
  pam = cc.find_library('pam')
  kiln_deps_extra += pam
else
  kiln_args_extra += '-DKILN_PAM_STUB'
endif

# xcb is the WM-side X connection (xcb_kill_client plus minimal atoms).
# xcb-ewmh decodes _NET_WM_ICON (the iterator over its size-prefixed frames),
# the one property wlroots hands back raw for us to read.
if xwayland_enabled
  kiln_deps_extra += dependency('xcb')
  kiln_deps_extra += dependency('xcb-ewmh')
  kiln_args_extra += '-DKILN_XWAYLAND'
endif

# sd-bus, the one DBus connection the notify and tray services share.
# libsystemd and basu are the same API behind different headers, so
# the only difference the code sees is which one to include.
if get_option('dbus').enabled()
  sdbus = dependency('libsystemd', required: false)
  if sdbus.found()
    kiln_args_extra += '-DKILN_SDBUS_SYSTEMD'
  else
    sdbus = dependency('basu', required: true,
      not_found_message: 'dbus needs libsystemd or basu; build with -Ddbus=disabled to go without')
  endif
  kiln_deps_extra += sdbus
  kiln_args_extra += '-DKILN_DBUS'
endif

xdg_shell_h = custom_target(
  'xdg-shell-protocol.h',
  input: protocols_dir / 'stable/xdg-shell/xdg-shell.xml',
  output: 'xdg-shell-protocol.h',
  command: [wayland_scanner, 'server-header', '@INPUT@', '@OUTPUT@'],
)

# wlr-layer-shell is a wlroots protocol, not in wayland-protocols; the XML is
# vendored under protocols/ so a system-wlroots build never depends on the
# subproject checkout.
layer_shell_h = custom_target(
  'wlr-layer-shell-unstable-v1-protocol.h',
  input: 'protocols/wlr-layer-shell-unstable-v1.xml',
  output: 'wlr-layer-shell-unstable-v1-protocol.h',
  command: [wayland_scanner, 'server-header', '@INPUT@', '@OUTPUT@'],
)

# Client-side protocol glue for the wl-activate test fixture (scripts/wl-activate.c).
# Only the fixture links these; kiln itself is a server and never does. xdg-shell
# maps the toplevel, xdg-activation drives the request under test.
xdg_shell_client_h = custom_target(
  'xdg-shell-client-protocol.h',
  input: protocols_dir / 'stable/xdg-shell/xdg-shell.xml',
  output: 'xdg-shell-client-protocol.h',
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
)
xdg_shell_client_c = custom_target(
  'xdg-shell-protocol.c',
  input: protocols_dir / 'stable/xdg-shell/xdg-shell.xml',
  output: 'xdg-shell-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)
xdg_activation_client_h = custom_target(
  'xdg-activation-v1-client-protocol.h',
  input: protocols_dir / 'staging/xdg-activation/xdg-activation-v1.xml',
  output: 'xdg-activation-v1-client-protocol.h',
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
)
xdg_activation_client_c = custom_target(
  'xdg-activation-v1-protocol.c',
  input: protocols_dir / 'staging/xdg-activation/xdg-activation-v1.xml',
  output: 'xdg-activation-v1-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)
# wlr-foreign-toplevel-management client glue for the wl-toplevel test fixture
# (scripts/wl-toplevel.c). kiln's server half uses the wlroots C API and needs no
# generated code; only the fixture, which speaks the wire protocol, does. The XML
# is vendored under protocols/ like wlr-layer-shell.
foreign_toplevel_client_h = custom_target(
  'wlr-foreign-toplevel-management-unstable-v1-client-protocol.h',
  input: 'protocols/wlr-foreign-toplevel-management-unstable-v1.xml',
  output: 'wlr-foreign-toplevel-management-unstable-v1-client-protocol.h',
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
)
foreign_toplevel_client_c = custom_target(
  'wlr-foreign-toplevel-management-unstable-v1-protocol.c',
  input: 'protocols/wlr-foreign-toplevel-management-unstable-v1.xml',
  output: 'wlr-foreign-toplevel-management-unstable-v1-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)
# fractional-scale + viewporter client glue for the wl-fractional test fixture
# (scripts/wl-fractional.c): the client reads the exact scale kiln hands its
# surface. kiln's server half is a plain wlroots global and needs no generated
# code; only the fixture, which speaks the wire protocol, does.
fractional_scale_client_h = custom_target(
  'fractional-scale-v1-client-protocol.h',
  input: protocols_dir / 'staging/fractional-scale/fractional-scale-v1.xml',
  output: 'fractional-scale-v1-client-protocol.h',
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
)
fractional_scale_client_c = custom_target(
  'fractional-scale-v1-protocol.c',
  input: protocols_dir / 'staging/fractional-scale/fractional-scale-v1.xml',
  output: 'fractional-scale-v1-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)
viewporter_client_h = custom_target(
  'viewporter-client-protocol.h',
  input: protocols_dir / 'stable/viewporter/viewporter.xml',
  output: 'viewporter-client-protocol.h',
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
)
viewporter_client_c = custom_target(
  'viewporter-protocol.c',
  input: protocols_dir / 'stable/viewporter/viewporter.xml',
  output: 'viewporter-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)

# idle-inhibit client glue for the wl-inhibit test fixture (scripts/wl-inhibit.c):
# the client binds the manager and holds idle off. kiln's server half is a
# plain wlroots global; only the fixture speaks the wire.
idle_inhibit_client_h = custom_target(
  'idle-inhibit-unstable-v1-client-protocol.h',
  input: protocols_dir / 'unstable/idle-inhibit/idle-inhibit-unstable-v1.xml',
  output: 'idle-inhibit-unstable-v1-client-protocol.h',
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
)
idle_inhibit_client_c = custom_target(
  'idle-inhibit-unstable-v1-protocol.c',
  input: protocols_dir / 'unstable/idle-inhibit/idle-inhibit-unstable-v1.xml',
  output: 'idle-inhibit-unstable-v1-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)

# The cdef-sync guard. LuaJIT never checks a ffi.cdef against the C it names,
# so the boundary's cdef is compiled here against the real headers: a drifted
# signature or struct layout fails the build instead of corrupting a frame.
# Generated from lua/kiln/cffi.lua, which stays the one place a cdef is written.
cdef_guard_c = custom_target(
  'cdef_guard.c',
  input: 'lua/kiln/cffi.lua',
  output: 'cdef_guard.c',
  command: [find_program('scripts/gen-cdef-guard.py'), '@INPUT@', '@OUTPUT@'],
)

executable(
  'kiln',
  ['kiln.c', 'ui.c', 'render.c', 'core.c', 'queue.c', 'clay_impl.c',
   'pam_auth.c', 'dbus.c', 'notify.c', 'tray.c',
   xdg_shell_h, layer_shell_h, cdef_guard_c],
  include_directories: include_directories('third_party'),
  c_args: kiln_args_extra,
  # ffi.C resolves against the running executable's dynamic symbol table, so
  # the exported kiln_* verbs must be in it.
  export_dynamic: true,
  dependencies: [
    wlroots,
    wayland_server,
    xkbcommon,
    libinput,
    pixman,
    luajit,
    cairo,
    pangocairo,
    gdk_pixbuf,
    libm,
  ] + kiln_deps_extra,
  install: true,
)

# The command line onto a running compositor. Nothing but libc: it carries no
# verb table of its own, quoting its arguments into one command that the
# compositor resolves, so it never has to be rebuilt when a verb is added.
executable(
  'kiln-client',
  ['kiln-client.c'],
  install: true,
)

# Completions as data, in the directories the three shells already look in, so
# they are edited by someone who writes shell rather than someone who writes C
# string literals. Each one asks the running compositor for its verbs, so a
# completion never goes stale against the build it is completing for.
datadir = get_option('prefix') / get_option('datadir')
install_data(
  'completions/kiln-client.bash',
  rename: 'kiln-client',
  install_dir: datadir / 'bash-completion/completions',
)
install_data('completions/_kiln-client', install_dir: datadir / 'zsh/site-functions')
install_data(
  'completions/kiln-client.fish',
  install_dir: datadir / 'fish/vendor_completions.d',
)

# Session entry, so display managers list kiln at the login screen.
install_data('kiln.desktop', install_dir: datadir / 'wayland-sessions')

# A Wayland client that drives xdg-activation on demand, so the activation
# battery can prove C's seat->valid derivation with a real round trip instead
# of restating the fact it means to test. Ungated: it needs only
# wayland-client and the generated protocol glue.
executable(
  'wl-activate',
  ['scripts/wl-activate.c',
   xdg_shell_client_h, xdg_shell_client_c,
   xdg_activation_client_h, xdg_activation_client_c],
  dependencies: [wayland_client],
  install: false,
)

# A Wayland client that drives wlr-foreign-toplevel-management on demand, so the
# foreign-toplevel battery can prove kiln advertises one handle per mapped
# client and that a taskbar's minimize/activate round-trips through the existing
# request events, instead of restating those facts. Ungated like wl-activate.
executable(
  'wl-toplevel',
  ['scripts/wl-toplevel.c',
   xdg_shell_client_h, xdg_shell_client_c,
   foreign_toplevel_client_h, foreign_toplevel_client_c],
  dependencies: [wayland_client],
  install: false,
)

# A Wayland client that starts a real DnD drag on the first pointer button, so
# the DnD battery can observe drag::start/drag::end from an actual grab instead
# of restating them. The data-device is in core wayland.xml, so only xdg-shell
# glue is generated. Ungated like the others.
executable(
  'wl-drag',
  ['scripts/wl-drag.c',
   xdg_shell_client_h, xdg_shell_client_c],
  dependencies: [wayland_client],
  install: false,
)

# A Wayland client that maps a toplevel and reports the fractional scale kiln
# hands it: with the manager wired, a surface on a 1.5x output must receive
# a preferred_scale of 180 (1.5 in 120ths). Ungated like the others.
executable(
  'wl-fractional',
  ['scripts/wl-fractional.c',
   xdg_shell_client_h, xdg_shell_client_c,
   fractional_scale_client_h, fractional_scale_client_c,
   viewporter_client_h, viewporter_client_c],
  dependencies: [wayland_client],
  install: false,
)

# A Wayland client that maps a toplevel and holds idle off with an idle-inhibitor,
# so the idle battery can observe idle::inhibit flip on a real inhibitor
# instead of restating it. Ungated like the others.
executable(
  'wl-inhibit',
  ['scripts/wl-inhibit.c',
   xdg_shell_client_h, xdg_shell_client_c,
   idle_inhibit_client_h, idle_inhibit_client_c],
  dependencies: [wayland_client],
  install: false,
)

# Test fixtures, never installed. An X11 window-state sender, so the
# request-family batteries drive real client asks instead of restating them.
if xwayland_enabled
  executable(
    'x11-state',
    'scripts/x11-state.c',
    dependencies: [dependency('xcb'), dependency('xcb-icccm')],
    install: false,
  )
  # A game's pointer grab, in the smallest client that makes one.
  executable(
    'x11-lock',
    'scripts/x11-lock.c',
    dependencies: [dependency('xcb')],
    install: false,
  )
  # The cursor image the outer X server holds: the raster kiln chose, at the
  # size it chose it, which is the sharpness half of the cursor battery.
  executable(
    'x11-cursor',
    'scripts/x11-cursor.c',
    dependencies: [dependency('xcb'), dependency('xcb-xfixes')],
    install: false,
  )
  # A client declaring _NET_WM_ICON at two sizes and a WM_WINDOW_ROLE, the two
  # facts the icon battery reads. No app on the box sets both on demand.
  executable(
    'x11-icon',
    'scripts/x11-icon.c',
    dependencies: [dependency('xcb')],
    install: false,
  )
endif

# The runtime: the default config and the Lua library it requires. The
# compositor appends the datadir's lua/ subtree to package.path, so the
# installed tree resolves require("kiln") with no loader file beside it.
#
# kilnrc.lua installs AS rc.lua: the source tree names the config after the
# compositor so it reads as this project's own, and the installed name is the
# one a user copies to ~/.config/kiln/rc.lua and edits.
install_data('kilnrc.lua', rename: 'rc.lua', install_dir: kiln_datadir)
install_subdir('lua', install_dir: kiln_datadir)
