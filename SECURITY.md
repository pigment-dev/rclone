# Security Policy

PigmentDev rClone handles credentials for your cloud accounts and has access to your files, so we take security reports seriously. This page explains which versions get fixes, how to report a problem privately, and what is in scope.

## Supported versions

The project is in beta. Security fixes go into the latest release only.

| Version | Supported |
|---|---|
| Latest `1.0.0-beta.x` | Yes |
| Older betas | No, please update |

Once 1.0.0 is released, the latest minor release line will receive security fixes.

## Reporting a vulnerability

Please **do not** open a public issue, Discussion or pull request for a security problem.

Report it privately in one of these ways:

1. **GitHub Security Advisories (preferred):** go to the [Security tab of pigment-dev/rclone](https://github.com/pigment-dev/rclone/security) and click **Report a vulnerability**.
2. **Email:** support@pigment.dev, with "Security" in the subject line.

Please include:

- the affected version (and macOS, Linux or Windows version),
- a description of the problem and its impact,
- steps to reproduce, or a proof of concept,
- any ideas you have for a fix.

Do not include real tokens, passwords or private files. If you need to show a secret, use a test account and revoke it afterwards.

## What to expect

We are a small team, so these are targets rather than promises:

- We aim to acknowledge your report within a few working days.
- We aim to give a first assessment within about two weeks.
- We will keep you updated while we work on a fix, and agree a disclosure date with you.
- With your permission, we will credit you in the advisory and the changelog.

## Scope

In scope:

- **The daemon socket and IPC.** The local Unix socket (or Windows named pipe), its file permissions, the hello and session token handshake, and anything that lets another local user or process control the daemon or read its data.
- **Credential storage.** The encrypted `rclone.conf`, the passphrase in the macOS Keychain, Linux Secret Service or Windows Credential Manager, and any path where secrets could end up in logs, exports or the diagnostics bundle.
- **The update channel.** The Sparkle appcast, the EdDSA update signatures, and the release artifacts and checksums published on GitHub.
- **OAuth handling.** The loopback redirect listener and token exchange.
- **Path handling.** Anything that makes a job read or write outside its configured folders, or follow links in an unsafe way.
- **The Homebrew cask and formula** in `packaging/homebrew/`.

Out of scope:

- Problems in rclone itself. Please report those to the [rclone project](https://github.com/rclone/rclone/security). If an rclone issue affects this app, tell us too so we can update.
- Problems at the storage providers.
- The fact that builds are currently unsigned by Apple. This is known and documented.
- Attacks that need an attacker who already has full control of your user account or root access.
- Denial of service through very large file trees, unless it leads to data loss.

## Safe harbour

We will not take legal action against people who report in good faith, follow this policy, avoid privacy violations and data destruction, and give us reasonable time to fix the problem before disclosure.
