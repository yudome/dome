# yudaemond

The shell backend. One Zig process, no dependencies.

- `xmake build yudaemond` builds `build/bin/yudaemond`
- the build prints its time and binary size, records `.bench/build.jsonl`, and prunes the cache over 300MB
- `yudaemond restart`, `state`, `doctor`, `bench`, `bench widgets`, `parity`, `mcp`
- Every command prints plain text; `--json` prints the raw JSON
- `yudaemond bench widgets` ranks every shell widget by open time and by shell
  and daemon RSS/CPU while it is open, measured in a test VM guest
  session, and stores the raw run under `.bench/widgets/<timestamp>.json`
  (`--json` prints it, `--widgets id[,id]` narrows the run, `--hold` seconds)
- The systemd unit lives at `~/.config/systemd/user/yudaemond.service`
- QML talks to it through `quickshell/services/Yudae.qml`

Everything not on screen belongs here. The files under `src/providers/` each
own one source of state; `src/primitives/` holds the pieces used more than once.
