# Plugins

One standard to make, load and share anything that modifies the system: Hyprland plugins, themes, shell features and app configs. A theme is a plugin.

## A plugin is a folder

```
plugins/<id>/
  plugin.toml
  Makefile
  src/ ...
  hypr.lua        hypr only
  theme.toml      theme source, rendered by make
```

`templates/_template-hypr/`, `_template-theme/`, `_template-shell/`, `_template-app/`, `_template-daemon/` and `_template-transition/` are working examples. Copy one into `plugins/<id>` and rename every `_template-*` name.

### Manifest

```toml
id = "drop-preview"
kind = "hypr"
version = "1.0.0"
build = "make"
provides = ["drop-preview.so"]

[requires]
hyprland = ">=0.50"
```

| key | rule |
| --- | --- |
| `id` | folder name, `^_?[a-z][a-z0-9-]*$`; a leading `_` marks a template |
| `kind` | `hypr`, `theme`, `shell`, `app`, `daemon` or `transition` |
| `version` | free string |
| `requires` | optional; only `hyprland`, with `>=`, `<=`, `>`, `<` or `=` and a dotted version |
| `build` | command run in the folder with `OUT` in the environment; `make` sees `OUT=<dir>` |
| `provides` | relative paths the build must write under `OUT`; no `..`, no absolute paths |

Unknown keys are rejected so a typo never turns into a silently ignored field.

### Source only

No `.so`, `.bin`, `.o`, `.a`, `.dylib`, `.dll`, `.exe` and no ELF file may exist inside a plugin folder. The conformance suite and the loader reject them, so every Hyprland update can rebuild from source. Built files live in `$XDG_STATE_HOME/yudae/build/<id>/`.

Lua, scripts, QML and assets are allowed. Security is the user's call.

## Load list

`$XDG_STATE_HOME/yudae/plugins.toml`, never shipped. `YUDAE_PLUGINS` overrides the path for tests and VMs. A missing file means no plugins and the built-in defaults.

```toml
load = ["tokyo", "borders-plus-plus", "drop-preview"]

[tokyo]
accent = "#7aa2f7"
```

- Order matters; later plugins override earlier ones (theme colors in particular).
- A `[id]` table becomes `YUDAE_PLUGIN.options` in `hypr.lua`.
- A plugin not in `load` is never touched.

Source folders are found in the repo `plugins/` first, then `$XDG_DATA_HOME/yudae/plugins/` for `plugin add`.

## Kinds

One adapter per kind in yudaemond. Plugins never touch the loader.

### hypr

- `provides` has the `.so` or `.bin`. `hypr.lua` contains config only.
- yudaemond writes `$XDG_STATE_HOME/yudae/loaded.lua`; `hypr/hyprland.lua` `dofile`s it after the normal config. The generated file loads each current binary, sets `YUDAE_PLUGIN` (`id`, `dir`, `out`, `options`) and inlines the plugin's `hypr.lua`.
- At daemon start the loader reads `pkg-config --modversion hyprland`. The stamp holds that version and a hash of every source file. A changed version or source rebuilds; `loaded.lua` never compiles.
- After every reload the daemon writes `$XDG_STATE_HOME/yudae/plugins.ready` with the version it built for. `hypr/hyprland.lua` loads `loaded.lua` only when that equals `hl.version()`, so a list built for another Hyprland is skipped instead of popping a failed-load notification.
- `yudae-plugins.path` watches `/usr/share/pkgconfig/hyprland.pc`. A package update rebuilds the plugins during the running session, so the next login loads them directly; the daemon only live-loads when `hyprctl version` matches the headers it built against.
- After a live load the daemon reloads the Hyprland config once so the plugin's `hypr.lua` options apply.
- A failed build skips only that plugin, posts a notification with the compiler output, and keeps the desktop running.

### theme

- `provides` has `theme.toml`. It may use the same sections as the files under `shell/config/` (`[colors]`, `[weather]`, `[calendar]`, ...), so a key replaces the base value in its own section. Color keys must be color settings from `shell/services/Config.qml`; values are `#rrggbb` or `#aarrggbb`. Boolean switches are allowed too. Set `surfaceRaised`, `surfaceHover` and `rule` in `[colors]`: every app, card, row and menu draws from them.
- A theme may carry `wallpaper.jpg|png` (the full-res image applied with the look) and `cover.jpg` (that wallpaper cropped to 16:9 with the top bar drawn in the theme's palette). The picker's look row shows the cover, and the strip previews the wallpaper full screen before applying. `xmake build theme-cover` then `daemon/zig-out/bin/theme-cover [id...] [--force]` generates `cover.png` from the theme palette when a theme has no cover yet.
- yudaemond merges themes in load order into `$XDG_STATE_HOME/yudae/theme.toml`.
- `providers/config.zig` reads that file after the base files in `shell/config/`, so `Yudae.settings` retints live without a shell restart.

### shell

- `provides` includes the QML entry. The first `.qml` in `provides` is the entry.
- yudaemond exposes every loaded shell plugin in the `plugins` snapshot with a `file://` entry URL.
- `shell/PluginHost.qml` instantiates each entry. The entry is a Quickshell surface (`PanelWindow`), not a plain item.
- The suite lints every `.qml` in the folder with `qmllint`.

### app

- `build` renders the template into `$XDG_STATE_HOME/yudae/build/<id>/`; every `provides` path must exist afterwards.
- Nothing is installed into `~/.config`; the app reads the rendered file from the state dir.

Example: `plugins/foot/theme.ini` renders to `~/.local/state/yudae/build/foot/theme.ini`.

### daemon

A compile-time provider. The loader still validates and builds its manifest, but the provider list in yudaemond decides what runs.

### transition

A wallpaper transition drawn by yudaemond. No build: the shader is an asset.

```
plugins/<id>/
  plugin.toml
  transition.frag
```

```toml
id = "wipe"
kind = "transition"
version = "1.0.0"
duration = 700              # ms, 1..10000
easing = [0.65, 0, 0.35, 1] # cubic-bezier, default [0.25, 0.1, 0.25, 1]
ink_at = 0.5                # eased progress where the bar ink flips, default 0.5
```

- `build`, `provides` and `requires` are rejected for this kind.
- `transition.frag` is a GLSL ES 3.00 body. The daemon prepends `#version 300 es`, `precision highp float` and `#line 1`, and declares `uniform sampler2D old, new`, `uniform float progress, time`, `uniform vec2 resolution`, `in vec2 uv` (top-left origin) and `out vec4 color`. The plugin writes `void main()`.
- `old` and `new` are already cover-scaled to the output, so sample them at `uv`.
- Each number in the plugin's `[id]` table of the load list is set as `uniform float <name>`; declare the ones you read.
- Pick one with `wallpaper.apply {path, transition: "<id>"}` or the `wallpaperTransition` setting. `none` and `fade` are built in; `fade` lasts `wallpaperTransitionMs`.
- `yudae transition check <file>` compiles the shader on the real driver; `xmake test plugin-check/plugins` runs it.

## Commands

```
yudae plugin list
yudae plugin build <id>
yudae plugin load <id>
yudae plugin unload <id>
yudae plugin theme <id>
yudae plugin add <git-url>
yudae plugin update <id>
yudae plugin reload
```

- `load` and `unload` edit the TOML and reload immediately.
- `theme <id>` loads one theme and unloads every other theme in one step; the wallpaper picker's theme row calls it. The `plugins` snapshot lists every installed theme under `themes` with its `active` flag and preview colors.
- `build` forces one build, then reloads the generated Lua and live-loads Hyprland plugins.
- `add` clones into `$XDG_DATA_HOME/yudae/plugins/<manifest id>`, records the commit in `$XDG_STATE_HOME/yudae/commits/<id>`, adds it to `load` and reloads. It prints kind, version, commit and path.
- `update` pulls an installed plugin, records the commit and reloads. Repository plugins are not pulled.
- `reload` re-reads the list, rebuilds stale plugins, rewrites `loaded.lua`, merges themes and applies shell/app plugins.
- `xmake plugin` rebuilds every repository plugin's Makefile into `$XDG_STATE_HOME/yudae/build/<id>`; it does not touch the load list.

## Tests

- The `plugin-check` test (`xmake test plugin-check/plugins`) discovers every folder under `plugins/` and `templates/`, validates the manifest, rejects binaries, runs `make`, checks `provides`, lints shell QML, parses theme colors and builds app templates. Hypr plugins are skipped when `pkg-config hyprland` is missing.
- Zig unit tests cover the load list, missing folder, broken TOML, unknown kind, duplicate id, requires mismatch, order, options, unload, source hash, theme layering and a real Hyprland template build.
- VM scenarios `vm/scenarios/plugin-*.json` cover no list, load, unload, stale source, broken source, binary in folder, missing compiler, themes, theme layering, Lua themes, shell, app and Hyprland.

Golden images can be pinned to an Arch Linux Archive date:

```
xmake vm packages --snapshot 2026/10/28
xmake vm golden --snapshot 2026/10/28
yudae vm create old --from 2026-10-28
```

`--from` accepts a VM name (clone its disk) or a golden tag built by `vm/images`.
