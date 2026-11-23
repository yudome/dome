---
name: Quickshell
description: Use when editing QML, shell surfaces, apps, services, live reload, quickshell logs or the shell design system.
---

- Run the shell from the repo: `quickshell -p shell/shell.qml`; never edit installed copies.
- Check `/run/user/1000/quickshell/by-id/<newest>/log.qslog` with `grep -a` on errors.
- Use the shell tokens in `shell/services/Config.qml`; keep the existing type and palette.
- Reusable UI belongs in `shell/ui/` (primitives), `shell/appkit/` (app chrome) or `shell/panelkit/` (popup chrome), registered in that folder's `qmldir`. See `docs/design-system.md`.
- Apps compose `AppWindow` + `AppScaffold`; state and daemon calls go in `features/<name>/Store.qml`. Check new UI in `shell/app-gallery.qml`.
- qmllint misses wrong property names on custom types; run `scripts/app-check` (headless cage, part of `xmake test`) and look in your VM.
