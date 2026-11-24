# Design system

TLDR: monochrome, dense, glyph-driven. Every value is a token in `shell/services/Config.qml`, editable through `shell/config/*.toml`. Every visual is composed from `shell/ui`, `shell/appkit` and `shell/panelkit`. No literals, no hand-built chrome, hints only through `Hint`. `xmake lint` enforces it.

## Principles

- Hints only through `Hint` (key + short label, text from `Config`, all hidden by `hints = false`); no counters.
- Mono first: `mono = true` swaps every hue for the mono ink; color is opt-in per token (`cpuBase` / `cpuBaseMono`). Apps have no accent hue: selection is ink on `surfaceRaised`.
- One thing, one glyph, everywhere.
- Text never overlaps: bounded width, anchored to neighbours, elided.
- No "·" separators; spacing separates.
- Scrollbars on the container's right border, never smoothed.

## Layers

| Layer | Path | Owns |
|---|---|---|
| Tokens | `shell/services/Config.qml` | every color, size, duration and glyph |
| Generic primitives | `shell/ui/` | icons, text, controls, rows, overlays, data visuals, scroll mechanics |
| App composition | `shell/appkit/` | window frame, header, scaffold, sidebar, split, page, sections, app states, `Metrics`, `Motion`, `AppPalette` |
| Panel composition | `shell/panelkit/` | popup page, header, rows, footer, process panel |
| Features | `shell/features/<name>/` | `Store.qml` state and daemon calls, product content, one-off visuals |

`ui` imports nothing from `appkit`, `panelkit` or features. `appkit` and `panelkit` import `ui`. Features import all three. Kits never call `Yudae`.

## Tokens

Source: `Config.qml`. Each token reads `settings.<name>` with a built-in default. `settings` is the daemon's live snapshot (`Yudae.settings`), else `shell/cache/settings.json`, plus a preview `overlay` used by the settings app and the gallery.

Files: one TOML per category in `shell/config/`: `appearance`, `display`, `general`, `icons`, `launcher`, `notifications`, `power`, `wallpaper`, `widgets`.

### Color

| Token | Default | Role (`AppPalette`) | Use |
|---|---|---|---|
| `surface` | `#101010` | `surface` | window, page and sidebar background |
| `surfaceRaised` | `#1c1c1c` | `raised` | cards, sidebar selection, search box |
| `surfaceHover` | `#262626` | `hover` | row hover, control fill on cards |
| `rule` | `#222222` | `rule` | separators, borders |
| `foreground` | `#ffffff` | `ink` | ink |
| `muted` | `#ffffff` | `inkMuted` | secondary ink, captions |
| `dim` | `#3f3f3f` | `inkDim` | tracks, idle scrollbar, disabled |
| `red` / `yellow` | `#e05252` / `#e0b24f` | `danger` / `warning` | destructive, pending |
| `surfaceTranslucent` | `#ff101010` | | bar background, alpha first |
| `mono` | `true` | | use `*Mono` variants instead of hues |

Chrome colors exist once: every search box, card and calendar box is `surfaceRaised`, every hover and highlight `surfaceHover`, every separator `rule`, every track `dim`. Feature colors are data only (`cpuBase`, `memoryFree`, `contribEmpty`, ...) and stay in their feature; the kits never read them. Every theme in `plugins/*/theme.toml` sets `surfaceRaised`, `surfaceHover` and `rule`, so apps follow the theme. `xmake lint` runs `scripts/color-check`, which rejects color literals in QML; `scripts/ui-check` rejects any `Config.x` that does not exist.

### Type

`fontFamily` (GoogleSansCode), `fontSize` body, `appTitleSize` title, `appHeadingSize` section heading, `appCaptionSize` caption, `iconSize`. `valueSample` sizes numeric bar slots; `Label { role: "value" }` uses tabular figures so values never jitter.

### Space and shape

App geometry (`[app]` in `appearance.toml`): `appHeaderHeight` 56, `appRowHeight` 48, `appSidebarWidth` 220, `appSidebarWideWidth` 260, `appSidebarMin`/`appSidebarMax`, `appPadding` 32, `appPaddingCompact` 16, `appPaddingWide` 48, `appColumn` 900, `appGap` 16, `appSectionGap` 40, `appRadius` 12, `appControlRadius` 8, `appControlWidth` 272, `appChipHeight` 30, `appCompactWidth` 640, `appWideWidth` 1200, window presets `appSmall*` 720x480, `appMedium*` 960x640, `appLarge*` 1200x800, floor `appFloor*` 480x360, `appScrim`, `disabledOpacity`.

Shared: `spacing` 12, `gapsIn` 4, `gapsOut` 8, `rowHeight`, `rowInset`, `panelPadding` 12 (every bar popup), `popupBorderWidth` 1, `scrollbarWidth` 2, `scrollbarHoverWidth` 6, `scrollbarMinThumb` 12. Bar: `barInset`, `barPadding`, `barStatSpacing`.

### Motion

Every duration ends in `Ms`: `popupFadeMs` 140, `popupSlideMs` 400, `toggleMs` 160, `windowStepMs`, `scrollbarFadeMs` 200, `scrollbarIdleMs` 900, `tooltipDelayMs` 600, `confirmMs` 5000, `barFadeMs`, `barSlideMs`, `workspaceMorphMs`, `agentMorphMs`, `stepBarMs`. No local durations; `scripts/ui-check` rejects radius and duration literals.

### Icons

Every glyph is `iconX` in `config/icons.toml`, mirrored as `Config.iconX`, plus the `icons` name map (`Config.glyph(name)`). Look up before adding; never a second glyph for the same thing. The VM app, its machines and its launcher entry share `vm`; Disk uses `disk`, Settings `settings`. Glyphs are drawn through `Icon` (any slot) or `Glyph` (font glyph content), never a bare `Text`.

## Components

### `shell/ui`

| Area | Components | Notes |
|---|---|---|
| Icons | `Icon`, `IconBar`, `IconButton`, `Glyph`, `DynamicIcon` | `Icon` is the square slot: `name`, `glyph`, `source` image, or child content. `Glyph` centers glyph ink. `IconButton` owns hover, selected, disabled, reveal, tooltip, focus and keyboard. |
| Text | `Label`, `BarText` | Roles `title`, `heading`, `body`, `caption`, `value`; `capOffset` centers by cap height. A feature may set a size token on a `Label`; raw `Text` with its own font is for data visuals only. `BarText` is bar-only. `Label` and `Glyph` expose `inkTop`, `inkBottom` and `inkBelow`; `InkLine` mirrors an ink edge of either into a zero-size sibling line that anchors can target (keep it in a plain container, not a positioner). |
| Buttons | `Button`, `Chip` | Kinds `primary`, `secondary`, `ghost`, `danger`; `busy`; `confirm` arms in danger, a second activation runs. Takes an `AppAction`. |
| Inputs | `TextField`, `SearchField`, `Switch`, `PillSwitch`, `Select`, `ColorField`, `FocusRing`, `InlineEdit` | `PillSwitch` is the segmented control; `Select` is a dropdown over `MenuList`; `InlineEdit` is the text backend. |
| Slider | `Slider`, `SliderTrack`, `GlyphScale`, `StepBar` | `Slider` owns value, stops, steps, drag, wheel, keys; renderers are visual only and get `value`, `normalized`, `dragging`, `hovered`, `orientation`, `stops`. |
| Rows | `ListRow`, `FormRow`, `Selector`, `StepList`, `IconRow`, `NotificationRow` | `ListRow`: leading, content, trailing slots. `FormRow`: label, note, pending dot, control slot. |
| Surfaces | `Card`, `Tooltip`, `Separator`, `Highlight`, `Drawer`, `HyprBorder`, `HyprShadow` | `Tooltip` is every popup. |
| Navigation | `NavItem`, `Tabs`, `Breadcrumb` | `Breadcrumb` separates with the `right` glyph. |
| Feedback | `Badge`, `ProgressBar`, `Braille`, `EmptyState`, `Hint` | Empty and error states are a glyph plus a short noun line, with an optional `Hint` under it. `Hint` is the only way to draw a shortcut or instruction; `ui-check` rejects hint text anywhere else. |
| Overlays | `MenuRow`, `MenuList`, `ContextMenu` | Menu entries with `confirm: true` arm first. |
| Scroll | `Scrollbar` | Low level: right border, no track, fades in on scroll or hover, draggable. Features use `AppScroll`. |
| Data visuals | `CellGrid`, `DotGraph`, `SignalBars`, `SpeedGauge`, `PowerFlow`, `DayDial`, `Figures` | Stay in `ui` or their feature, never in a kit. |
| Singletons | `Input`, `Handoff` | key map, focus handoff |

### `shell/appkit`

| Component | Job |
|---|---|
| `AppWindow` | the xdg_toplevel; `preset` small, medium, large; floor 480x360 |
| `AppScaffold` | sidebar, header, content, footer slots; `sizeClass` compact, regular, wide; compact turns the sidebar into a drawer |
| `AppSplit` | the only resizable sidebar split; collapses in compact |
| `AppHeader` | back, title, trailing slot, `actions` as buttons; compact folds them into a menu |
| `AppSidebar`, `AppNav` | sidebar with optional title and search; `NavItem` list |
| `AppPage`, `AppSection` | scrolling page with max column and responsive padding; heading plus card |
| `AppFooter` | message, actions, `AppTask` progress |
| `AppScroll` | the only feature scrollbar: own flickable, or `view:` attached to a list |
| `StateView` | loading (`Braille`), empty, error with retry, ready |
| `AppAction`, `AppTask` | shared command and progress state |
| `Metrics`, `Motion`, `AppPalette` | read-only names for `Config` tokens |

### `shell/panelkit`

`PanelPage` (padding, content width, `closeRequested`), `PanelHeader` (title, value, trailing slot), `PanelBand` (section title on a raised surface, bleeds to the panel edges), `PanelRow`, `PanelFooter`, `ProcessPanel` (header, detail, viz).

## Sizes

`Metrics.sizeClass(width)`: compact below `appCompactWidth`, wide above `appWideWidth`. Only layout changes with width, never text size. Apps are checked at 480, 720, 960 and 1280 in the gallery.

## Gallery

`quickshell -p shell/app-gallery.qml` opens `features/gallery`: every component and state, a mono switch and a size class switch. Use it for screenshots and as the reference when adding a component.

## Adding a component

1. Search `shell/ui`, `shell/appkit` and `shell/panelkit` first; reuse or extend.
2. One-off visuals stay in the feature. Second real use: move to the right kit, register it in its `qmldir`, delete the feature copy in the same change.
3. Tokens only: colors, sizes and durations from `Config`; a new token goes in its Config section and the matching TOML.
4. Logic-heavy primitives leave one `*.check.js` beside them; `xmake lint` and `xmake test` run every one.
5. Add it to the gallery. `xmake lint` and `scripts/app-check` clean.
