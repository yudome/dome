# Architecture

TLDR: one repo, split by what a thing is. xmake is the single entry point. `vm` runs disposable KVM machines for real-session tests. One IPC door for commands.

## Layout

```
dotfiles/
  config/            plain app configs, one dir per app, each symlinked to ~/.config/<name>
  plugins/           source-only plugins: hypr, theme, shell, app, zsh; see docs/plugins.md
  hypr/              hyprland conf; the one non-config symlinked, hyprland reads ~/.config/hypr
  shell/             quickshell, run with `quickshell -p`, never symlinked
    features/<name>/ one folder per feature: App.qml Store.qml widget, panel, feature.json
    ui/              generic primitives: icons, text, controls, rows, overlays, data visuals, scroll
    appkit/          app chrome: AppWindow, AppScaffold, AppHeader, AppSidebar, AppPage, Metrics, Motion
    panelkit/        widget popup chrome: PanelPage, PanelHeader, PanelRow, PanelFooter, ProcessPanel
    app-<name>.qml   one entry per app (vms, disk, gallery); `yudae app open <name>` runs it
    native/          Yudae.Native C++ QML module (VmDisplay, WallVideo) + yudae-pump
    lockscreen ->    symlink to ../lockscreen so its QML resolves `qs`
    config/          one TOML per settings category; icons.toml holds every glyph
  lockscreen/        the lock screen and the greeter: one Surface, PAM or greetd auth, video backdrop, greeter Hyprland config
  daemon/            yudaemond (Zig); src/providers/<name>.zig pairs with features/<name>
  systemd/           user units and the root fsd helper units
  vm/                mkosi/ guest image, images (overlays), net (per-VM netns), scenarios; xmake vm, bench and doctor
  docs/              reference: how the system is shaped
  .agents/skills/    task guides: how to do X
  xmake.lua + one xmake.lua per dir
  xmake/             xmake Lua modules: checks, tasks, util
  PLANS.md AGENTS.md README.md
```

## Rules

- A feature has one name. `features/weather/` on the QML side, `providers/weather.zig` on the daemon side. Add or delete both together.
- `config/` has no code. Anything with logic leaves it.
- `AGENTS.md` is an index. Procedure goes in `.agents/skills/`, reference in `docs/`.
- Only `xmake link` writes into `~/.config`. It refuses to overwrite a real file and prints what it would replace.
- The shell and greeter run from the repo path, never from `~/.config`.
- The lock lives in the main shell process: `lockscreen/Lock.qml` holds a fresh `WlSessionLock` per lock. It locks on idle (`lockAfterMinutes`), on the power menu's Lock (`yudaemond lock`), on logind `Lock` and before sleep, and again after a shell or daemon crash in the same Hyprland session (Hyprland's `allow_session_lock_restore`). The daemon's `lockscreen` provider owns the state: it publishes `locked` and the profile, keeps the `yudae-locked-<instance>` flag in `$XDG_RUNTIME_DIR`, and takes `lock`, `unlock` and `power` (`suspend`, `reboot`, `poweroff` only) commands. There is no lock script and no lock shortcut.
- Boot logs straight in: greetd's `initial_session` starts Hyprland as the user with `YUDAE_LOCK_AT_START=1`, and the shell locks once on its first start in that Hyprland, before it even reaches the daemon (a `yudae-started-<instance>` marker in `$XDG_RUNTIME_DIR` keeps reloads from locking again). Unlocking is the login, so there is no second compositor and no black screen. The greeter only shows after a logout.
- The greeter is `shell/greeter.qml`, run by greetd inside a minimal Hyprland (`lockscreen/hypr/greeter.lua`) and installed with `sudo xmake install greeter` from the repo it should run from. It draws the same `lockscreen/Surface.qml` as the lock plus a user cell next to the power cells; it swaps the card for a menu with a back arrow, the user row and the session row. Tab steps the session, Up and Down the user, Escape closes the menu. Users (`/etc/passwd`) and sessions (`/usr/share/wayland-sessions`) come from the profile the daemon writes; the chosen one starts through `lockscreen/session`, which sends its output to `~/.local/state/session.log`.
- Lock and greeter play their wallpaper on every show: a video plays and settles on its still frame through `Yudae.Native.WallVideo`, which shares the daemon's decoder and settle curve (`daemon/src/c/video.c`, `settle.c`). `lockWallpaper` and `greeterWallpaper` pick `desktop`, `lock` or a path. The daemon writes the choice, the still pick, preview frames and a greeter-readable copy of the media to `shell/cache/lockscreen/<machine-id>/profile.json`, or `/var/tmp/yudae-lockscreen/<machine-id>/` when the repo is read-only (a VM).
- After `lockIdleSeconds` without input only the wallpaper shows; moving the mouse or a key brings the controls back. An idle lock starts that way.
- `xmake lockscreen` opens the preview app (`shell/app-lockscreen.qml`): lock or greeter, mock auth, wrong password, idle. `yudae vm scenario <vm> greeter-lock` runs the real lock and greeter in a VM.

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
| `xmake lint` | qmllint on `shell/` and `lockscreen/`, plus the color, kit, slider and face checks |
| `xmake lockscreen` | the lock screen preview app |
| `xmake test` | daemon parsers/protocol tests, plugin conformance, QML lint, the kit and face checks, and every app plus the shell loaded in a headless cage |
| `xmake bench` | headless daemon cold build, size, start, idle RSS and spawns, then `yudaemond bench` against `bench/baseline.json` |
| `xmake vm ...` | VM images and the image build bench; running VMs are `yudae vm` |
| `xmake doctor` | host and VM checks, `--json` for machines |

`xmake` drives Zig directly for the daemon, the launcher index and the cover tool, and the system `make` for hypr plugins. The build time, binary size and cache size go to `.bench/build.jsonl` in `after_build`, and the daemon cache is pruned over `YUDA_BUILD_CACHE_MB` (300). `xmake f --headless=y` builds `yudaemond-headless`, the minimal control-plane daemon that carries the performance gates.

There is no wrapper: `/usr/bin/xmake` runs the real thing. `shell/native` builds the Quickshell app window and the VM display, including the in-process Conduit broker client; the daemon runs `qemu-system-x86_64` from `PATH`, or the NVIDIA path (`~/qemu-linux/install`, Conduit) when `backend=auto` selects it. `YUDAE_QEMU` and `YUDAE_NVIDIA_QEMU` override both.
