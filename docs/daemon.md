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

The Settings app (`shell/app-settings.qml`, `features/settings/`) draws itself from `settings.schema`; it holds no list of settings. Adding one means adding a line to `shell/config.toml`:

- A section is a `[section]` table; the comment line above it is the panel title. A key needs no registration: its type comes from its value, and its label from the key with the section prefix dropped (`barCells` in `[bar]` is "Cells").
- A trailing comment adds the rest without code: `# 4..30` gives the slider range, `# icon | text` makes a choice, `hidden` keeps a key out of the app, and any other sentence is shown as the row's note.
- A page is one entry in `settingsPages` with a name, a glyph from the icon list and the sections it holds, in order. Sections not listed in any page fall under "Other".
- `[agent] agentFinishedToast` turns the "Task finished" toast off; the finished list in the agent panel stays.

`settingsApply` is `instant` (every change is written as it is made) or `manual` (changes wait behind one Apply). It is itself a setting.

`config.toml` stays the only store. Edits are one line each, keeping indent, trailing comment and file order; the result is parsed before the atomic write, so a bad edit never lands.

- `settings.schema` returns the pages, sections and keys with type, value, label, note, choices and slider steps; the app re-reads it whenever the config changes. Glyph keys are collected on the page named `Icons` and left out of every other page.
- `settings.get {key?}` returns one value, or the whole flattened map without a key.
- `settings.set {key, value}` writes one key and then the keys that copy or derive from it: `# same as <key>`, and arithmetic or `a ? b : c` comments that name the changed key (`notifyWidth` follows `notifyScale`, `barBorderWidth` follows `barFloating`). The value must have the key's current type: string, bool, integer (a whole float is accepted) or float (an integer is written as `N.0`). Non-ASCII text is written as `\uXXXX` / `\UXXXXXXXX`. Errors: `UnknownKey`, `WrongType`, `Unsupported` (arrays and tables), `NoKey`, `NoValue`.
- `bar.layout {layout}` writes the whole `topbarlayout.json` document atomically after the same `normalize` the bar reader uses accepts it (`NoBar`, `NoLayout`). One widget per line, like the checked-in file.
- `settings.app {pane?}` opens the app (`setsid scripts/yudae app open settings [--pane <pane>]`), like `vms.app` and `disk.app`. The pane is a page name; Super+P opens the app on `display`.

The bar preview in the app draws the real bar: `bar/BarBody.qml` is the rows, widget components and border that `Bar.qml` uses, so the preview and the live bar are one piece of code. In `manual` mode the app feeds pending values through `Config.overlay`. The display controls (scale, refresh, resolution) live only in the Display page; there is no display widget and no font size in the display panel, so `fontSize` in `[shell]` is the one font size everywhere.

## VM control plane

The daemon is the only process that talks to QEMU and to guest daemons:

```
host yudaemond --QMP unix socket--> qemu per VM (screendump, input, stop/cont, balloon)
      |
      +--vsock (CID per VM)--> guest yudaemond (state, ui tree, call, exec)
```

Provider code lives in `src/providers/vms/`: `qmp.zig`, `vsock.zig`, `budget.zig`, `tiers.zig`, `cgroup.zig`, `images.zig`. The snapshot has a `vms` section that QML renders like any other provider. Agents never talk to QEMU or the guest directly.

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

Repo files are `systemd/system/yudae-fsd.socket`, `systemd/system/yudae-fsd.service` and `systemd/system/org.yudae.policy`. `scripts/yudae-fsd-install` writes them only after a root confirmation; nothing writes as root on its own.

### Bench

`xmake bench disk` runs the synthetic fixture (deep, wide, 1M-capable tiny files, hardlinks, sparse file, symlink loop), benchmarks V0 sequential, V1 threaded and V2 io_uring at 1/2/4/8/16/nproc plus V3 btrfs `TREE_SEARCH_V2`, keeps the fastest exact scanner, records every variant in `bench/disk.jsonl` and checks `bench/baseline.json`. `--cold` drops the page cache through `yudae-fsd` (or directly when root), `--real` adds `$HOME`. Accuracy is always exact; reference scanners are reported when present, never installed automatically. V2 is the only shipped scanner; without io_uring the scan fails instead of silently walking the tree. V3 is measured but not shipped because btrfs inline extents fail the exact block-accounting gate on tiny files.
