# One build system: xmake

Everything builds, checks, benches and installs through xmake. Hyprland plugins (`kind = "hypr"`) keep their Makefiles. Runtime scripts that run in a guest, at login or from the UI stay shell. No Python left in the repo.

## Goals

- Plain `/usr/bin/xmake`, no wrapper in `~/.local/bin`.
- One `xmake.lua` per area; the root only `includes(...)` them and holds global options.
- Build-time scripts are xmake Lua tasks and tests next to the code they cover.
- `xmake install` puts every runtime piece in place, `yudae` included.
- Requirements: xmake, zig, make (hypr plugins), qemu (vm). No python, no node.

## Layout

```
xmake.lua              includes, options (debug, small, llvm, headless)
daemon/xmake.lua       yudaemond, yudaemond-headless, files provider, zig tests, index, cover tool
shell/xmake.lua        qml checks (color, ui, app), js checks, includes shell/native
shell/native/xmake.lua unchanged
plugins/xmake.lua      plugin-check, builds non-hypr plugins, runs make for hypr plugins
templates/             each non-hypr template ships an xmake.lua instead of a Makefile
vm/xmake.lua           vm task, doctor, bench-images
```

## Moves

| now | becomes |
| --- | --- |
| `scripts/xmake` | deleted, real xmake |
| `scripts/tasks.sh` | `task()`s in the area files: link, lint, bench, vm, doctor |
| `scripts/yubuild` | `daemon/xmake.lua` target, build timing and cache prune in `after_build` |
| `scripts/yudae` | deleted; `xmake install` links `~/.local/bin/yudae` to the binary |
| `scripts/yudae-fsd-install` | `xmake install fsd` (root, asks first) |
| `scripts/color-check`, `scripts/ui-check` | Lua tests in `shell/xmake.lua` |
| `scripts/app-check` | Lua test in `shell/xmake.lua` |
| `scripts/plugin-check` | Lua test in `plugins/xmake.lua` (xmake reads TOML) |
| `scripts/bench` | `xmake bench` in Lua |
| `scripts/theme-cover` | Zig tool target in `daemon/xmake.lua` (numpy and PIL gone) |
| `daemon/tools/build-index.py` | Zig tool target, run in `before_build` |
| python call in `providers/vms.zig` | Zig |
| `daemon/build.zig`, `daemon/src/providers/files/build.zig` | deleted |
| `shell/**/*.check.js` | Lua ports of the JS logic, or run the JS in Quickshell's engine; node gone |
| `vm/doctor`, `vm/bench-images` | Lua in `vm/xmake.lua` |
| `shell/scripts/greeter-install`, `greeter-uninstall` | `xmake install greeter`, `xmake uninstall greeter` |
| theme, app, shell, daemon plugin Makefiles | per-plugin `xmake.lua`; hypr plugins keep `make` |
| `.github/workflows/check.yml` | `xmake && xmake test` |

## Stays shell

Run outside the repo toolchain, so they keep zero dependencies:

- `vm/desktop`, `vm/desktop-sync`, `vm/shell`, `vm/audio-bridge`: run in the guest or spawned by the daemon
- `shell/features/greeter/session`, `shell/features/greeter/start`: run by greetd
- `shell/scripts/lock`: run from the power menu

## Daemon changes

- Every `{repo}/scripts/yudae` spawn (`launcher.zig`, `config.zig`, `disk.zig`, `mcp.zig`) re-runs itself via `/proc/self/exe`.
- `zig-out/bin` becomes xmake's output dir; the systemd unit runs the installed path.

## Order

1. Root and area `xmake.lua`; daemon builds and tests through xmake; `build.zig` deleted.
2. `xmake install` with the `yudae` link and self-exec in the daemon; `scripts/yudae` deleted.
3. Checks to Lua: color, ui, plugin, app, then js.
4. Tasks to Lua: link, lint, bench, vm, doctor, bench-images; wrapper and `tasks.sh` deleted.
5. Zig tools: index, theme-cover, vms python call. Python gone.
6. Non-hypr plugins and templates on xmake; greeter and fsd install targets.
7. CI, systemd unit, docs (`architecture.md`, `daemon.md`, `agent-tooling.md`, `plugins.md`, `perf.md`, `vm-nvidia.md`), skills, AGENTS.md repo map.

Each step: `xmake`, `xmake test` green, daemon runs and the shell loads in the agent's VM.
