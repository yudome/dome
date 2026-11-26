# Daemon shape

`daemon/` is one process, `yudaemond`. It owns every non-UI job: agent state, sessions, plans, workspaces, tray, audio, network, wallpaper, launcher index, icons, and the VM control plane.

## State flow

```
providers -> hub.snapshot() -> unix socket -> services/Yudae.qml -> QML
```

- Each provider renders one key of the snapshot.
- `hub.publish()` coalesces a burst of events into one render (16ms gap) and drops a render identical to the last one.
- The IPC server sends the full snapshot to every client, one JSON object per line. There is no patch protocol.
- `sync` asks for a snapshot after the commands in the same connection, so a caller always sees its own write.

## IPC messages

- `{"sync":true}` - reply with the current snapshot.
- `{"cmd":{...}}` - a command, routed by `commandThunk` in `main.zig`.
- `{"dismiss":"id"}` - dismiss a notification or session row.
- `{"refresh":true}` - re-read provider state.
- `{"gaze":true}` - subscribe to pointer lines for the face.

## Layout

- `src/main.zig` - context, provider wiring, command routing.
- `src/hub.zig` - snapshot render, revision, publish coalescing.
- `src/ipc.zig` - socket server, clients, broadcast.
- `src/cli.zig` - `state`, `doctor`, `bench`, `parity`, `call`, `mcp`.
- `src/mcp.zig` - stdio JSON-RPC tools.
- `src/providers/<name>.zig` - one job each.
- `src/primitives/` - code used twice.

## Command routing

A provider registers its commands by key. `yudae call <target> <method> [args...]` sends `{"cmd":{"<target>":{"<method>":<value>}}}`. With no arg the value is `true`, one arg is a string (or JSON if it parses), several are an array. The daemon routes the target to the provider; the provider validates the method.

## Settings

Every settings category is one file under `shell/config/`. Adding a setting means adding a line to that category's file; a key needs no registration, its type comes from its value. A trailing comment documents it: `# 4..30` is the range, `# icon | text` the choices. All font glyphs live in `icons.toml`.

The files under `shell/config/` stay the only store. Edits are one line each, keeping indent, trailing comment and file order; the result is parsed before the atomic write, so a bad edit never lands.

- `settings.get {key?}` returns one value, or the whole flattened map without a key.
- `settings.set {key, value}` finds the category file that owns the key, writes one line there and then the keys that copy or derive from it, in that file or another: `# same as <key>`, and arithmetic or `a ? b : c` comments that name the changed key (`notifyWidth` follows `notifyScale`, `barBorderWidth` follows `barFloating`). The value must have the key's current type: string, bool, integer (a whole float is accepted) or float (an integer is written as `N.0`). Non-ASCII text is written as `\uXXXX` / `\UXXXXXXXX`. Errors: `UnknownKey`, `WrongType`, `Unsupported` (arrays and tables), `NoKey`, `NoValue`.
- `bar.layout {layout}` writes the whole `topbarlayout.json` document atomically after the same `normalize` the bar reader uses accepts it (`NoBar`, `NoLayout`). One widget per line, like the checked-in file.

## Wallpaper

yudaemond draws the wallpaper itself; there is no awww. `src/c/wallrender.c` runs one render thread with its own Wayland connection: one wlr-layer-shell background surface per output (fractional scale + viewporter, hotplug), frames paced by `wl_surface.frame` so every animation runs at that output's Hz.

- Decode: `src/c/imgdecode.c`, by magic bytes. jpg through TurboJPEG (scaled 1/2, 1/4, 1/8 while it still covers the output), png through wuffs (the `daemon-deps` xmake target fetches the pinned C file and the layer-shell XML into `build/deps/` and runs wayland-scanner into `build/deps/gen/`), webp through libwebp, everything else (avif, jxl, gif, tiff) through libav.
- Draw: EGL + GLES 3. Cover scaling on the GPU, one readback into a `wl_shm` buffer per output, then the GL context, textures and decoder are freed. Idle is one buffer per output and no wakeups.
- Transitions: `none`, built-in `fade` (`wallpaperTransitionMs`) and `transition` plugins (docs/plugins.md). `wallpaper.apply {path, transition?, output?, fade?}`; `wallpaperTransition` picks the default.
- Ink: measured from the top band of the final frame before the transition starts and published when the eased progress reaches `ink_at`. Same luminance rule as awww's `ink.rs`. Each output keeps its own verdict; the `ink` snapshot and `bar-ink.json` keep their shape.
- Video (mp4, webm, mkv, mov): `src/c/video.c` decodes through libav with VA-API when present; NVDEC frames reach GL without a copy (`EGL_EXT_image_dma_buf_import`, one NV12 `samplerExternalOES` image), otherwise planes are uploaded. A timerfd presents only when a new video frame is due. `wallpaperVideoLoop = false` plays once on apply and settles on the still frame; `true` loops.
- Settle: the playback rate eases from 1x to 0 (`1-(1-u)^curve`) and lands on the still frame, on its next occurrence far enough ahead, looping forward. `wallpaper.play` ramps back up, `wallpaper.settle` stops, `wallpaper.pause true|false`, `wallpaper.frame {path?, t}` saves the still frame.
- Still frame pick: `src/c/stillpick.c` decodes every frame at 160x90 once, at nice 19, scores motion decay, sharpness, contrast and light, skips frames near scene cuts, and derives the settle length (600-2500ms). `providers/stills.zig` caches it in `build/cache/wallpaper-videos.json` by mtime and size, with the user's `restFrame`.
- Still frame app: `yudae still [path]` opens `daemon/still.py` (GTK4) on the active wallpaper or `path`. It reads fps, duration and the current still from `wallpaper.filmstrip {path}`, shows frames through ffmpeg and saves with `wallpaper.frame {path, t}`.
- Pause: socket2 events; `wallpaperPause = "fullscreen" | "any-window" | "never"`. Paused means no frames, no decode, audio faded and corked, GL freed.
- Audio: `wallpaperAudio = false` by default, `wallpaperVolume`. When off the audio track is never opened and no PipeWire stream exists; `wr_audio_opens` is the one gate.
- VMs: the host writes `$XDG_RUNTIME_DIR/yudae-state/state.json` (and `still.jpg` for videos); the VM control plane shares it read-only as virtiofs tag `yudae-state`, `vm/desktop` mounts it at `/run/yudae-state`, and the guest daemon shows that image with the host's ink. An explicit `wallpaper.apply` in a guest still draws, for tests.
- Checks: `yudae transition check <file>` compiles a transition on the real driver. `yudae bench wallpaper <files>` and `yudae bench wallpaper --live <file> [s]` (docs/perf.md).
- `xmake wallpaper-check [all|daemon|images|video|controls|fullscreen|still|outputs]` runs every check above against the live session after `xmake install`: inks per transition, idle with no GPU context, video pacing and settle, play/pause/settle, a real fullscreen window, filmstrip, preview, saved still frame, zero copy, audio cork, hotplugged outputs and the VM share. It makes its own fixtures in `~/.cache/yudae/wallpaper-check`, opens and closes a terminal, creates and removes a headless output, and puts the original wallpaper back. `wallpaper.stats` is the counter it reads.

## VM control plane

The daemon is the only process that talks to QEMU and to guest daemons:

```
host yudaemond --QMP unix socket--> qemu per VM (screendump, input, stop/cont, balloon)
      |
      +--vsock (CID per VM)--> guest yudaemond (state, ui tree, call, exec)
```

Provider code lives in `src/providers/vms/`: `qmp.zig`, `vsock.zig`, `budget.zig`, `tiers.zig`, `cgroup.zig`, `images.zig`. The snapshot has a `vms` section that QML renders like any other provider. Agents never talk to QEMU or the guest directly.

Guest networking is `vm/net`: one unprivileged network namespace per VM made by `pasta --config-net --no-map-gw`, nft rules inside it, and `passt --one-off` behind QEMU. The rules are built from the host's live addresses at VM start and drop the host's own addresses and prefixes, `10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `100.64/10`, `fc00::/7` and `fe80::/10`. The guest gets the internet but not the host, its LAN or its loopback services; DNS sent to `10.0.2.3` goes through pasta to the host resolver. The host's nft ruleset is never touched. The daemon kills the namespace with the VM, also when a start fails.

Shares (repo, wallpaper, state, nvidia, host pacman cache) are `virtiofsd --readonly`. The pacman cache share is the first `CacheDir` of the host (`pacman-conf CacheDir`), mounted at `/mnt/hostpkg` and listed first in the guest's `CacheDir`, so guest installs take the host's exact builds and download the rest into the guest's own cache.

Pausing a VM (idle tiers, `vm sleep`, `vm park`) tells a Conduit backend `keep` on its power socket (`--power-socket`, `power.sock` in the run dir) before QMP `stop`, so the device restart on `cont` keeps the guest's GPU objects instead of resetting them under Hyprland. A logind delay inhibitor watches `PrepareForSleep`: before the host sleeps the daemon pauses every hot VM (and asks Conduit backends to `hold`), after it wakes it `release`s them, continues exactly those VMs and sets their clocks.

Images come from `vm/mkosi/build` (see `docs/agent-tooling.md`). When the base of a disk's backing chain sits next to a `vmlinuz` and `cmdline`, the daemon boots that kernel directly (`-kernel`/`-append`); older images without them boot from their own disk.

A governor loop every 5s steps idle VMs hot to warm (5 min), warm to parked (15 min), parked to off (60 min, disk kept). Past the idle destroy budget (default 24h, `YUDAE_VM_IDLE_DESTROY_MS`) it removes the VM and deletes its run dir. Scenario runs delete their VM on success and keep their screenshots.

## File search

`providers/files/` is the launcher's file and folder name index, Spotlight style: `index.zig` (format, search, case folding), `build.zig` (walker, builder, change scan), `recent.zig` (recent list and inotify watcher), `follow.zig` (fanotify follow through `yudae-fsd`). For any home search the launcher puts up to 8 `file` rows after the first 4 results; activating one runs `xdg-open` and records usage like apps.

- Files live in `$XDG_CACHE_HOME/yudae/` (default `~/.cache/yudae/`): `files.idx` (the index, read through `mmap`, replaced by an atomic rename) and `files.log` (entries added since the last rebuild).
- Built by `yudaemond files-index <root> <home> <out>`, a short-lived child at nice 19, as the user, so only readable paths are indexed. Hidden entries are skipped except `~/.config`. Skipped: the disk guard's protected paths, `/tmp /var /opt /nix /snap /lost+found`, `node_modules`, `__pycache__`, `zig-out`, and any mount whose source device is not the one `/` or `$HOME` lives on; its folder shows but is not walked.
- Breadth first, `$HOME` before the rest, so ids are already in rank order. A thread pool lists directories in batches of 64 while the main thread streams names to the file; two poster threads build the gram lists.
- Every folder has a record (id, first child, child count, parent record, name, mtime), so folder paths come back without decoding names.
- Refresh, in the daemon: when the launcher opens and the last scan is older than 10 s, every recorded folder is stat'ed in parallel (about 55 ms for 110k folders on 4 cores). Only folders whose mtime moved are read; names missing from the index, and the whole contents of new folders on the same device, go into the recent list and `files.log`. Deleted entries need nothing: results are `statx` checked.
- Follow: the daemon keeps a connection to `yudae-fsd` (`follow`). The helper marks every filesystem the index covers with fanotify, resolves each event to its folder, drops folders the user could not list, and streams the changed folders every 500 ms. The daemon diffs only those folders against the index into the recent list, so no stat scan runs while following. Without the helper, or after a queue overflow, the stat scan above is used. btrfs subvolumes reject fanotify fid marks with `EXDEV`, so the helper falls back to a no-fid filesystem mark, streams the folder of each closed write, and reports partial follow (`P`); the daemon then keeps the stat scan on launcher open for renames and empty folders.
- Compaction, in `files-index`: only when there is no index or the recent list fills (20000 entries). `yudae files rebuild` (IPC `{"cmd":{"launcher":{"rebuildFiles":true}}}`) forces a from-scratch build in the background: it waits for any running scan, ignores the old index and swaps the new one in. It reuses the children of every folder whose mtime is unchanged, so only changed folders are read from disk; if nothing changed it only rewrites `built_ms`.
- Layout: header with section offsets, names (blocks of 64 front-coded names with a zigzag varint parent delta and dir bit), posting lists, block starts, keys, folder records. Trigrams list blocks; 1 and 2 byte grams list groups of 16 blocks. Names are folded to lower case for ASCII, Latin-1, Latin Extended-A, Greek and Cyrillic.
- A query intersects up to 8 of its rarest gram lists, decodes only matching blocks and stops at 64 hits. Rows sort exact match first, then files you opened before, then prefix, word start, substring, then `$HOME` first, then newest modified; `statx` drops deleted files.
- Live: an inotify watcher on `$HOME` and eight levels below (at most 32768 directories) adds new files, folders, renames and deletes to the recent list at once. The list is deduplicated, reloaded from `files.log` on start and pruned after each compaction.

## Disk provider

`providers/disk/` owns `disk`. A scan runs only when `disk.scan` is called; nothing scans on open, on a timer or in the background.

- `scan {path}` starts a scan and returns `scanning`. Every scan goes through `/run/yudae/fsd.sock`; without the root helper the scan does not run. There is no unprivileged or partial scan path.
- `view {path, depth}`, `search {query}`, `stat {path}`, `mark/unmark {path}`, `trash/delete {path}`, `move/copy/rename {from,to}`, `packages`, `uninstall {names,confirm}`, `clean-packages {confirm}`, `caches`, `clean {id,confirm}`, `watch {path,seconds}`.
- `watch` starts a background fanotify session and places the changed names and sizes in `disk.live` in the snapshot; it does not scan on open or on a timer.
- Snapshot key `disk` carries status, error, root, focus, real disk used/free, totals and the focused view only. The treemap layout is computed in Quickshell.
- Cache `~/.cache/yudae/disk.bin` is mode `0600`, written to a temp file and renamed. It is a `mmap` layout: fixed header, flat 32-byte nodes, one name buffer, totals already summed.
- A root scan walks `/usr`, `/etc`, `/home`, `/var/cache` and other mounts, so the map covers the real data. Only pseudo filesystems `/proc /sys /dev /run` and shared btrfs snapshot stores (`/.snapshots`) are skipped. Write and delete protection is separate: those static paths and mount roots are still refused. The used/free bar reads the real filesystem.

### yudae-fsd

`yudaemond fsd` (installed as `/usr/local/lib/yudae/yudaemond fsd`) is the root helper behind `systemd/system/yudae-fsd.socket`. It reads `SO_PEERCRED` and a pidfd from each connection, asks polkit `CheckAuthorization` for the action, then re-checks the protected list. Scans cross mounts read-only; removal paths are opened with `openat2(RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV)`.

| action | policy |
| --- | --- |
| `org.yudae.fs.scan` | `auth_admin_keep`, about five minutes |
| `org.yudae.fs.follow` | `yes` for the active session: read only, folder names the user can list |
| `org.yudae.fs.remove` | `auth_admin`, every time |
| `org.yudae.fs.bench` | `auth_admin` |
| `org.yudae.packages.manage` | `auth_admin` |

Repo files are `systemd/system/yudae-fsd.socket`, `systemd/system/yudae-fsd.service` and `systemd/system/org.yudae.policy`. `xmake install fsd` writes them only after a root confirmation; nothing writes as root on its own.

### Bench

`xmake bench disk` runs the synthetic fixture (deep, wide, 1M-capable tiny files, hardlinks, sparse file, symlink loop), benchmarks V0 sequential, V1 threaded and V2 io_uring at 1/2/4/8/16/nproc plus V3 btrfs `TREE_SEARCH_V2`, keeps the fastest exact scanner, records every variant in `bench/disk.jsonl` and checks `bench/baseline.json`. `--cold` drops the page cache through `yudae-fsd` (or directly when root), `--real` adds `$HOME`. Accuracy is always exact; reference scanners are reported when present, never installed automatically. V2 is the only shipped scanner; without io_uring the scan fails instead of silently walking the tree. V3 is measured but not shipped because btrfs inline extents fail the exact block-accounting gate on tiny files.
