# Plans

## Settings app

A macOS-style settings app for everything in `shell/config.toml` and `shell/topbarlayout.json`, with visual previews. Edits stay pending until Apply; Apply writes the real files and the host updates live through the existing watchers.

### Rules

- Apply writes straight into `shell/config.toml`: edit the one line of the key, keep comments and order. No overlay file.
- Every color from `Config.qml`, glyphs from the icon list, one glyph for the app, its launcher entry and its window. No key hints on screen.

### Daemon

- `settings.set {key, value}`: rewrite the key's line in `config.toml`, type checked against the current value. The config watcher republishes.
- `bar.layout {layout}`: atomic write of `topbarlayout.json`, validated by the existing `normalize`.
- `settings.app`: open the app, same as vms and disk (`setsid script app open settings`).
- Zig test per verb, CLI and MCP verbs, `docs/daemon.md`.

### App

`shell/app-settings.qml`, AppId `com.yudae.settings`, `features/settings/App.qml` on `AppWindow`. Sidebar of categories on the left, pane on the right.

| Category | Sections |
|---|---|
| Appearance | colors, shell |
| Top bar | bar, tray, layout editor |
| Display | the DisplayPanel controls |
| Wallpaper | wallpaper |
| Panels | popup, tooltip, notify, calendar, launcher, windows |
| Widgets | cpu, memory, mixer, media, network, weather, contrib, agent, disk |
| Lock and power | lock, power |

Controls from the value type: bool switch, number `StepBar`, color well, enum `Selector`. Fine tuning numbers under a collapsed Advanced group.

### Preview

- Simulated, never the live bar: a static strip drawn in the app, no widget components, no daemon data.
- Each widget is its glyph from the icon list, drawn with the pending colors, icon size, spacing, padding and thickness; text widgets show fixed sample text.
- Under the strip, only the chunk of the current wallpaper that sits under that part of the bar on the real monitor.
- Picker for which part to show: left, center, right. Redraws on every pending change; the real bar changes only on Apply.
- Same card on top of the Top bar and Appearance panes.

### Top bar editor

- Three slots, left, center, right, with chips from `topbarlayout.json`.
- A widget not in the layout does not exist on the bar; no hidden state.
- A library list of every feature with a bar widget, read from `features/*/feature.json`: glyph, name, one-line description (new `"description"` field in each `feature.json`).
- Drag from the library into a slot to add, drag a chip back to the library to remove, drag between slots to move or reorder.
- Apply writes the layout through `bar.layout`.

### Display

The display widget leaves the bar: drop `display` from the layout, move the `DisplayPanel` content into the Display pane, delete `DisplayStat`.

### Order of work

1. Daemon verbs and tests.
2. App skeleton, sidebar, launcher entry.
3. Generic panes from config types.
4. Display move.
5. Simulated bar preview.
6. Top bar editor and library.
7. Docs.
8. Verify on a VM, `xmake lint`, `xmake test`.

Settled: Apply writes `config.toml` directly; preview is simulated with a wallpaper chunk; widgets off the bar are absent, added back from the described library; display lives only in settings.

## Appkit and shared UI standard

Moved to `plans/appkit.md`. That file owns the app, widget and panel UI architecture, component catalog, rules, lint enforcement and migration order.
