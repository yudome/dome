# Agent tooling

Everything an agent needs is a CLI or an MCP tool. Never guess a command.

## CLI

```
yudae restart                              # restart yudaemond and wait until it answers
yudae call <target> <method> [args...]     # -q: quiet no-op if nothing is running
yudae state | doctor | bench | parity | ui tree
yudae plugin list | build <id> | load <id> | unload <id> | theme <id> | add <url> | update <id> | reload
yudae vm <verb> ...                        # same verbs as the MCP tools
yudae open <vm> [app]                      # open the viewer, or an app inside the guest
yudae disk scan|view|search|stat|mark|unmark|trash|remove|move|copy|rename|packages|uninstall|clean-packages|caches|clean|watch [args...]
yudae settings schema                      # pages, sections and keys as the app draws them
yudae settings get [key]
yudae settings set <key> <value>           # value is JSON when it parses, else a string
yudae settings app [pane]
yudae bar layout <file.json>
```

- Output is plain text: records as aligned tables, objects as `key  value` lines, `vm exec` as the command's own stdout, stderr and exit code. Add `--json` anywhere for the raw JSON; scripts and scenarios that parse output must pass it.
- `yudae disk scan [path]` asks for a scan. `yudae disk view [path]` prints the focused `disk` state. `--yes` confirms `uninstall` and `clean`.

- The daemon owns routing. A feature registers its target in its provider (`weather`, `launcher`, `bar`, `menu`, `lock`, `vms`).
- Hyprland binds, scripts, the MCP and VM scenarios use `yudae call`, never raw `qs ipc call`.
- Changing state from a CLI pushes a refresh; no timers.
- The same command works inside a VM, because the guest runs the same yudaemond.
- `yudae vm key <vm> XF86AudioRaiseVolume` takes hardware names as well as qcodes, so the compositor binds fire. `--hold <ms>` holds the key down for key repeat.

## MCP

`yudaemond mcp` is a stdio JSON-RPC server.

- state, providers, bench, parity
- qs_log
- plugin_list, plugin_build, plugin_load, plugin_unload, plugin_theme, plugin_add, plugin_update, plugin_reload
- settings_schema, settings_get, settings_set, settings_app, bar_layout
- disk_scan, disk_view, disk_search, disk_stat, disk_mark, disk_unmark, disk_trash, disk_delete, disk_move, disk_copy, disk_rename, disk_packages, disk_uninstall, disk_caches, disk_clean, disk_watch
- vm_create, vm_list, vm_state, vm_exec, vm_push, vm_pull, vm_key, vm_type, vm_click, vm_move, vm_drag, vm_scroll, vm_gui, vm_config, vm_screenshot, vm_wait, vm_sleep, vm_wake, vm_park, vm_stop, vm_destroy, vm_snapshot, vm_restore, vm_fork, vm_view, vm_ui_tree, vm_run_scenario

Every result is bounded and typed: capped output with a handle for the rest, exit codes, durations.

`vm_drag` presses at `x,y`, walks to `toX,toY` in `steps` moves (default 16) and releases; the CLI form is `yudae vm drag <vm> <x> <y> <toX> <toY> [steps]`. Scenario steps take the same fields with `"do": "drag"`.

`vm_key` maps hardware names to the QEMU qcode the guest sees, and `hold` keeps the key down in milliseconds for key repeat. Names QEMU has no qcode for (brightness, mic mute) are rejected.

## VM workflow

Structured state first, pixels last:

1. `vm_state` - the guest daemon snapshot.
2. `vm_exec` / `vm_ui_tree` - text and tree.
3. `vm_screenshot` - visuals only.
4. `vm_wait` - QMP events, Hyprland events and the guest socket. No sleep loops, no screenshot spam.

`vm_create` with no name uses the caller's session id as the VM name, so each agent session gets its own VM and a second create reuses it. Never pass another agent's name or a shared name such as `ui`. The budget is half the host RAM and all host cores; a VM takes one core unless `cores` is given. Idle VMs step down hot to warm at 5 minutes, warm to parked at 15, parked to off at 60 with the disk kept. A VM idle past `YUDAE_VM_IDLE_DESTROY_MS` (default 24h, `0` disables) is destroyed with its disk; `destroyIdleMs` on create overrides it per VM. A scenario destroys its VM when it passes and keeps screenshots in `vm/runs/shots/<name>/`; `"keep": true` in the scenario context keeps the VM for debugging.

`yudae vm scenario shell-ready` is the UI smoke: boot, Hyprland, Quickshell, screenshot. `yudae vm scenario <vm> <scenario> --from <tag>` runs it on another golden. `pull` steps take a repo-relative `to`.

## Guest image

`xmake vm images` (`vm/mkosi/build`) builds the guest with mkosi from `vm/mkosi/`, on the host, with no provisioning VM:

- `mkosi.conf.d/packages.conf` is the package list; `pins.conf` takes `name=version` pins; `mkosi.extra/` holds the units, scripts, fstab, presets and sudoers; `mkosi.postinst.chroot` creates the `user` account.
- Repos, mirrors, the public keyring and the kernel package are read from the host at build time (`/etc/pacman.conf` and its includes, `/etc/pacman.d/gnupg`, the `pkgbase` of the running kernel). The host's sync databases fix the versions, so the guest gets the exact builds the host has; packages the host has cached are reflinked, not downloaded.
- The host's installed builds of its kernel package (and headers), hyprland, aquamarine, quickshell and qt6-base are taken from the pacman cache into mkosi's local repo, which comes first, so the guest matches the host even after the sync databases moved on. The build fails when they still differ, unless `pins.conf` pins them. `--snapshot YYYY/MM/DD` pins the Arch repos to the archive and tags the image `golden-YYYY-MM-DD`.
- The package tree is cached until the package list, pins, repos or host databases change; an edit under `mkosi.extra/` reuses it and takes about 20s.
- mkosi writes a directory; the build turns it into a whole-disk btrfs (`root=/dev/vda`, no partition table) with `mkfs.btrfs --rootdir --reflink` inside `unshare --map-root-user`, so file data is cloned from mkosi's cache instead of copied and every file is root's. That raw file is the backing of a thin `golden.qcow2`: no `qemu-img convert`, no compression format any QEMU could lack. Docs, translations and, in the NVIDIA profile, the kernel headers (needed only while DKMS builds `conduit-guest`) are left out.
- Each build lands in `~/.cache/dotfiles/vm/images/<id>/` (`root.btrfs`, a thin `golden.qcow2`, `vmlinuz`, `cmdline`, `manifest.json`) and moves `images/current`. Old ids stay while a VM's backing chain uses them.
- File owners other than root are applied at guest boot by `systemd-tmpfiles` from the pacman mtree data. `ldconfig`, the journal catalog and the `.updated` stamps are done at build time, and host-only units (nsresourced, mountfsd, homed, sysext, wait-online and the like) are masked, so a first boot runs none of them.

Agents install software with `yudae vm exec <vm> 'sudo pacman -S --noconfirm <pkg>'`; it lands in that VM's overlay only. A package every agent needs goes into `packages.conf`.

Apps start from `shell/app-<name>.qml` (`settings`, `vms`, `disk`, `gallery`); `yudae app open <name>` opens one, and a new app needs only its `app-<name>.qml`. `xmake test shell-app/app` loads every app and the shell headless and fails on QML runtime errors. For a UI change, run `quickshell -p shell/app-gallery.qml` in your own VM and screenshot it at 480, 720, 960 and 1280 wide.

A human can watch and take over with `vm view <name>` (the Quickshell `vms` app on that VM, 2560x1440 at scale 1.6667) or from the launcher's Virtual machines entry, which opens the app gallery. The gallery shows gray last-viewed thumbnails and renders no VM until a card is clicked. While a human holds input, agent input fails with "human has control". Closing the window or `vm release <name>` returns the guest to 1536x864 at scale 1 for agents and captures a new thumbnail. `Ctrl+Alt+O` (`vmOverlayKey`) in the viewer toggles a performance overlay like conduit-viewer's: frames received and shown per second, frame time now, average, p99 and max, receive-to-screen latency, input events per second and the display path. On the Conduit path the backend stamps each frame with the guest's flip time, so it also shows flip-to-receive and flip-to-screen, and frame times come from the flips.
