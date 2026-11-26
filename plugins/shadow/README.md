# shadow

General window shadows. Replaces the built-in Hyprland shadow with a baked
gaussian texture: a soft ambient halo plus a tight contact layer. Applies to
any window Hyprland would shadow, so `no_shadow`, `no_border` and undecorated
windows are respected; with the repo's `no-shadow-on-tiled` rule that means
floating windows.

The built-in `decoration:shadow:enabled` is turned off while this plugin is
enabled. Quickshell popups bake the same texture from the same options through
the `ShadowTexture` native item.

## Options

Set in the yudae load list (`~/.local/state/yudae/plugins.toml`):

```toml
[shadow]
range = 72    # visible falloff, logical px
offset = 0    # downward shift, logical px
alpha = 0.55  # ambient layer strength
contact = 0
```

`enabled = false` hands shadows back to Hyprland.
