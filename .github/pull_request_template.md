## Summary

<!-- What does this change do, and why? Link the issue it fixes, e.g. "Fixes #123". -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] New provider
- [ ] Docs only
- [ ] Refactor or internal change (no user-visible change)
- [ ] Build, CI or packaging

## Area

- [ ] Core daemon (`core/`)
- [ ] CLI (`pdrclone`)
- [ ] macOS app (`mac/`)
- [ ] Docs or landing page (`docs/`)
- [ ] Packaging (`packaging/`, `.github/`)

## How I tested it

<!-- Commands you ran, providers and OS versions you tested on. -->

## Checklist

- [ ] Tests added or updated, and `go test ./... -race` passes (for core changes)
- [ ] `swift build` and `scripts/build-app.sh` work (for app changes)
- [ ] Code is formatted (`gofmt`, `golangci-lint`, `swiftformat`)
- [ ] `docs/PROTOCOL.md` updated if the IPC protocol changed
- [ ] Help docs in `docs/help/` updated if behaviour changed
- [ ] Line added under `## [Unreleased]` in `CHANGELOG.md` (for user-visible changes)
- [ ] Screenshots in `docs/media/` updated if the UI changed
- [ ] No secrets, tokens or personal data in code, tests, logs or screenshots

## Screenshots

<!-- For UI changes: before and after, light and dark mode if they differ. -->
