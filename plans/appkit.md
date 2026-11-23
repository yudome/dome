# Appkit and shared UI standard

One UI architecture for every app, widget and panel, in the design language of `docs/design-system.md`: monochrome, dense, glyph-driven. One toolkit, one window frame, one layout rhythm. Every value is a `Config` token editable through `shell/config/*.toml`. A feature composes the kit; it does not paint its own chrome.

This plan runs beside the Settings plan in `plans.md`. Settings is finished first, then inspected as the reference app before migration.

## Goal

- Every app uses the same window frame, header, sidebar, page, rows, buttons, inputs, scrollbars and states.
- Every widget uses the same bar slot, popup frame and controls.
- Colors, sizes and durations stay editable: `Config.qml` reads them from `shell/config/*.toml`.
- Geometry is fixed by the kit's tokens. No per-app header heights, row heights, radii or durations.
- A missing component is added to the kit once, not copied into a feature.
- Removing a component deletes the old version in the same change.

## Design language

The kit enforces `docs/design-system.md`; it adds nothing on top of it.

- Mono first. `mono = true` swaps every hue for mono ink. Color is opt-in per token (`x` / `xMono`).
- Glyph-driven. One thing, one glyph, everywhere, from `config/icons.toml`.
- Dense. One `fontFamily`, `fontSize` body, `valueSample` for numeric slots so values never jitter.
- Discovered by use. No "press X", key lists, hints, counters or placeholder instructions anywhere in the kit or the gallery.
- Text never overlaps: bounded width, anchored to neighbours, elided.
- No "·" separators; spacing separates.
- Scrollbars on the container's right border.

## Layers

| Layer | Path | Owns |
|---|---|---|
| Tokens | `shell/services/Config.qml` | every color, size, duration and glyph |
| Generic primitives | `shell/ui/` | icons, text, controls, rows, overlays, data visuals, scroll mechanics |
| App composition | `shell/appkit/` | window frame, header, scaffold, sidebar, split, page, sections, app states |
| Panel composition | `shell/panelkit/` | popup page, header, rows, footer |
| Features | `shell/features/<name>/` | `Store.qml` state and daemon calls, product content, one-off visuals |

`ui` imports nothing from `appkit`, `panelkit` or features. `appkit` and `panelkit` import `ui`. Features import all three. Never reverse.

`AppWindow` moves from `shell/ui/` to `shell/appkit/`. Each kit gets its own `qmldir`, imported as `qs.appkit` and `qs.panelkit`.

## Tokens

`Metrics`, `Motion` and `AppPalette` are read-only singletons in `shell/appkit/` that alias `Config` tokens. They are names, not a second source: every value is a `Config` token with a built-in default and a line in its TOML.

- New app-wide tokens go in `Config.qml` and `config/appearance.toml`: `appHeaderHeight`, `appRowHeight`, `appSidebarWidth`, `appSidebarWideWidth`, `appPadding`, `appPaddingCompact`, `appPaddingWide`, `appColumn`, `appGap`, `appSectionGap`, `appRadius`, `appControlWidth`, `appChipHeight`, `appTitleSize`, `appCaptionSize`, `appCompactWidth`, `appWideWidth`, `scrollbarHoverWidth`, `scrollbarMinThumb`, `scrollbarFadeMs`.
- Defaults come from today's Settings values (`settingsRowHeight` 48, `settingsPadding` 32, `settingsGap` 16, `settingsSectionGap` 40, `settingsColumn` 900, `settingsSidebarWidth` 220, `settingsRadius` 12, `settingsChipHeight` 30, `settingsControlWidth` 272, `settingsTitleSize` 22), so Settings looks the same after migration.
- The `settings*` geometry tokens are deleted when Settings migrates; only truly settings-only values (`settingsPreviewBelow`) stay.
- Durations end in `Ms`. `Motion` aliases `popupFadeMs`, `toggleMs`, `windowStepMs` and the new `scrollbarFadeMs`.
- `Units` is not needed: `Calc` already holds shared math. Byte and DPR helpers join `Calc` when a second feature needs them.

## Semantic palette

Appkit never uses widget colors such as `launcherHighlight`, `settingsCard` or `cpuBase`. `AppPalette` maps roles onto the existing base tokens:

| Role | Token | Use |
|---|---|---|
| `surface` | `surface` | window and page background |
| `raised` | new `surfaceRaised` | cards, sidebar selection, chips |
| `hover` | new `surfaceHover` | row and button hover |
| `rule` | new `rule` (replaces `settingsRule`) | separators, card borders |
| `ink` | `foreground` | primary text and glyphs |
| `inkMuted` | `muted` | secondary text |
| `inkDim` | `dim` | disabled text, tracks, idle scrollbar |
| `danger` | `red` | destructive actions, errors |
| `warning` | `yellow` | pending, caution |

No accent hue: selection is `ink` on `raised`, matching mono. A colored accent is a later opt-in token with an `accentMono` twin, not part of this plan. Widgets keep their own feature colors.

## Component catalog

| Area | Components | Notes |
|---|---|---|
| Icons | `Icon`, `IconBar`, `IconButton`, `Glyph` | `Icon` is a square slot: `name` from the icon map, `glyph`, or any child content. `Glyph` is font-glyph content only. |
| Slider | `Slider`, `SliderTrack`, `GlyphScale` | `Slider` owns mechanics; renderers are visual only. `GlyphScale` replaces `GlyphBar`. `StepBar` stays the stepped control. |
| Text | `Label` | Roles: title (`appTitleSize`), body (`fontSize`), caption (`appCaptionSize`), value (`valueSample` width). One `fontFamily`. `BarText` stays bar-only. |
| Buttons | `Button`, `IconButton`, `Chip` | Primary, secondary, ghost, danger, disabled, busy, confirm. `ArrowPill` becomes a `Button` icon variant. |
| Inputs | `TextField`, `SearchField`, `Switch`, `PillSwitch`, `Select`, `ColorField`, `FocusRing` | `SearchField` exists in `ui`; Settings switches to it. `InlineEdit` stays the text backend. `PillSwitch` is the segmented control; no separate `Segmented`. `Select` is a dropdown over `MenuList`; `Selector` stays the keyboard list. |
| Rows | `ListRow`, `FormRow` | Leading, content, trailing slots. `GlyphRow` becomes `ListRow` + `Icon`. Settings `Field` becomes `FormRow`. |
| Surfaces | `Card`, `Tooltip`, `Separator`, `Highlight` | One radius, border and padding contract from `appRadius`, `popupBorderWidth`, `appPadding`. `Tooltip` stays every popup. |
| Navigation | `NavItem`, `Tabs`, `Breadcrumb` | Settings nav, Disk tabs and path, VMs sections. `Breadcrumb` separates with a glyph from the icon list, never "·" or "/". |
| Feedback | `Badge`, `ProgressBar`, `Braille`, `EmptyState` | `Braille` is the spinner. Empty and error states are a glyph plus one short line, never an instruction. |
| Overlays | `MenuRow`, `MenuList` | `ContextMenu`, `MenuLevel`, tray and notification menus compose these. |
| Scroll | `Scrollbar`, `AppScroll` | `Scrollbar` stays low-level. `AppScroll` wraps a view and attaches it. |
| App frame | `AppWindow`, `AppHeader`, `AppScaffold`, `AppSplit`, `AppSidebar`, `AppNav`, `AppPage`, `AppSection`, `AppFooter`, `StateView` | The only app chrome. `AppTabs` is `Tabs`; `AppEmpty` is `EmptyState` inside `StateView`. |
| Panel frame | `PanelPage`, `PanelHeader`, `PanelRow`, `PanelFooter` | The only widget popup chrome. |
| Tokens | `AppPalette`, `Metrics`, `Motion` | Aliases of `Config` tokens. |
| Actions | `AppAction`, `AppTask` | Shared command state, busy, confirm, progress, failure. |

## Icons

`Icon` is the only visual icon slot.

- Props: `name`, `glyph`, `size` (default `iconSize`), `ink`, `align` (`center` or `baseline`).
- `name` resolves through `Config.glyph(name)`. Look up the icon list first; one glyph per thing across the app, its launcher entry and its window.
- Child content replaces the glyph: an image, `AgentFace`, `PowerFlow`, or any custom item.
- Glyph content is always drawn through `Glyph`, which centers the ink in its box.
- `IconButton` is the only interactive icon. It owns hover, press, selected, disabled, reveal, tooltip, focus, keyboard activation and accessibility. Tooltips name the thing; they never describe a shortcut.
- `IconBar` lays out icons on one baseline. The topbar and apps use the same contract.
- `AgentFace` is content, not a primitive. It uses the same `Icon` in the bar and in an app.
- `DynamicIcon` stays the low-level paint engine.
- Delete `BarIcon`, `RevealIcon`, `AppIcon` as public primitives. Fold them into `Icon` or feature content.
- Move `AgentFace`, `AgentRow` into `features/agent`. Delete Settings `WidgetGlyph` and `WidgetIcon`; widgets show their `feature.json` `glyph` through `Icon`.

## Slider

`Slider` owns value, range, step, drag, click, wheel, keyboard, focus, disabled, orientation and accessibility.

Renderers are visual only, with no input handling. They receive `value`, `normalized`, `dragging`, `hovered`, `enabled` and `orientation`.

- `SliderTrack` is the default line, fill and knob: `dim` track, `foreground` fill.
- `GlyphScale` is the old glyph-column visual used by Display, Field, Power and Volume.
- A one-off renderer stays in its feature. A renderer used twice moves to `ui`.
- No `render: "glyph"` string switch. Use a component or child item.

## Alignment

Every icon and text follows one contract.

- `Icon` is square.
- Glyph ink is centered through `Glyph`, not bounding boxes.
- Text has a measured line box and is centered by cap-height in rows and buttons.
- Every text slot has a bounded width, anchors to its neighbours and elides.
- Leading and trailing slots have fixed widths from `Metrics`.
- Gaps come from `Metrics`, never local values.
- Features never write `Row { Glyph {} Text {} }`.

Owning components: `Button`, `IconButton`, `ListRow`, `FormRow`, `NavItem`, `AppHeader`, `AppPage`, `BarStat`.

## Scrollbars

The thumb is the content position, never animated content.

- Sits on the container's right border, as `Scrollbar.qml` does today. No track background.
- Thumb follows content directly. No lag.
- Wheel and trackpad are 1:1 with native kinetic behavior.
- No `Behavior on contentY`, no glide, no smooth scroll.
- `scrollbarWidth` idle, `scrollbarHoverWidth` on hover, `dim` ink.
- Minimum thumb `scrollbarMinThumb` (replaces the literal 12).
- Hidden when idle; fades in on scroll or hover over `scrollbarFadeMs`.
- Draggable.
- Every app uses `AppScroll`. No feature draws its own `Scrollbar`.

## App sizes

`AppScaffold` exposes one `sizeClass` from its content width.

| Width | Layout |
|---|---|
| `< appCompactWidth` compact | sidebar becomes a `Drawer`, `appPaddingCompact`, one column, header actions move into a `MenuList` |
| regular | sidebar `appSidebarWidth`, `appPadding` |
| `> appWideWidth` wide | sidebar `appSidebarWideWidth`, `appPaddingWide`, content max `appColumn` |

Rules:

- `AppSplit` collapses in compact.
- `AppHeader` elides the title.
- `AppList` hides detail and size columns in compact.
- `AppPage` owns max width and responsive padding.
- `AppSidebar` labels show in the drawer; icon-only rail only if needed.
- `AppWindow` presets: small 720x480, medium 960x640, large 1200x800, floor 480x360, as `Config` tokens.
- Test 480, 720, 960 and 1280.
- Text does not scale with width. Only layout changes.

## State and actions

Each app gets a store.

```
features/<name>/
  App.qml      composition only
  Store.qml    state, daemon calls, pending, errors
  pages/       app-specific content
```

- Views do not call `Yudae`.
- `appkit` and `panelkit` never import `Yudae`.
- Settings `Store.qml`: schema, pending, apply, layout, errors.
- VMs `Store.qml`: list, selection, power, config, live view.
- Disk `Store.qml`: view, packages, caches, selection, jobs, clean.

Shared action state:

- `AppAction`: text, icon name, kind, enabled, busy, confirm, run().
- `AppTask`: running, done, total, label, failed.
- `Button` consumes `AppAction`.
- `ProgressBar` and `AppFooter` consume `AppTask`.
- One destructive confirm pattern for Destroy, Clean and similar actions: the button arms in `danger`, a second activation runs it. No confirm text that explains the gesture.

Shared async states:

- `StateView`: loading (`Braille`), empty, error, ready.
- One retry action, an `IconButton`.
- Replaces "No machines", "Nothing matches", "Scan to build the map", and daemon error text with a glyph plus a short noun line ("No machines", "No matches"), never a how-to.

## Rules

- One component per job.
- Content goes in slots; no component assumes text.
- Colors from `Config` through `AppPalette`. Sizes from `Metrics`. Motion from `Motion`.
- No local color, size or duration literals.
- No business logic in `ui`, `appkit` or `panelkit`.
- Keep one-off visuals in their feature. Promote on the second real use.
- Delete the replaced primitive in the same migration.
- No new icon wrapper, button, row, header, sidebar, scrollbar or window frame in a feature.
- No aliases or compatibility wrappers left behind.
- No universal render engine. Use components, `Loader` or `Component`.
- No moving data visuals into appkit: `Bubbles`, `Figures`, `DayDial`, `PowerFlow`, `SpeedGauge`, `SignalBars`, `CellGrid`, `DotGraph`, `GlyphScale` stay local or in `ui`.
- No hints, key lists, counters or "·" in any component or the gallery.

## Enforcement

`xmake lint` (`task_lint` in `scripts/tasks.sh`) already runs qmllint, `shell/ui/*.check.js` and `scripts/color-check`. Extend it:

- Run `*.check.js` from `shell/appkit` and `shell/panelkit` too.
- Add `scripts/ui-check`, beside `color-check`, failing on:
  - `Scrollbar` outside `ui` and `appkit`
  - `Behavior on contentY`
  - `GlyphBar`, `GlyphRow`, `BarIcon`, `RevealIcon`, `AppIcon`, `ArrowPill` after migration
  - `font.family` or `font.pixelSize` in features outside data visuals
  - radius or duration literals outside `Config.qml`
  - `ui`, `appkit` or `panelkit` importing a feature or `Yudae`
  - "·" in QML strings
- Add `KitGallery`: one surface showing every component, state and size class, with no hint text.
- Use the gallery for screenshots and as the reference for future agents.
- Update `docs/design-system.md` (layers, tokens, component table), `docs/architecture.md` with the layer rules, and `docs/agent-tooling.md` if app entry points move.

## Migration order

1. Wait for Settings to be finished. Inspect it as the reference app before changing it.
2. Add the app tokens to `Config.qml` and `config/appearance.toml`. Create `shell/appkit` and `shell/panelkit`; move `AppWindow`; add `Metrics`, `Motion`, `AppPalette`.
3. Build `Icon`, `IconBar`, `IconButton`, `GlyphScale`, `Slider`, `SliderTrack`. Migrate `AgentFace` and the topbar.
4. Build `AppScroll` and the new `Scrollbar`; remove content smoothing from Settings and `Selector`; move the Notify, VMs and Disk sidebar scrollbars to `AppScroll`.
5. Build `Label`, `Button`, `Chip`, `Switch`, `Select`, `TextField`, `ColorField`, `FocusRing`; extend `PillSwitch` and `SearchField`.
6. Build `ListRow`, `FormRow`, `Card`, `NavItem`, `Tabs`, `Breadcrumb`, `Badge`, `ProgressBar`, `EmptyState`, `StateView`, `MenuRow`, `MenuList`, `AppAction`, `AppTask`.
7. Build the app frame: `AppHeader`, `AppScaffold`, `AppSplit`, `AppSidebar`, `AppNav`, `AppPage`, `AppSection`, `AppFooter`.
8. Migrate Settings using its new `Store.qml`; delete the `settings*` geometry tokens.
9. Migrate VMs.
10. Migrate Disk.
11. Build `PanelPage` and migrate Agent, Weather, Network, Volume and Calendar.
12. Delete replaced code, add `scripts/ui-check`, update docs and the gallery.

## Settings inspection

Before migration, inspect the finished Settings app and produce a promotion table.

Check:

- app shell: sidebar, search, header, page, footer, apply bar
- every `Field` control type
- `Section` and card structure
- `DisplayPage` and `GlyphScale`
- `WallpaperPage` picker and theme rows
- `LayoutEditor` chips, library and drag targets
- `BarPreview` simulation
- `WidgetGlyph` and `WidgetIcon` duplication
- hardcoded sizes, glyphs, durations, colors and `Text` styles
- hint text, counters or "·" on screen
- scroll, resize, hover, focus and pending states

For each one: keep, move to feature, promote to kit, or delete. Do not migrate until this table exists.

### Current Settings findings

| Current | Decision | Target |
|---|---|---|
| `App.qml` schema, pending, expect, writes, apply, revert, feature loading | Move | `features/settings/Store.qml` |
| `Binding Config.overlay` in `App.qml` | Move | `Store.qml` |
| 757-line `App.qml` mixes state and view | Split | `App.qml` composition + `Store.qml` |
| Fixed `settingsSidebarWidth` sidebar, no resize | Promote | `AppScaffold` + `AppSplit` + `AppSidebar` |
| Custom search box (`Rectangle` + `TextInput` + placeholder) | Replace | existing `ui/SearchField` inside `AppSidebar` |
| Custom nav rows | Promote | `NavItem` inside `AppNav` |
| Sidebar `Flickable` without scrollbar | Promote | `AppScroll` |
| Header + `ArrowPill` + title | Promote | `AppHeader` |
| Custom page `Flickable` + wheel handler + `Behavior on contentY` + `Scrollbar` | Promote | `AppPage` + `AppScroll`; delete smoothing |
| Apply bar + custom pill buttons | Promote | `AppFooter` + `Button` + `AppAction` |
| Widget group chips | Promote | `Chip` or `PillSwitch` |
| Empty/search-error text | Promote | `StateView` / `EmptyState` |
| `Section.qml` heading + card + field loop | Rewrite | `AppSection` + `Card`; keep a thin settings section |
| `Field.qml` label/note/pending layout | Promote | `FormRow`; pending ink `warning` |
| bool control | Promote | `Switch` |
| enum control | Promote | `PillSwitch` or `Select` |
| numeric control + `GlyphBar` + value input | Promote | `Slider` + `GlyphScale` + `TextField` with `valueSample` width |
| color swatch + `ColorDialog` | Promote | `ColorField` |
| glyph preview + text input | Promote | `TextField` + `Icon` |
| text input | Promote | `TextField` |
| `popupPos` grid picker | Keep | one-off `PositionPicker` in settings |
| `DisplayPage` local `Heading`, `Panel`, `Rule` | Delete | `Label`, `AppSection`, `Card`, `Separator` |
| `DisplayPage` monitor row | Promote | `FormRow` |
| `DisplayPage` group row + `GlyphBar` + value | Promote | `FormRow` + `Slider` + `GlyphScale` |
| `DisplayPage` resolution rows | Promote | `ListRow` with a trailing check `Icon` from the icon list |
| `DisplayPage` “more resolutions” link | Promote | `Button` ghost variant |
| `WallpaperPage` heading and empty text | Promote | `Label` + `EmptyState` |
| `WallpaperPage` wallpaper tile, active outline and hover | Promote mostly | `Card` with selected state; keep wallpaper data |
| `LayoutEditor` local `Heading`, `Panel`, `Rule` | Delete | `Label`, `AppSection`, `Card`, `Separator` |
| `LayoutEditor` slot chips and ghost chip | Promote | `Chip` |
| `LayoutEditor` library rows | Promote | `ListRow` |
| `LayoutEditor` drag state and drop aiming | Keep | feature-only composition |
| `WidgetGlyph` dynamic glyph switch | Delete | `Icon` with `feature.json` `glyph`; optional sample component for agent/workspaces |
| `WidgetIcon` loader | Delete | `Icon` |
| `BarPreview` frame and arrows | Promote mostly | `Card` + `IconButton`; keep simulation logic |
| `LayoutEditor` hidden `BarBody` and `../../bar` import | Refactor | public widget catalogue or sample preview API; do not reach into bar internals |
| 30 raw `font.family` declarations | Promote | `Label` roles |
| 61 hardcoded sizes, margins, radii and durations | Promote | `Metrics` and `Motion` tokens |
| `Config.settings*` palette and geometry tokens | Replace | `AppPalette` and `app*` tokens; keep truly settings-only values |
| `settingsAccent` (`cpuCore`) | Delete | selection is `ink` on `raised` |
| `ArrowPill` | Replace | `IconButton` |
| MouseArea-only nav, chips and buttons | Promote | focus, keyboard activation and accessibility in shared components |

The largest duplication is not visual: `DisplayPage`, `LayoutEditor` and `Section` each define their own heading, card and rule. The largest structural win is moving all of `App.qml`'s state and daemon access into `Store.qml`.

## Acceptance

- Settings, VMs and Disk use `AppWindow`, `AppHeader`, `AppScaffold`, `AppPage` and `AppSplit`.
- All three have one header height, one nav anatomy, one page rhythm and one button hierarchy.
- Sidebars resize through `AppSplit` only.
- Scrollbars come from `AppScroll` only, sit on the right border and show no content smoothing.
- Icons and text share one alignment contract; every glyph comes from the icon list through `Glyph`.
- `mono = true` and `mono = false` both render correctly in the gallery.
- No hint text, counters or "·" on any app surface.
- No raw `Scrollbar`, `GlyphBar`, `GlyphRow`, `BarIcon`, `RevealIcon`, `AppIcon` or `ArrowPill` remains after migration.
- `xmake lint` and `xmake test` pass.
- Screenshots at 480, 720, 960 and 1280 match the kit gallery.
- A new app can be added without a new header, sidebar, button, row, icon or scrollbar.

## Decisions

- Settled: the Settings plan's "macOS-style" means its information architecture and apply flow only. Its look is this design language and its chrome is appkit.
- Settled: no accent hue; mono selection.
- Settled: window rounding stays the Hyprland global; apps draw no frame radius of their own.
- Settled: window size and sidebar width are not persisted; `AppSplit` keeps the width for the session.
- Settled: `panelkit` stays separate; it owns `ProcessPanel` as well as the frame.
- Settled: the duration rule covers animation `duration`; `Timer` intervals are logic, not motion.

## AGENTS.md rule

The rule is in `AGENTS.md` under `# UI architecture`:

- Apps and widgets compose `shell/ui`, `shell/appkit` and `shell/panelkit`; features never hand-build chrome.
- Missing components go into the kit first; promote on the second use and delete the old one.
- State and daemon calls live in `Store.qml`; views hold no business logic.
- Colors from `Config`, sizes from `Metrics`, motion from `Motion`; no local literals.
- `Glyph` is content only; icons use the shared slot and accept any content.
