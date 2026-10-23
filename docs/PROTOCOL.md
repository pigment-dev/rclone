# PigmentDev rClone — daemon IPC protocol (v1)

The daemon `pdrcloned` and every client (the macOS app, the `pdrclone` CLI) talk over one local socket using **newline-delimited JSON-RPC 2.0** (one JSON object per line, UTF-8, `\n` terminated).

## Transport

| OS | Endpoint |
|---|---|
| macOS | `~/Library/Application Support/PigmentDev rClone/daemon.sock` |
| Linux | `$XDG_RUNTIME_DIR/pdrclone/daemon.sock`, else `~/.local/state/pdrclone/daemon.sock` |
| Windows | named pipe `\\.\pipe\pdrclone-<username>` |

- Socket file mode `0600`, parent dir `0700`. Override with env `PDRCLONE_SOCKET` or flag `--socket`.
- Data dir (config, db, logs, bisync workdirs): macOS `~/Library/Application Support/PigmentDev rClone/`, Linux `~/.config/pdrclone/` (data in `~/.local/share/pdrclone/`), Windows `%APPDATA%\PigmentDev rClone\`. Override with env `PDRCLONE_HOME` (everything goes under it; used by tests and demo mode).
- First message from a client MUST be `hello`. The daemon rejects anything else with error `-32001`.

## Envelope

Request: `{"jsonrpc":"2.0","id":7,"method":"jobs.list","params":{}}`
Response: `{"jsonrpc":"2.0","id":7,"result":{...}}` or `{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"...","data":{...}}}`
Notification (daemon → client, no id): `{"jsonrpc":"2.0","method":"job.progress","params":{...}}`

Error codes: `-32700` parse, `-32601` method not found, `-32602` invalid params, `-32603` internal, `-32001` not authenticated / hello missing, `-32010` not found, `-32011` conflict (e.g. job already running), `-32012` provider/auth error, `-32013` blocked by policy.

All timestamps are RFC 3339 strings in UTC. All sizes are int64 bytes. IDs are short random strings (`job_8f3k2m`, `acc_x1y2z3`, `act_…`, `run_…`).

## Methods

### Session
- `hello` `{client:"mac|cli", version:"1.0.0"}` → `{daemonVersion, rcloneVersion, protocol:1, os, arch, dataDir, pid, startedAt}`
- `subscribe` `{topics:["job.state","job.progress","action.new","action.updated","log.line","daemon.health","transfer"]}` → `{ok:true}` (default after hello: everything except `log.line` and `transfer`)
- `daemon.info` → same as hello result + `{jobsRunning, uptimeSec, rssBytes, goroutines}`
- `daemon.shutdown` → `{ok:true}`

### System state (pushed by the macOS app; Linux/Windows daemon self-detects)
- `system.state` `{network:{status:"satisfied|unsatisfied", interface:"wifi|ethernet|cellular|other|none", expensive:bool, constrained:bool, ssid:"Home"|null, vpn:bool}, power:{onBattery:bool, batteryPercent:0-100|null, lowPowerMode:bool}, disk:{freeBytes:int}, sleeping:bool}` → `{ok:true}`. Daemon re-evaluates policy on every push.

### Accounts
- `accounts.providers` → `{providers:[Provider]}`
  `Provider = {id:"drive", name:"Google Drive", auth:"oauth|fields", category:"cloud|object|server|local", popular:bool, fields:[Field]}`
  `Field = {name, label, help, type:"string|password|bool|int|select", required:bool, default, options:[{value,label}], advanced:bool}`
  Providers shipped: `drive, onedrive, dropbox, box, pcloud, s3, b2, azureblob, gcs, sftp, ftp, webdav, mega, protondrive, local`.
- `accounts.list` → `{accounts:[Account]}`
  `Account = {id, provider, name, remote:"pd_acc_x1y2z3", status:"ok|needsAuth|error|unknown", error:null|string, createdAt, quota:null|{total,used,free,trashed}}`
- `accounts.add.start` `{provider, name, fields:{...}}` → `{state:"done", account:Account}` | `{state:"needsOAuth", sessionId, authUrl}` | `{state:"needsInput", sessionId, question:{name,label,help,type,options,default}}`
- `accounts.add.continue` `{sessionId, answer:any}` → same shape as start. For OAuth the daemon runs a loopback redirect server; the app opens `authUrl` in the browser and polls `continue` with `answer:null` until `done` or error.
- `accounts.add.cancel` `{sessionId}`
- `accounts.test` `{id}` → `{ok:bool, error?, latencyMs}`
- `accounts.quota` `{id}` → `{quota}`
- `accounts.rename` `{id, name}`, `accounts.remove` `{id, force:bool}` (error `-32011` when jobs use it unless force)

### Remote browsing
- `remote.list` `{accountId|null, path:"", dirsOnly:true}` (accountId null = local filesystem) → `{path, entries:[{name, path, isDir, size, modTime}]}`
- `remote.mkdir` `{accountId, path}`

### Jobs
`Job = {`
`  id, name, enabled:bool,`
`  localPath:"/Users/a/Projects",`
`  accountId, remotePath:"Backups/Projects",`
`  direction:"upload|download|twoWay",`
`  deletePolicy:"mirror|archive|never", archiveRetentionDays:30,`
`  conflictPolicy:"newer|keepBoth|preferLocal|preferRemote|ask",`
`  filters:{presets:["vcs","ide","deps","build","osjunk","caches","dotfolders","dotfiles"], rules:[{kind:"exclude|include", pattern:"*.log"}], maxSizeMB:null|int, minAgeSec:int, excludeIfPresent:[".nosync"], respectGitignore:bool, skipSymlinks:bool},`
`  triggers:{onChange:bool, debounceSec:10, intervalMin:null|int, daily:null|"09:30", weekly:null|{day:1-7,time:"09:30"}, cron:null|"0 */2 * * *", onWake:bool, manual:true},`
`  network:{allowCellular:bool, allowExpensive:bool, wifiOnly:bool, ssidAllow:[], ssidDeny:[], pauseOnBattery:bool, minBatteryPercent:null|int},`
`  limits:{bwUpKBps:null|int, bwDownKBps:null|int, transfers:4, checkers:8},`
`  safety:{maxDeletePercent:25, dryRunFirst:true, checksum:false},`
`  createdAt, updatedAt,`
`  status:JobStatus`
`}`
`JobStatus = {state:"idle|queued|running|paused|waiting|error|needsBaseline", reason:null|string, lastRun:null|RunSummary, nextRun:null|time, progress:null|Progress}`
`RunSummary = {id, startedAt, endedAt, ok:bool, error:null|string, bytes, files, deletes, conflicts, dryRun:bool}`
`Progress = {bytes, totalBytes, files, totalFiles, speed /*bytes/sec*/, eta /*sec|null*/, percent /*0-100 float*/, checks, totalChecks, errors, transferring:[{name, size, bytes, percent, speed}]}`

- `jobs.list` → `{jobs:[Job]}`
- `jobs.get` `{id}` → `{job}`
- `jobs.create` `{job:{…without id/status…}}` → `{job}` (validates paths, account exists; new two-way jobs start in `needsBaseline`)
- `jobs.update` `{id, patch:{…}}` → `{job}`
- `jobs.delete` `{id}`
- `jobs.run` `{id, dryRun:false, resync:false}` → `{runId}` (async; progress via notifications). `resync:true` performs the two-way baseline.
- `jobs.preview` `{id}|{job}` → `{runId}` then `job.preview` notification, or synchronous result `{adds:int, updates:int, deletes:int, excluded:int, bytes:int, sample:{adds:[path], updates:[path], deletes:[path], excluded:[{path, rule}]}}` (synchronous, timeout 120 s)
- `jobs.pause` `{id}` (stops current run, state `paused`, no triggers until resume), `jobs.resume` `{id}`, `jobs.cancel` `{id}` (stops current run only)
- `jobs.pauseAll` `{untilSec:null|int}` / `jobs.resumeAll`
- `jobs.explain` `{id, path}` → `{included:bool, rule:null|string}` (why is this file (not) synced)
- `jobs.history` `{id, limit:20}` → `{runs:[RunSummary]}`

### Action Center
`Action = {id, jobId|null, kind:"conflict|authExpired|maxDeleteAbort|error|quotaFull|permission|info", severity:"info|warning|error", title, message, path:null|string, createdAt, resolved:bool, choices:[{id:"keepLocal|keepRemote|keepBoth|retry|reconnect|runAnyway|dismiss", label}]}`
- `actions.list` `{includeResolved:false}` → `{actions:[Action]}`
- `actions.resolve` `{id, choice}` → `{action}`
- `actions.dismissAll`

### Logs
`LogLine = {ts, level:"debug|info|notice|warn|error", jobId|null, runId|null, msg, path:null|string}`
- `log.query` `{jobId?, level?, search?, since?, until?, limit:500, before?:ts}` → `{lines:[LogLine]}` (newest first)
- `log.export` `{jobId?, format:"text|json", dest:"/path/file"}` → `{path}`
- `diag.bundle` `{dest}` → `{path}` (zip, secrets redacted)

### Settings (daemon-side)
`Settings = {defaults:{direction, conflictPolicy, deletePolicy, debounceSec, minAgeSec, maxDeletePercent, dryRunFirst, presets:[...]}, network:{allowCellular, allowExpensive, bwSchedule:[{days:[1..7], from:"09:00", to:"18:00", upKBps, downKBps}], proxy:null|string}, logs:{level:"info", retentionDays:30}, engine:{transfers:4, checkers:8, tpsLimit:0}}`
- `settings.get` → `{settings}`, `settings.set` `{patch}` → `{settings}`

### Tools
- `tools.dedupe.scan` `{accountId, path}` → `{groups:[{name, files:[{id,path,size,modTime}]}]}` ; `tools.dedupe.apply` `{accountId, path, mode:"newest|largest|rename"}` → `{removed:int, renamed:int}`

## Notifications

- `job.state` `{jobId, status:JobStatus}` — on every state change.
- `job.progress` `{jobId, runId, progress:Progress}` — at most 4 Hz per job while running.
- `overall.progress` `{running:int, bytes, totalBytes, percent, speed, eta}` — at most 4 Hz, aggregate of all running jobs; drives the menu bar ring.
- `action.new` / `action.updated` `{action}`
- `log.line` `{line:LogLine}` (only if subscribed)
- `daemon.health` `{ok:bool, message}`

## Filter presets (canonical, daemon is source of truth; rclone filter syntax)

| id | rules |
|---|---|
| `vcs` | `- .git/**` `- .svn/**` `- .hg/**` `- .bzr/**` |
| `ide` | `- .vscode/**` `- .idea/**` `- .claude/**` `- .cursor/**` `- .fleet/**` `- .zed/**` |
| `deps` | `- node_modules/**` `- vendor/**` `- .venv/**` `- venv/**` `- __pycache__/**` `- .pnpm-store/**` `- Pods/**` |
| `build` | `- dist/**` `- build/**` `- target/**` `- .next/**` `- .nuxt/**` `- out/**` `- DerivedData/**` `- .build/**` |
| `osjunk` | `- .DS_Store` `- ._*` `- Thumbs.db` `- desktop.ini` `- .Spotlight-V100/**` `- .Trashes/**` `- .fseventsd/**` `- Icon\r` |
| `caches` | `- .cache/**` `- *.tmp` `- *.swp` `- *~` `- .sass-cache/**` |
| `dotfolders` | `- .*/**` |
| `dotfiles` | `- .*` |

Patterns without a leading `/` match at any depth (rclone semantics). Custom rules are applied **before** presets, so an `include` rule can override a preset. `.nosync` (default in `excludeIfPresent`) excludes the folder containing it.
