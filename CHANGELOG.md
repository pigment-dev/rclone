# Changelog

All notable changes to PigmentDev rClone are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.7] - 2026-10-27

### Fixed

- Folder-by-folder runs: the top level is synced last, and its deletion guard is measured against the whole job. In beta.6 a folder removed or renamed on this Mac could stop a large job with "too many deletes" because the guard only counted the top level.
- Progress labels read "Folder 3 of 42 · name" and "Last part · files at the top level".

## [1.0.0-beta.6] - 2026-10-27

### Changed

- Large jobs sync one top-level folder at a time. Files at the top level go first, then each folder in turn, so transfers start right away instead of after the whole tree has been compared, and one slow or failing folder doesn't hold up the rest. Jobs with rules anchored to the job root ("/name/…") still run as one piece.
- Progress shows which part is running ("Folder 3 of 42 · hesabyar") and says "Comparing this Mac with the cloud…" while both sides are being listed, instead of "0 B · 0 files".
- The deletion guard checks each folder on its own; in folder-by-folder runs a folder needs more than 20 deletions before the guard can stop the run.

## [1.0.0-beta.5] - 2026-10-23

### Fixed

- The cloud folder picker now syncs into the folder you open. Before, a job could silently point at the top level of the storage if "Use" wasn't clicked, and a mirror job would then plan to delete everything else there.
- Google Drive "Computers" (e.g. "My Mac") load reliably: they are found with a much faster search that runs in the background and is cached, and a computer can be opened from its drive.google.com link.
- After an update, an outdated sync service is restarted automatically.
- The window content no longer spills past the window edge; the sidebar stays visible.
- The menu bar popover shows up to three and a half jobs and says "Checking for changes…" instead of "0 B of 0 B".

### Added

- Preview: an "If you create this job" summary that explains what will be uploaded, deleted or archived and what happens on later syncs, plus a warning when the top level of the storage is selected. Creating a job that deletes or archives files needs a confirmation.
- Deletion settings explain what Mirror, Archive and Never mean for the chosen direction.
- Skipped files show the reason in plain words (e.g. "OS junk · custom folder icon").
- Job page: click "This Mac" to show it in Finder and "Cloud" to open the folder in the browser (Google Drive opens the exact folder).

### Changed

- Job settings moved into an Edit window; the job page shows Overview and History. Overview tiles open the matching settings.
- Text fields, search fields and dropdowns share one shape.

## [1.0.0-beta.4] - 2026-10-23

### Added

- Status bar at the bottom of the window: sync service state and versions, the current activity with a progress bar, speed and time left.
- Account cards show the signed-in name and email (Google Drive, OneDrive, Dropbox, Box), so several accounts of the same provider are easy to tell apart. The setup wizard shows the email too.
- Storage usage loads automatically for new accounts.

### Changed

- Adding an account: Sign in and Advanced are separate tabs, the sign-in button is always at the bottom, and rarely used rclone options are folded under "All rclone options".
- "Refresh storage" is now "Refresh account info" and also updates the signed-in user.
- The menu bar popover closes when it opens the main window, Settings or the setup wizard.
- The sidebar no longer has a footer; its information moved to the status bar.

## [1.0.0-beta.3] - 2026-10-23

### Added

- Settings › Advanced › rclone: shows the built-in and command-line rclone versions, checks for new rclone releases, and updates or installs the command-line rclone with Homebrew.

### Changed

- rclone updated to v1.75.2.
- Smaller sidebar icons with more room before the titles.
- The app is English only; the language setting is removed.
- The CLI Homebrew formula is now `pigment-dev/cli/pdrclone`.

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
