---
name: VM
description: Use when working with the QEMU VM control plane, guest scenarios, the VM viewer app, yudae VM verbs, or the yudae MCP VM tools.
---

- Drive the VM through `yudae` or the yudae MCP (`opencode mcp list` -> yudae). Do not write throwaway scripts for VM actions.
- Run `yudae vm doctor` before blaming a VM. It prints the NVIDIA/GL verdict and the exact fix for each failed check.
- `backend=auto` uses Conduit on an NVIDIA host, otherwise GL. `vm create --gl` forces the GL path. Do not downgrade the host NVIDIA driver; report it to the user.
- Every agent uses its own VM. `vm_create` with no name names it after the session; pass that name to every `vm_*` call. Never start, reuse, stop or destroy another agent's VM, including `ui`.
- If the daemon lacks the action, ask the user before adding it to yudaemond.
- The viewer app runs on the host. Test guest UI with `yudae vm start/exec/screenshot` or a scenario; watch it with `yudae open <vm> <app>`.
- Read `docs/agent-tooling.md` and `docs/daemon.md` before changing VM behavior.
