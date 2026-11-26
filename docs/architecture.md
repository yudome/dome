# Architecture

TLDR: one repo, split by what a thing is. xmake is the single entry point. `vm` runs disposable KVM machines for real-session tests. One IPC door for commands.

## Layout

```
dotfiles/
  config/            plain app configs, one dir per app, each symlinked to ~/.config/<name>
  plugins/           source-only plugins: hypr, theme, shell, app; see docs/plugins.md
  hypr/              hyprland conf; the one non-config symlinked, hyprland reads ~/.config/hypr
  shell/             quickshell, run with `quickshell -p`, never symlinked
    features/<name>/ one folder per feature: App.qml Store.qml widget, panel, feature.json
    ui/              generic primitives: icons, text, controls, rows, overlays, data visuals, scroll
    appkit/          app chrome: AppWindow, AppScaffold, AppHeader, AppSidebar, AppPage, Metrics, Motion
    panelkit/        widget popup chrome: PanelPage, PanelHeader, PanelRow, PanelFooter, ProcessPanel
    app-<name>.qml   one entry per app (settings, vms, disk, gallery); `yudae app open <name>` runs it
    native/          Yudae.Native C++ QML module (VmDisplay) + yudae-pump
    lib/ lock/ launcher/ greeter/
    config/          one TOML per settings category; icons.toml holds every glyph
  daemon/            yudaemond (Zig); src/providers/<name>.zig pairs with features/<name>
  systemd/           user units and the root fsd helper units
  vm/                mkosi/ guest image, images (overlays), net (per-VM netns), scenarios; xmake vm, bench and doctor
  docs/              reference: how the system is shaped
  .agents/skills/    task guides: how to do X
  xmake.lua + one xmake.lua per dir
  modules/           shared xmake Lua primitives: checks, tasks, util
  PLANS.md AGENTS.md README.md
```

## Rules

- A feature has one name. `features/weather/` on the QML side, `providers/weather.zig` on the daemon side. Add or delete both together.
- `config/` has no code. Anything with logic leaves it.
- `AGENTS.md` is an index. Procedure goes in `.agents/skills/`, reference in `docs/`.
- Only `xmake link` writes into `~/.config`. It refuses to overwrite a real file and prints what it would replace.
- The shell and greeter run from the repo path, never from `~/.config`.
- The greeter is `shell/greeterShell.qml`, run by greetd as `cage -- quickshell` through `shell/features/greeter/start`. It and the lock draw the same `features/lock/Stage.qml`: font, `lockFontSize`, `lockDigits`, `lockClockFormat` and colors come from `shell/config/`.
- The greeter starts the chosen session through `shell/features/greeter/session`, which sends its output to `~/.local/state/session.log`, so nothing is printed on the VT between the greeter and the desktop.
- The greeter's third button opens the switch menu: one row for the session name and one for the user, arrows to change each, and that choice is used for the login. Sessions come from `/usr/share/wayland-sessions`.

## UI layers

- `ui` imports nothing from `appkit`, `panelkit` or features. `appkit` and `panelkit` import `ui`. Features import all three. Never reverse.
- `ui`, `appkit` and `panelkit` never talk to the daemon (`Yudae`); state and daemon calls live in `features/<name>/Store.qml`, views compose the kits.
- Colors from `Config` (`AppPalette` in apps), sizes from `Config`/`Metrics`, durations from `Config`/`Motion`.
- The `shell-checks` test enforces this in `xmake test` and `xmake lint`; the full standard is `plans/appkit.md` and `docs/design-system.md`.

## xmake

xmake orchestrates, it does not replace the real builders.

| task | does |
| --- | --- |
| `xmake` | daemon, launcher index, `Yudae.Native` QML module, `yudae-pump` |
| `xmake install` | daemon into `~/.local/bin`, the `yudae` link, and the native pieces, then `yudae restart`; `xmake install fsd` and `xmake install greeter` ask for root first |
| `xmake plugin` | rebuild every `plugins/*/Makefile` into `~/.local/state/yudae/build/<id>`; hypr plugins keep `make` |
| `xmake link` | symlink `config/*`, `hypr/`, the user units and the icons into `$HOME` |
| `xmake lint` | qmllint on `shell/`, plus the color, kit, slider and face checks |
| `xmake test` | daemon parsers/protocol tests, plugin conformance, QML lint, the kit and face checks, and every app plus the shell loaded in a headless cage |
| `xmake bench` | headless daemon cold build, size, start, idle RSS and spawns, then `yudaemond bench` against `bench/baseline.json` |
| `xmake vm ...` | VM images and the image build bench; running VMs are `yudae vm` |
| `xmake doctor` | host and VM checks, `--json` for machines |

`xmake` drives Zig directly for the daemon, the launcher index and the cover tool, and the system `make` for hypr plugins. The build time, binary size and cache size go to `daemon/bench/build.jsonl` in `after_build`, and the daemon cache is pruned over `YUDA_BUILD_CACHE_MB` (300). `xmake f --headless=y` builds `yudaemond-headless`, the minimal control-plane daemon that carries the performance gates.

There is no wrapper: `/usr/bin/xmake` runs the real thing. `shell/native` builds the Quickshell app window and the VM display, including the in-process Conduit broker client; the daemon runs `qemu-system-x86_64` from `PATH`, or the NVIDIA path (`~/qemu-linux/install`, Conduit) when `backend=auto` selects it. `YUDAE_QEMU` and `YUDAE_NVIDIA_QEMU` override both.
