# Architecture

TLDR: one repo, split by what a thing is. xmake is the single entry point. `vm` runs disposable KVM machines for real-session tests. One IPC door for commands.

## Layout

```
dotfiles/
  config/            plain app configs, one dir per app, each symlinked to ~/.config/<name>
  plugins/           source-only plugins: hypr, theme, shell, app; see docs/plugins.md
  hypr/              hyprland conf; the one non-config symlinked, hyprland reads ~/.config/hypr
  shell/             quickshell, run with `quickshell -p`, never symlinked
    features/<name>/ one folder per feature: Card.qml Widget.qml Service.qml feature.json
    ui/              primitives used twice or more; AppWindow is the xdg_toplevel primitive
    native/          Yudae.Native C++ QML module (VmDisplay) + yudae-pump
    lib/ lock/ launcher/ greeter/
    config/          one TOML per settings category; icons.toml holds every glyph
  daemon/            yudaemond (Zig); src/providers/<name>.zig pairs with features/<name>
  systemd/ scripts/
  vm/                images, overlays, guest setup, scenarios
  docs/              reference: how the system is shaped
  .agents/skills/    task guides: how to do X
  xmake.lua + one xmake.lua per dir
  plans.md AGENTS.md README.md
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

## xmake

xmake orchestrates, it does not replace the real builders.

| task | does |
| --- | --- |
| `xmake build` | daemon (wraps `zig build`), cursor plugin, `Yudae.Native` QML module, `yudae-pump` (native C++ targets) |
| `xmake plugin` | rebuild every `plugins/*/Makefile` into `~/.local/state/yudae/build/<id>` |
| `xmake link` | symlink `config/*` and `hypr/` into `~/.config` |
| `xmake lint` | qmllint on `shell/`, `node shell/lib/check.js` |
| `xmake test` | daemon parsers/protocol tests, plugin conformance, qml fixtures, idle-spawn test |
| `xmake bench` | headless daemon cold build, size, start, idle RSS and spawns, then `yudaemond bench` against `bench/baseline.json` |
| `xmake vm ...` | VM images and the image build bench; running VMs are `yudae vm` |
| `xmake doctor` | what is missing and why |

`zig build` stays underneath: the build budgets are measured on it and `scripts/yubuild` reports them. `zig build -Dheadless=true` builds `yudaemond-headless`, the minimal control-plane daemon that carries the performance gates.

`scripts/xmake` is linked to `~/.local/bin/xmake`. Inside the repo it dispatches `build`, `plugin`, `link`, `lint`, `bench`, `hypr`, `vm` and `doctor` to `scripts/tasks.sh`; every other xmake command goes to the system xmake. `shell/native` builds the Quickshell app window and the VM display, including the in-process Conduit broker client; the daemon runs `qemu-system-x86_64` from `PATH`, or the NVIDIA path (`~/qemu-linux/install`, Conduit) when `backend=auto` selects it. `YUDAE_QEMU` and `YUDAE_NVIDIA_QEMU` override both.
