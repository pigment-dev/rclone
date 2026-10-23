// Package version carries build-stamped version strings.
package version

// Version is overridden at build time with -ldflags "-X .../version.Version=1.2.3".
var Version = "0.1.0-dev"

// Commit is the git commit, stamped by goreleaser.
var Commit = "none"

// Protocol is the IPC protocol version.
const Protocol = 1
