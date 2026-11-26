# Performance

Measured, not guessed.

## Budgets

| gate | budget |
| --- | --- |
| incremental build | under 2s |
| cold build | under 20s |
| binary | under 3MB |
| start, fork to socket ready | under 10ms |
| idle RSS | under 8MB |
| subprocess spawns at steady state | zero |

The gates are measured on the headless daemon, `xmake f --headless=y && xmake build yudaemond-headless`, binary `yudaemond-headless`. That is the control-plane build used by CI and by tests that do not need the QML providers. The full desktop daemon is measured separately and reported by `xmake bench` as information, because it carries the launcher index, icon cache and every UI provider.

## Tools

- `xmake` prints build time and binary size, records `daemon/bench/build.jsonl` from `after_build`, and prunes `daemon/.zig-cache` over `YUDA_BUILD_CACHE_MB` (300MB).
- `xmake bench files` runs `yudaemond bench files`: it builds the synthetic file index, rebuilds it with the unchanged-folder reuse path, runs the folder stat scan, mmaps the index, and times name queries. `home` adds the real disk index build. It appends `bench/files.jsonl` and gates the synthetic throughput against `bench/baseline.json` (`files`).
- `yudaemond bench` records binary size, start time, idle RSS, idle CPU over 60s, shell total RSS, and the top RAM/CPU hoggers with deltas against `bench/baseline.json`.
- `xmake build` and `xmake bench` call the same tools and report the same numbers. Compilation is not reimplemented in Lua.
- `xmake bench` builds the headless daemon with a clean cache, starts it on a temporary runtime dir, measures it, and exits nonzero if a gate fails.

## Measured 2026-11-02

Host: CachyOS, kernel 7.3.1, Zig 0.17.0.

| gate | headless | full desktop daemon |
| --- | --- | --- |
| incremental build | 132-198ms | same build |
| cold build | 9.1s | 80s |
| binary | 360KB | 2.70MB |
| start | 0-1ms | 4ms |
| idle RSS | 3.6MB | 41.6MB |
| steady-state spawns | 0 | 0 |

The full desktop daemon over the 8MB RSS and 20s cold gates is not a regression hidden by the headless pass: `xmake bench` prints both numbers. The headless build is the profile that meets the budgets.

## File index, measured 2026-11-16

Host: CachyOS, kernel 7.3.4, Zig 0.17.1, btrfs root. `xmake bench files`.

| fixture | entries | folders | index | build | reuse | stat scan | load | query p50 | query p99 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| synthetic | 20,114 | 44 | 227,204B | 10.7ms | 0.1ms | 0.7ms | 0.01ms | 6.87us | 35.72us |
| home | 878,634 | 70,625 | 18.7MB | 298.8ms | 96.6ms | 20.1ms | 0.02ms | 45.30us | 265.82us |

The home build is `2.94M` entries/s. Reuse rewrites the index from unchanged folder children; the stat scan walks every recorded folder. A cold first build measured separately was 3.0s, and a cold stat scan 48ms.

## Wallpaper, measured 2026-11-25

`yudae bench wallpaper <files>` (offscreen, nothing is drawn) and `yudae bench wallpaper --live <file> [s]` (draws its own background surface; run it in a VM). Budgets:

| gate | budget |
| --- | --- |
| idle after a change | 0 commits, 0 decodes, no GL context, no GPU fds |
| paused video | 0 commits, 0 decodes, audio corked |
| playing video | commits = video fps, 0 dropped |
| settle | lands on the still frame within one frame |
| image decode, 1440p jpg/png/webp | under 100ms |

Host, RTX 3070, ReleaseSafe, 2560x1440 sources (best of 5):

| file | decode |
| --- | --- |
| jpg (q2, 1.0MB) | 18.7ms |
| png (wuffs, RGBA) | 70.9ms |
| webp (q90) | 45.7ms |
| avif (libaom still) | 129.6ms |
| jpg 6016x3384, 25MB | 270ms at 1/2 scale, same as `djpeg` |

| video | VA-API, zero copy | software |
| --- | --- | --- |
| 1080p30 h264 | 638 fps decode+upload | 715 fps |
| 1440p60 h264 | 415 fps | 481 fps |
| 2160p60 hevc | 451 fps | 199 fps |

Binary: 4.07MB ReleaseSafe stripped with the renderer, against 3.75MB before it; the 3MB budget was already exceeded. wuffs is built with only the PNG modules and the RGBA destination.

Zero-copy frames match the software path pixel for pixel (same mean RGB of the last frame). AV1 falls back to software on this driver. Still pick: 40s 2048x872 AV1 in 2.0s; 4s 2160p60 in 1.9s.

Guest (virtio-gpu, software decode), `--live` on 1080p30: 30.0 commits/s, 30.0 presented/s, 0 dropped, 20.6% CPU, 150MB RSS; paused 0 commits and 0 decodes in 3s at 0.00% CPU; settle landed 0.00ms from the still frame, then 0 commits. Audio probe: 48k frames/s while playing, 0 after cork. Real fullscreen window (F11) paused the video at 0.925s and leaving fullscreen resumed at 0.925s. Resolution sweep on a 60Hz headless guest output, fade per mode:

| mode | decode | apply total | fade frames in 400ms | daemon CPU ticks over 2s |
| --- | --- | --- | --- | --- |
| 1920x1080 | 408ms (5K jpg) | 511ms | 24 | 95 |
| 2560x1440 | 82ms (png) | 165ms | 25 | 20 |
| 3840x2160 | 458ms (5K jpg) | 925ms | 23 | 77 |

The guest readback through virgl dominates at 2160p (467ms over decode); the host cost per resolution is not measured yet.

Fade: 400ms at the output rate (25 frames on a 60Hz headless output, ink at +120ms with the default ease).

## VM viewer, measured 2026-11-03

Host: RTX 3070, 615.78.08, Hyprland 0.57.0, QEMU 11.1.3, guest 2560x1440 at scale 1.6667, 279.96Hz. CPU from `/proc/<pid>/stat` deltas, GPU from `nvidia-smi` at 500ms, RSS from `/proc/<pid>/status`. 60s per scenario.

### GTK baseline (C1)

| scenario | qemu CPU | GPU | qemu RSS |
| --- | --- | --- | --- |
| S0 idle desktop | 20.8% | 6.8% | 1.80GB |
| S1 launcher open/close every 500ms | 125.6% | 23.9% | 2.06GB |
| S2 continuous animation | 363.6% | 29.8% | 2.13GB |

### Measured configs

`refreshRate` 279.96 is the guest CRTC mode, not delivered frames. The deliverable metric is frames the viewer actually receives per second. CPU from `/proc`, GPU from `nvidia-smi`, 30-60s.

| config | guest | qemu CPU | other CPU | GPU | RSS | status |
| --- | --- | --- | --- | --- | --- | --- |
| C1 GTK S0 | 2560x1440 1.6667 | 20.8% | - | 6.8% | 1.80GB | measured |
| C1 GTK S1 | 2560x1440 1.6667 | 125.6% | - | 23.9% | 2.06GB | measured |
| C1 GTK S2 | 2560x1440 1.6667 | 363.6% | - | 29.8% | 2.13GB | measured |
| C5 pump S2 | 1536x864 1.0 | 194.4% | pump 13.4% | 38.7% | qemu 1.86GB, pump 19MB | measured |
| C2 viewer windowed S0 | 2560x1440 1.6667 | 61.9% | viewer 14.1, hypr 10.8 | 14.2% | qemu 1.78GB, viewer 263MB | measured |
| C2 viewer windowed S1 | 2560x1440 1.6667 | 141.7% | viewer 25.4, hypr 16.1 | 29.1% | qemu 1.81GB, viewer 263MB | measured |
| C2 viewer windowed S2 | 2560x1440 1.6667 | 441.3% | viewer 44.5, hypr 21.3 | 30.5% | qemu 1.82GB, viewer 263MB | measured |
| C3 viewer fullscreen S0 | 2560x1440 1.6667 | 73.6% | viewer 16.9, hypr 7.4 | 11.9% | qemu 1.81GB, viewer 262MB | measured |
| C3 viewer fullscreen S1 | 2560x1440 1.6667 | 139.3% | viewer 26.1, hypr 11.9 | 9.4% | qemu 1.81GB, viewer 264MB | measured |
| C3 viewer fullscreen S2 | 2560x1440 1.6667 | 439.3% | viewer 44.2, hypr 18.6 | 37.8% | qemu 1.86GB, viewer 266MB | measured |
| C4 ScanoutMap/pixmap | 2560x1440 | - | - | - | works, not timed |
| C6 egl-headless S2 | 1536x864 1.0 | 201.7% | - | 29.1% | 1.92GB | measured |

The C5 pump is the agent baseline: no human window, 1536x864 at scale 1, guest still presenting. The C6 `egl-headless` baseline at the same size is slightly cheaper: 201.7% CPU and 29.1% GPU against 207.8% total CPU (194.4% qemu + 13.4% pump) and 38.7% GPU. The dbus display therefore costs about 3% more CPU and 9.6 GPU points for agents, and it is kept because viewing then needs no VM restart. The earlier frozen-guest C5 numbers were invalid and are gone.

C2/C3 do **not** pass the C1 GTK bar: qemu CPU is 61.9-441.3% windowed and 73.6-439.3% fullscreen against GTK 20.8-363.6%, and the viewer adds 14.1-44.5% CPU and ~262MB RSS. The viewer is a real Quickshell process, not a thin GTK child; the honest result is that the native path is heavier. GPU is 11.9-37.8% against GTK 6.8-29.8%. Fan-out and frame count were not re-instrumented in this run.

The C4 fallback is proven separately with a non-GL guest (`virtio-gpu-pci`, llvmpipe, `-display dbus,p2p=yes`): QEMU sends `ScanoutMap` with a 2560x1440 memfd, stride 10240; the viewer mmaps it, swizzles BGRA to RGBA and uploads the texture. The first full scanout is lost to the listener-registration race, so the viewer nudges `SetUIInfo` once after connecting to force a fresh scanout. The screenshot is `vm/runs/demo/proof/scanout-map.png`. Not timed yet; the pixmap path copies and swizzles the whole frame.

The native viewer does receive 150 `UpdateDMABUF` frames/s on the animation, so the ack/toy-client throttle from the spikes is gone. A screenshot of the viewer shows the guest bar, the animation and the sidebar.

### Frame path now proven

1. The guest cycles dmabuf scanouts. QEMU exports them with `ScanoutDMABUF2`, fourcc ``A B G R 8 8 8 8``/``X B G R``, modifier `0x0300000000e08014`. The viewer imports with `EGL_LINUX_DMA_BUF_EXT` and draws a `QSGSimpleTextureNode`.
2. QEMU caches the export by texture id; repeat scanouts become `UpdateDMABUF`.
3. `/home/user/dotfiles/daemon/zig-out/bin/yudae-pump` keeps an agent VM presenting with no viewer, at 1536x864 scale 1.
4. `yudae vm view` stops the pump, sets 2560x1440 scale 1.6667 in the guest and opens `shell/app-vms.qml`; `vm release` restores 1536x864 and restarts the pump. No VM restart.
5. The native plugin is copied into `~/.local/lib/yudae/qml` by `vm/desktop`, `shell/shell-guest.qml` imports it, and its `registerTypes` calls `QQuickWindow::setDefaultAlphaBuffer(true)`. The guest overlay alpha is fixed: `quirks:skip_non_kms_dmabuf_formats = false` makes Hyprland advertise non-KMS ARGB formats, system Mesa exposes 25 ARGB8888 configs and the launcher shows the wallpaper. Proof: `vm/runs/demo/proof/launcher-alpha-hyprland-quirk.png`.

### Venus + zink attempt (2026-11-03)

Venus was tried as the virgl alpha fix. QEMU ran with `virtio-gpu-gl-pci,blob=on,hostmem=2G,venus=on`; the guest installed `vulkan-virtio`. `vulkaninfo` sees `Virtio-GPU Venus (NVIDIA GeForce RTX 3070)` and `VK_KHR_wayland_surface`, but windowed use is broken on this host: `vkcube` selects the Wayland WSI and dumps core, and zink fails with `ZINK: failed to choose pdev` on every window surface, falling back to llvmpipe. `eglinfo -p wayland` sees zink only through the EGL device path, not a window. QEMU was reverted to plain `virtio-gpu-gl-pci`. Proof: `vm/runs/demo/proof/venus-vkcube.log`, `venus-gl-zink.txt`, `venus-gl-virgl.txt`.

### Mesa fork attempt (2026-11-03)

Superseded by a one-line Hyprland quirk. The guest compositor filtered ARGB out of its dmabuf feedback because the virtio-gpu primary plane is XR24-only. `quirks:skip_non_kms_dmabuf_formats = false` makes Hyprland advertise non-KMS formats too; the system Mesa then exposes 25 ARGB8888 configs with alpha 8, and the guest launcher shows the wallpaper behind it. No Mesa or Hyprland fork is needed. Proof: `vm/runs/demo/proof/launcher-alpha-hyprland-quirk.png`. The local Mesa fork was deleted.

### Guest parity (P1-P5)

- P1/P2: host DP-2 is 2560x1440, scale 1.6666666, 279.961Hz; guest Virtual-1 is 2560x1440, scale 1.6666666, 279.95999Hz.
- P3: host and guest both use `/home/user/Documents/Wallpaper/wallhaven-0p2em3_2560x1440.png`; the guest snapshot's `wallpaper.active` reports the same image.
- P4: 676 host font families against 642 guest; the missing ones are CachyOS extras (Arabic/Syriac PCF), no guest-only families. The shell font `GoogleSansCode Nerd Font` resolves in both. Icon themes are the same 8; host has one extra `cachyos.svg` icon, not a theme. `breeze_cursors` is present in both.
- P5: fixed by the Hyprland non-KMS quirk; see the proof above.

### VM image build

`xmake vm bench [tag]` runs `vm/images build --force` in `~/.cache/yudae-vm-bench` (`DOTFILES_VM_BENCH` moves it, `DOTFILES_VM_BENCH_CACHE` the cache) and appends one JSON line to `bench/images.jsonl` (gitignored).

Old `vm/images` script (cloud image plus a provisioning VM) against the mkosi pipeline, with the NVIDIA bits (`conduit-guest`, headers, dkms), on this host:

| run | old script | mkosi, first cut | mkosi now |
| --- | --- | --- | --- |
| full build, host package cache seeded | 95.4s | 98.5s | 64s |
| full build, every package downloaded (489) | fails: cloud image gone (404) | 109.6s | 89.9s |
| edit under `mkosi.extra/` | full rebuild | 39-47s | none, copied from the repo share at boot |
| edit to `mkosi.postinst.chroot` | full rebuild | 39-47s | 21-22s |
| edit to `vm/guest/*` | full rebuild | none, read from the repo share | none |
| image on disk | 3308MB | 1555MB (zlib qcow2) | 238MB own, the rest reflinked from the mkosi cache |
| files in the image | - | 110k | 80k |
| guest boot (`systemd-analyze`) | - | 8.8s | 5.0s |
| create to Quickshell running | 17.5s | 12.7-13.2s | 8.8-9.0s |

A full build is now 3s of prep, pacman 25s (7.6s signature checks, 16s single-threaded extraction), hooks 12s (DKMS compiling `conduit-guest` 7s), 9s of depmod, hwdb, mkosi's cache copies and the setup script, and 11s of mkfs. The old cache and output are moved aside and deleted after the build instead of before it (4.5s). Putting the whole host cache into mkosi's local repo would skip the signature checks but `repo-add` of 541 packages takes 11s. Where the edit rebuild went: mkosi's `Format=disk` ran `mkfs.btrfs --rootdir` through systemd-repart (24s, a full copy, and mkosi does not pass `SYSTEMD_REPART_MKFS_OPTIONS_BTRFS` on) and the qcow2 conversion took 14s. Now mkosi stops at a directory (11s) and the build runs `mkfs.btrfs --reflink --nodesize 4096 -O ^free-space-tree,^block-group-tree` itself: 6s with a warm page cache, about 10s right after mkosi; the default node size and features took 9-11s. Boot lost `ldconfig.service` (1.2s on the critical path), the update units and `systemd-nsresourced` (2.4s). `vm/images overlay` is 31ms, 27 of them `qemu-img create`.

Viewer overlay (`Ctrl+Alt+O`) with a terminal printing every 2ms, viewer open at 2560x1440 on a 280Hz host: old image 240 fps received / 132 shown, mkosi image 260 / 128, about 4ms average frame on both; Conduit path 158 / 148.

The mkosi image boots the host's kernel directly, with no bootloader and no initrd.

### Clock

QEMU uses `-rtc base=utc,clock=host`, so the guest RTC is the host wall clock. `vm/desktop` runs `hwclock -s` at Hyprland start, applies the host timezone from `vm/hoststate/timezone`, then disables NTP. `setGuestMode` disables NTP too. Guest `NTP=no`, `systemd-timesyncd` inactive/disabled; guest and host wall clocks stay within the vsock measurement margin.

### Full daemon budget

The headless daemon still passes 3.6MB idle RSS and 9.1s cold build against 8MB/20s. The full desktop daemon measures ~41.6MB/80s because it carries the launcher index, icon cache and every UI provider. Proposal: keep 8MB/20s as the control-plane gate and make the full desktop budget informational (48MB/90s), or lazy-load the launcher index/icons behind first use. That change is not made in this round; the measured numbers are the finding.

### Open bench work

- C2/C3 are measured above; they miss the C1 GTK bar.
- C6 `egl-headless` on the same guest sizes for the agent comparison.
- Mouse input latency still needs a tablet marker capture.
- Per-delivered-frame CPU/GPU, not just totals.

## Disk scanner, measured 2026-11-11

`xmake bench disk` builds a seeded synthetic tree, runs V0 sequential, V1 threaded and V2 io_uring batched statx at 1/2/4/8/16/nproc, plus V3 btrfs `TREE_SEARCH_V2`, keeps only exact versions, and writes every measured variant to `daemon/bench/disk.jsonl`. The first accurate run seeds the `disk` block in `daemon/bench/baseline.json`; later runs fail when the winner drops under 80% of that baseline or the cache grows past twice its baseline. `--files=N` changes the tiny-file count, `--real` adds `$HOME`, and `--cold` drops the page cache through `yudae-fsd` (`org.yudae.fs.bench`) or directly when the benchmark itself runs as root.

Measured in the VM, kernel 7.2.11, Zig 0.17.1, 20k tiny files:

| metric | warm | cold |
| --- | --- | --- |
| winner | v2 io_uring, 1 thread | v2 io_uring, 1 thread |
| throughput | 756k entries/s | 545k entries/s |
| syscalls | 0.01 per entry | 0.01 per entry |
| cache | 5.7kB, sub-millisecond `mmap` load | same |
| accuracy | exact against `statx` block totals | exact |

V1 thread counts are measured too; 8 and 16 threads lose to 1-2 because of lock and path allocation overhead. V3 reads the same exact tree on a btrfs subvolume but btrfs inline extents make its `nbytes` total disagree with `st_blocks` for tiny files on this fixture, so it fails the exact gate and is not shipped. The io_uring path is the only scan path; if it is unavailable the scan fails with a clear error.

Reference scanners ncdu, gdu, dua and hyperfine are reported when present. Installing them needs root and is asked for at bench time, never done automatically.

## Rules

- An optimization that breaks parity does not count.
- Re-run bench after every change that touches a hot path.
- A deliberate simplification with a known ceiling gets a `ponytail:` comment naming the ceiling and the upgrade path.
