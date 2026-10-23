# Changelog

All notable changes to PigmentDev rClone are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.2] - 2026-10-23

### Added

- Setup wizard: pick several local folders at once; each becomes its own job, synced into its own subfolder of the chosen cloud folder.
- Google Drive "Computers" (folders backed up by Google Drive for desktop) can be browsed and used as a sync destination.
- Settings › Appearance: Glass or Flat window style, with a blur slider for Glass.
- Step-by-step guide with direct console links for creating your own Google, Microsoft or Dropbox OAuth client ID.

### Changed

- Adding a cloud account is now one step: sign in with the browser. All provider options moved under Advanced.
- Option help text has clickable links, empty fields show placeholders, and long help is folded behind "More".
- Glass surfaces are no longer tinted; the window background is the blurred desktop instead of coloured shapes.
- Releases are published as the latest release, so the download links always point to the newest build.

### Fixed

- The Homebrew cask now finds the `pdrclone` CLI inside the app.
- The background service is re-registered after an app update, so launchd starts the new daemon.
- Removing an account is now written to the log.

## [1.0.0-beta.1] - 2026-10-23

### Added

- macOS app (macOS 14+, Apple Silicon first) with a menu bar popover and a main window: Dashboard, Jobs, Accounts, Action Center, Logs and Settings. Liquid Glass on macOS 26+, translucent material fallback on 14 and 15.
- `pdrcloned` background daemon with rclone embedded as a Go library, running as a LaunchAgent on macOS, a systemd user unit on Linux and a service on Windows.
- `pdrclone` command-line tool for macOS, Linux and Windows: `status`, `job list|run|pause|resume|dry-run|resync`, `account list|add|test`, `logs -f`, `config export|import`, `daemon start|stop|install`, and `--json` output.
- Providers: Google Drive (including Shared Drives), OneDrive Personal, Business and SharePoint, Dropbox, Box, pCloud, S3-compatible storage, Backblaze B2, Azure Blob, Google Cloud Storage, SFTP, FTP/FTPS, WebDAV/Nextcloud, Mega, Proton Drive and local/NAS folders.
- In-app OAuth sign-in with rclone's default client IDs, and support for your own OAuth client ID and secret.
- Sync jobs with upload, download and two-way (rclone `bisync`) directions; mirror, archive (`.pdrclone-archive/<date>` with retention) and never-delete policies; conflict policies newer, keep both, prefer local, prefer remote and ask.
- Triggers: on change with debounce, every N minutes, daily, weekly, cron, on wake or login, and manual. Several triggers per job.
- Safety guards: dry-run preview before the first run, max-delete guard (default 25%), checksum compare, min-age skip, pre-flight checks, guided baseline for two-way jobs.
- Exclusion presets (VCS, IDE and agents, dependencies, build output, OS junk, caches, dot-folders, dot-files), custom rules, include overrides, `.nosync` marker, `.gitignore` support, live preview with "why excluded".
- Network and power rules: cellular and expensive networks, Wi-Fi allow and deny lists, Ethernet only, VPN toggle, bandwidth limits with a weekly timetable, TPS limit, battery and Low Power Mode rules, low disk space pause, proxy, offline queue.
- Action Center with Running, Needs attention, Waiting and Recent sections; notifications with quiet hours; searchable logs with export; "why didn't this file sync?"; redacted diagnostics bundle.
- Google Drive Dedupe tool for cleaning up `(1)` duplicates.
- First-run wizard, Shortcuts actions, and a `pdrclone://` URL scheme.
- Encrypted rclone config with its passphrase in the macOS Keychain (Secret Service on Linux, Credential Manager on Windows).
- Sparkle updates signed with the project's own EdDSA key; Homebrew cask and CLI formula.
- Documentation at https://pigment.dev/docs/rclone/.

[Unreleased]: https://github.com/pigment-dev/rclone/commits/main
