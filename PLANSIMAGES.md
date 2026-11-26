# VM images: mkosi instead of vm/images

The guest image is built from declarative mkosi config instead of the 1161-line `vm/images` shell script. The host stays CachyOS; mkosi only builds the guests, from the same CachyOS repos the host uses, so the guest runs the exact package builds of the desktop it tests.

## Goals

- The image is config, not shell: packages, files, units and settings in `mkosi.conf` files.
- Built on the host with pacman, no provisioning VM boot.
- Guest packages come from the host's CachyOS repos and mirrors, so versions match the desktop.
- Editing the session script or a unit rebuilds in seconds, not the 1m40s package image.
- Versions can be locked: a whole-repo snapshot date, plus per-package pins.
- Agents can still install software inside a running guest.
- Isolation: what stays on the host stays on the host, what stays in the guest stays in the guest. Packages flow host to guest only.
- Nothing hardcoded about the host: repos, mirrors, keyring and kernel are read from the host at build time.
- The daemon, viewer, MCP tools and scenarios do not notice the change: same qcow2, same `overlay` and `ensure` contract.
- Requirements added: `mkosi` and `passt` (extra). Nothing from the AUR.

## Decision

mkosi over bootc.

- bootc has no official Arch base, only community experiments; it would add Podman, AUR `bootc` and the image-builder container.
- bootc's extra wins are in-place upgrades and registries. Agent VMs are throwaway overlays on the golden image, so neither pays here.
- mkosi is systemd's builder, supports Arch upstream, runs pacman directly and caches the package tree.
- Revisit bootc only if the host itself moves to an image-based OS. It stays CachyOS, so not planned.

## Layout

```
vm/mkosi/
  mkosi.conf            distribution, output format, caching, snapshot date
  mkosi.conf.d/
    packages.conf       the package list, replaces vm/packages.txt
    pins.conf           per-package version pins, empty until needed
    nvidia.conf         the Conduit guest bits, only for the nvidia backend
  mkosi.extra/          files copied as-is: yudae-session, yudae-gpu-wait, fstab lines, sudoers
  mkosi.postinst        enables units, creates the login user, symlinks hypr config
vm/images               shrinks to overlay, ensure, snapshot, restore, backup, list
vm/xmake.lua            xmake vm images reads the host setup, runs mkosi, converts raw to qcow2
```

## Read from the host

Generated per build, never committed:

- **Repos and mirrors**: the host `/etc/pacman.conf` and the mirrorlists it includes, so the guest uses the same repos and the same x86-64-v3 flavour the host uses. The VM already runs `-cpu host`, so v3 binaries run.
- **Keyring**: a copy of the host `/etc/pacman.d/gnupg`. The guest trusts exactly the keys the host trusts.
- **Kernel**: the kernel package the host runs (the `pkgbase` of the running kernel, for example `linux-cachyos`), at the host's installed version.
- **Package versions**: the host's installed versions of hyprland, aquamarine, quickshell and qt6-base become the expected guest versions.

## Moves

| now in `vm/images` | becomes |
| --- | --- |
| `cmd_fetch`, `CLOUD_NAME` cloud image | gone, mkosi bootstraps from pacman |
| `provision_script`, `delta_script`, `parallel_script` | gone, pacman runs on the host inside mkosi |
| `run_packages_vm`, `direct_initramfs`, `packages_seed` | gone, no provisioning VM |
| `prefetch_packages`, `prefetch_rootfs`, `build_parallel` | mkosi package cache |
| `make_disk_head`, `slice_root_image`, `slice_raw_image`, `make_pkg_image`, `materialize_packages` | mkosi `Format=disk` with systemd-repart |
| `packages_want` hash | mkosi cache keys, split per layer |
| `vm/packages.txt` | `mkosi.conf.d/packages.conf` |
| `golden_setup` heredocs | `mkosi.extra/` files and `mkosi.postinst` |
| `desktop_unit`, `daemon_unit` | unit files under `mkosi.extra/etc/systemd/system/` |
| `compact_packages` | `qemu-img convert -c` after the build |
| `cmd_overlay`, `cmd_ensure`, `cmd_snapshot`, `cmd_restore`, `cmd_backup`, `cmd_list` | stay, same arguments and output |

## Two layers

- **Base**: packages and keyring. Cached; rebuilt only when `packages.conf`, `pins.conf`, the repos or the snapshot date change.
- **Top**: `mkosi.extra/` and `mkosi.postinst`. Rebuilt on every change, in seconds.
- `golden.qcow2` stays a thin layer over the packages image, as now.

## Versions

- `mkosi.conf` takes a snapshot date; packages come from that day's archive. Empty date means latest, as today.
- CachyOS repos have no dated archive like the Arch Linux Archive, so a lock on CachyOS packages is a pin in `pins.conf` with the exact version.
- `xmake vm images` prints guest versions of hyprland, aquamarine, quickshell and qt6-base next to the host's and fails on a mismatch, unless a pin says otherwise.

## Isolation

The guest can read what the host shares, never write it. Nothing the guest does lands on the host.

| channel | direction | how |
| --- | --- | --- |
| repo, wallpaper, nvidia shares | host to guest, read-only | `virtiofsd --readonly`, enforced on the host (already the case) |
| host pacman cache | host to guest, read-only | new `virtiofsd --readonly` share of `/var/cache/pacman/pkg` |
| clipboard | both ways | kept as now |
| audio | guest to host speakers | kept exactly as today |
| network | guest to internet, not host loopback | passt `--no-map-gw` |
| vsock exec, QMP | host drives the guest | the guest only answers |

Guest root stays writable: it is the guest's own throwaway disk, not the host.

## Agent installs

- Agents install with `yudae vm exec <vm> 'sudo pacman -S --noconfirm <pkg>'`.
- The guest's pacman checks the shared host cache first (`CacheDir` lists it read-only, then its own cache), so packages the host already has are the host's exact builds and cost no download.
- A package the host never downloaded is fetched by the guest into the guest's own cache, never the host's.
- Everything installed lives in that VM's overlay and is gone when the VM is destroyed.
- A package every agent needs goes into `packages.conf`.

## Network

Done, ahead of the mkosi work: passt with `--no-map-gw`.

- One `passt --one-off` per VM, started by the daemon, gone when QEMU exits.
- Internet works; host loopback services are unreachable from the guest.
- DNS: the guest asks `10.0.2.3`, passt forwards only DNS to the host's first nameserver from `/etc/resolv.conf`. Old images with a static `10.0.2.3` keep working.
- Gap today: services bound to the host's LAN address and other LAN machines are still reachable.

### Closing the LAN gap without touching the host

Each VM's network lives in its own unprivileged network namespace, owned by the daemon and gone with the VM. No host firewall, no root.

```
guest -> passt (in the VM namespace, nft rules) -> pasta -> host stack -> internet
```

- The daemon runs `unshare --user --map-root-user --net` per VM; inside it, nft drops the host's own addresses, `10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `fc00::/7`, `fe80::/10`, and allows everything else.
- DNS still reaches the host resolver: `--dns-forward 10.0.2.3` in passt, and pasta forwards that one port to the host.
- pasta connects the namespace to the host with `--no-map-gw` too, so loopback stays closed at both layers.
- The rules are built from the host's live addresses at VM start, not hardcoded.
- Everything already present: `nft` (nftables), `unshare`, unprivileged user namespaces enabled.
- Checks: from the guest, the host LAN address, the router admin page and another LAN machine fail; the internet and DNS work; the host's nft ruleset is unchanged before and after.
- `passt` is a build requirement, checked by `xmake vm doctor`.
- The image symlinks `/etc/resolv.conf` to the systemd-resolved stub; mkosi keeps that.

## Size

- Today: packages image 3.4 GB, golden 2 MB.
- Target: under 2.5 GB.
  - `PackageManagerTrees` excludes docs, man pages and non-English locales.
  - Drop packages no scenario uses, after a pass over `packages.conf`.
  - Compressed qcow2.

## Stays

- QEMU command lines, virtio-gpu, virtiofs mounts of the repo and `/mnt/nvidia`.
- Daemon overlay and ensure calls in `daemon/src/providers/vms/images.zig`.
- The guest yudaemond runs from the repo over virtiofs, as now.
- Snapshots, forks and tiers.

## Tooling

- `xmake install` builds before it installs. Today it can copy a stale `daemon/zig-out/bin/yudaemond` when nothing told xmake the Zig sources changed, so a fresh install runs old code. Install depends on build, and the daemon target rebuilds when any `daemon/src/**/*.zig` is newer than the binary.

## Loose ends

- passt leak: `--one-off` exits when QEMU disconnects, but if QEMU fails before connecting, passt waits forever. The daemon kills it when a VM start fails, and the VM dir cleanup removes a stale `passt.sock`.
- passt on the NVIDIA backend is wired but untested; Conduit is not installed on this host. Test it with step 12.
- Guest kernel and repos read from the host also cover the NVIDIA guest packages (`conduit-guest`), which today come from `vm/packages.txt`.

## Steps

1. `xmake install` builds first.
2. LAN gap: per-VM network namespace with nft rules, pasta behind passt.
3. Install `mkosi` (ask first).
4. Read the host setup (pacman.conf, mirrorlists, keyring, running kernel) into a generated mkosi config; port `vm/packages.txt`; build the base tree; compare the installed package list to the current image.
5. Port `golden_setup`, `desktop_unit`, `daemon_unit` into `mkosi.extra/` and `mkosi.postinst`.
6. Raw to qcow2, wired into `xmake vm images`; old images kept until the new one passes.
7. Boot it through the daemon: `yudae vm scenario shell-ready`, then all `vm/scenarios/*.json`.
8. Version check against the host in `xmake vm images`.
9. Share the host pacman cache read-only in the daemon (one more `virtiofsd --readonly`), mount it in the guest, list it in the guest's `CacheDir`.
10. Size pass.
11. Delete the dead functions from `vm/images`; update `docs/agent-tooling.md`, `docs/architecture.md`, the vm skill.
12. Nvidia backend: `nvidia.conf`, test on the Conduit path once Conduit is installed.

## Checks

- `xmake test` passes.
- Every scenario in `vm/scenarios/` passes on the new image.
- Session script edit to bootable golden: under 15s.
- Clean package build faster than the current 1m40s.
- Guest hyprland, aquamarine, quickshell, qt6-base match the host.
- The VM manager viewer: one cursor, 280 fps cursor, clicks, keyboard, same as the current image.
- `yudae vm exec` runs `sudo pacman -S` in an agent VM, using the host cache when the host has the package.
- After an agent install, the host's pacman cache and installed packages are unchanged.
- From the guest as root: writing to any shared directory fails.
- The guest runs the host's kernel package and repos with nothing hardcoded in `vm/mkosi/`.

## Open

- Whether mkosi's Arch support handles the host's CachyOS `-v3` repos without patches.

## Decided

- Keyring: copied from the host.
- Kernel: whatever the host runs, read at build time.
- Repos: whatever the host uses, read at build time.
- Packages: host cache shared read-only, guest downloads the rest into its own cache.
- Clipboard both ways, audio out as today.
- Guest system writable.
- Network: passt, done.
