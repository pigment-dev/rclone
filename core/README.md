# PigmentDev rClone core (`pdrcloned` + `pdrclone`)

The cross-platform Go core of PigmentDev rClone: a sync daemon that embeds
[rclone](https://rclone.org) v1.75 as a library, and a small CLI. The macOS app
(`../mac`) and the CLI talk to the daemon over a local socket using the
protocol in [`docs/PROTOCOL.md`](../docs/PROTOCOL.md).

```
cmd/pdrcloned     daemon: run | install | uninstall   (--socket --home --demo --log-level -v --memory-limit)
cmd/pdrclone      CLI: status, job, account, logs, config, daemon   (--json --socket --home)
internal/
  api        NDJSON JSON-RPC 2.0 server: hello gate, subscriptions, coalesced progress
  client     JSON-RPC client used by the CLI and tests
  ipc        unix socket (0600) / Windows named pipe (go-winio)
  paths      per-OS data dir + socket; PDRCLONE_HOME / PDRCLONE_SOCKET overrides
  config     jobs.json / accounts.json / settings.json (versioned, atomic writes)
  keyring    rclone.conf passphrase in the OS keyring (file fallback under PDRCLONE_HOME)
  engine     rclone in-process: sync/copy/bisync, preview, remote ops, log capture
  accounts   provider catalogue from rclone's registry, non-interactive config + OAuth
  filters    presets, custom rules, .gitignore, size/age, "why excluded"
  sched      interval / daily / weekly / cron next-run, backoff
  watch      fsnotify recursive watcher with excluded-dir pruning and debounce
  policy     network/power rules, bandwidth timetable
  store      SQLite (modernc, no cgo): runs, logs, actions; batched inserts, retention
  daemon     wiring: job state machine, queue, triggers, Action Center, RPC handlers
  demo       simulated engine + seed data for screenshots (--demo)
  platform   RSS, Linux self-detection, launchd/systemd/Task Scheduler install
  diag       log export and redacted diagnostics bundle
packaging/   LaunchAgent plist (SMAppService) and systemd user unit
```

## Build and test

Go 1.27+. No cgo is needed (`CGO_ENABLED=0` everywhere; `-race` needs cgo locally).

```sh
cd core
go build ./...
go vet ./...
go test -race ./...
# cross-compile
for t in darwin/arm64 darwin/amd64 linux/amd64 windows/amd64; do
  GOOS=${t%/*} GOARCH=${t#*/} CGO_ENABLED=0 go build ./...
done
```

Integration tests use rclone's `local` backend in short temp dirs (`os.MkdirTemp("", "pdr")`):
one-way mirror/never/archive, download, max-delete abort, the on-change fast path,
preview, two-way baseline + edits on both sides + conflict resolution, the long
bisync state-file guard, and an end-to-end JSON-RPC session over a real socket.

## Run

```sh
go run ./cmd/pdrcloned run -v                       # real daemon, default data dir
go run ./cmd/pdrcloned --demo --socket /tmp/pdr.sock  # demo mode (see below)
go run ./cmd/pdrclone --socket /tmp/pdr.sock status
```

Data dir: macOS `~/Library/Application Support/PigmentDev rClone/`, Linux
`~/.config/pdrclone/` + `~/.local/share/pdrclone/`, Windows `%APPDATA%\PigmentDev rClone\`.
`PDRCLONE_HOME` (or `--home`) puts everything, including the socket, in one folder
and stores the rclone.conf key in a 0600 file there instead of the keyring.

### Demo mode

`pdrcloned --demo` seeds four accounts (Google Drive "Work", Dropbox "Personal",
Cloudflare R2 "Backups", SFTP "NAS"), five jobs (running, idle, error, waiting
for Wi-Fi, needs baseline), ~30 log lines and three Action Center items
(conflict, sign-in expired, max-delete stop), and loops a simulated upload with
smoothly changing `job.progress` and `overall.progress`. It never touches the
network: the engine and account flow are simulated, the data dir is a fresh temp
folder (removed on exit) unless `--home` is given, and pushed `system.state`
is ignored so the "waiting" job stays put for screenshots.

### Service install

`pdrcloned install` writes `~/Library/LaunchAgents/com.pigmentdev.rclone.daemon.plist`
(macOS), a systemd user unit (Linux), or a logon task (Windows). The Mac app instead
registers `packaging/macos/com.pigmentdev.rclone.daemon.plist` with `SMAppService`
from `Contents/Library/LaunchAgents/` (BundleProgram `Contents/MacOS/pdrcloned`).

## How syncs map to rclone

| Job | rclone |
|---|---|
| upload / download, `mirror` | `sync` (dest mirrors source) |
| upload / download, `never` | `copy` |
| `archive` | `sync` with `--backup-dir <dest>/.pdrclone-archive/<date>`, pruned after `archiveRetentionDays` |
| two-way | `bisync --resilient --recover`, workdir `<data>/bisync/<jobId>` |
| conflict `newer` / `preferLocal` / `preferRemote` | `--conflict-resolve newer / path1 / path2` (loser kept with a suffix) |
| conflict `keepBoth` / `ask` | `--conflict-resolve none`; `ask` adds an Action Center item per file |
| on-change upload | `copy` of the changed paths only (`--files-from` equivalent), full reconcile every 6 h |

Filters are compiled into an rclone filter attached to the run context (custom rules
first, then `.gitignore`, then presets; `.pdrclone-archive` is always excluded).
One-way runs with deletes do a listing pre-flight and stop with a `maxDeleteAbort`
Action when more than `maxDeletePercent` of the destination would be deleted;
two-way runs use bisync's own `--max-delete`.

## Known limits

- Per-job bandwidth limits share rclone's process-wide token bucket: the tightest
  limit of the running jobs (and the timetable) applies to all of them.
- On macOS fsnotify uses kqueue (one descriptor per watched entry); trees with more
  than 4000 folders fall back to scheduled full runs. Remote change notifications
  (Drive/OneDrive/Dropbox ChangeNotify) are not wired yet.
- Log lines from rclone are attributed to a job only while a single run is active.
- Linux network/battery detection is best effort (`/proc/net/route`, `/sys/class/power_supply`);
  Windows does not self-detect and allows all runs.
