# Contributing to PigmentDev rClone

Thanks for your interest in helping. PigmentDev rClone is a free, open-source (MIT) sync app for macOS, with a cross-platform daemon and CLI. It is powered by rclone, embedded as a Go library, and is not affiliated with the rclone project. This guide explains how to set up a development machine, how the repository is laid out, and how to send changes.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE). There is no CLA and no DCO sign-off requirement.

## Ways to help

- Report bugs with a diagnostics bundle (see https://pigment.dev/kb-topic/rclone/).
- Request a provider or a feature using the issue forms.
- Improve the docs in `docs/help/`. Small fixes are very welcome.
- Pick up an issue labelled `good first issue` or `help wanted`.
- Translate the app (String Catalog in `mac/Resources/Localizable.xcstrings`).

For larger changes, please open an issue or a Discussion first so we can agree on the approach before you spend time on it.

## Development setup

### Requirements

| Tool | Version | Notes |
|---|---|---|
| macOS | 26 or later recommended | The app's deployment target is macOS 14, but building needs the macOS 26 SDK for Liquid Glass. |
| Xcode | 26 or later (macOS 26 SDK) | Command line tools are enough for `swift build`; Xcode is useful for debugging. |
| Go | 1.27 or later | `brew install go` |
| golangci-lint | recent | `brew install golangci-lint` |
| swiftformat | recent | `brew install swiftformat` |
| GoReleaser, create-dmg | optional | Only for building release artifacts locally: `brew install goreleaser create-dmg` |
| Docker | optional | Integration tests start a MinIO container. |

Linux and Windows contributors can work on `core/` without any Apple tools.

### Build and test the core

```sh
cd core
go build ./cmd/...
go test ./... -race
```

This builds `pdrcloned` (the daemon) and `pdrclone` (the CLI). To run a daemon against a throwaway data folder, so it does not touch your real setup:

```sh
PDRCLONE_HOME="$(mktemp -d)" go run ./cmd/pdrcloned
```

Point the CLI at the same folder with the same `PDRCLONE_HOME` value.

### Build the Mac app

```sh
cd mac
scripts/build-app.sh
```

The script builds the Swift package, builds and embeds the daemon into `Contents/MacOS`, ad-hoc signs the bundle, and writes it to `mac/dist/`. Open the result with `open "dist/PigmentDev rClone.app"`.

For quick iterations on Swift code, `swift build` inside `mac/` is enough. The app needs a running daemon; the build script's embedded one is used by default.

## Repository layout

```text
rclone/
├─ README.md  LICENSE  CHANGELOG.md  CONTRIBUTING.md  SECURITY.md  CODE_OF_CONDUCT.md
├─ VERSION                    # single version shared by Go and Swift builds
├─ .github/
│  ├─ workflows/              # ci.yml, release-mac.yml, release-daemon.yml, pages.yml
│  └─ ISSUE_TEMPLATE/         # bug, feature and provider request forms
├─ core/                      # Go module github.com/pigment-dev/rclone/core
│  ├─ cmd/pdrcloned  cmd/pdrclone
│  ├─ internal/{api,config,accounts,jobs,engine,watch,sched,policy,store,platform,filters,dedupe,diag}
│  ├─ backends.go             # explicit rclone backend imports
│  ├─ .goreleaser.yaml        # Windows/Linux/macOS archives, deb/rpm, systemd unit
│  └─ testdata/
├─ mac/                       # SwiftPM package for the macOS app
│  ├─ Package.swift
│  ├─ Sources/PigmentDevRClone/{App,MenuBar,Windows,Wizard,Jobs,Accounts,ActionCenter,Logs,Settings,Glass,DaemonClient,Intents,Updater}
│  ├─ Resources/              # Info.plist, entitlements, app icon, Localizable.xcstrings
│  ├─ Tests/
│  └─ scripts/                # build-app.sh, make-dmg.sh, make-icon.swift, release-key.swift, embed-daemon.sh
├─ brand/                     # logo sources
├─ packaging/homebrew/        # cask and formula sources for the tap
└─ docs/                      # GitHub Pages site, help pages, media, protocol
   ├─ PROTOCOL.md             # daemon IPC protocol (source of truth for the API)
   ├─ help/                   # user documentation
   └─ media/                  # screenshots and demo video
```

The daemon is the source of truth for jobs, filters and policy. The Mac app is presentation plus macOS integration (Keychain, network path, Wi-Fi name, notifications, login item, Shortcuts). If a change needs new data from the daemon, update `docs/PROTOCOL.md` in the same pull request.

## Coding style

### Go

- Format with `gofmt` (or `goimports`). CI fails on unformatted code.
- Lint with `golangci-lint run ./...` from `core/`.
- Keep packages under `internal/`. Exported API surface lives in the JSON-RPC protocol, not in Go packages.
- Never log secrets. Use the redaction helpers for anything that could contain a token, password or key.
- New behaviour needs tests. Prefer table-driven tests; use the `local` backend or MinIO for integration tests.

### Swift

- Format with `swiftformat .` from `mac/`. CI runs `swiftformat --lint`.
- SwiftUI with `@Observable` stores. Keep the views thin; logic that talks to the daemon goes through `DaemonClient`.
- Glass effects go through the shared `pdGlass()` modifier so that macOS 14 and 15 get the material fallback.
- Every user-facing string goes through the String Catalog.
- Add VoiceOver labels to custom controls.

### Docs

- Plain, short sentences. Say what something does, and be honest about limits.
- Help pages are GitHub-flavoured Markdown in `docs/help/`, with relative links between pages.
- Screenshots and demo media go in `docs/media/`. PNGs should be 400 KB or smaller. Capture both light and dark mode when the screen looks different. If your change alters the UI, update the matching screenshots in the same pull request.

## Commits and pull requests

- Branch from `main`. Keep each pull request focused on one change.
- Write commit messages in the imperative: "Add pCloud quota", "Fix debounce for renames". A short body explaining why is welcome.
- Conventional Commit prefixes (`feat:`, `fix:`, `docs:`) are fine but not required.
- Fill in the pull request template. In particular:
  - tests added or updated, and `go test ./... -race` passes,
  - docs updated if behaviour changed,
  - a line added under `## [Unreleased]` in `CHANGELOG.md` for user-visible changes,
  - screenshots in `docs/media/` refreshed if the UI changed.
- CI must be green before review. A maintainer will review as soon as they can.

## Adding a provider

rclone supports many more backends than the app ships. To add one:

1. Open a provider request issue first, so we can check that the backend is stable and that its auth flow fits the app.
2. Add the backend import to `core/backends.go`. Only import what is used; this keeps the binary and memory use small.
3. Add the provider to the catalogue in `core/internal/accounts` (id, display name, auth kind `oauth` or `fields`, category, field definitions). Mark rarely used fields as advanced.
4. If the provider has special rules (name restrictions, case sensitivity, hash support, change notifications), handle them in the engine and add tests.
5. Add an icon for the provider picker in the Mac app.
6. Add a section to `docs/help/accounts.md` and update the provider list in `README.md` and `docs/PROTOCOL.md`.
7. Test add, test connection, a one-way sync and a two-way sync against a real account, and describe what you tested in the pull request.

## Reporting security issues

Do not open public issues for security problems. See [SECURITY.md](SECURITY.md).

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be kind and assume good intent.
