// Package keyring stores the rclone.conf passphrase in the OS keyring
// (macOS Keychain, Windows Credential Manager, libsecret) with a 0600 file
// fallback for tests, demo mode and PDRCLONE_HOME setups.
package keyring

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	gokeyring "github.com/zalando/go-keyring"
)

// Service is the keyring service name.
const Service = "PigmentDev rClone"

const account = "rclone.conf"

// Source returns the passphrase, creating and storing a random one on first use.
type Source struct {
	// FileFallback forces the file backend at Dir/.conf-key.
	FileFallback bool
	Dir          string
}

// Passphrase returns the existing passphrase or generates a new one.
// The second return is a human description of where it lives.
func (s Source) Passphrase() (string, string, error) {
	if !s.FileFallback {
		pw, err := gokeyring.Get(Service, account)
		if err == nil && pw != "" {
			return pw, "os keyring", nil
		}
		if errors.Is(err, gokeyring.ErrNotFound) {
			if _, ferr := os.Stat(filepath.Join(s.Dir, ".conf-key")); ferr == nil {
				return s.fromFile() // previously fell back to the file
			}
			pw, err := random()
			if err != nil {
				return "", "", err
			}
			if err := gokeyring.Set(Service, account, pw); err == nil {
				return pw, "os keyring", nil
			}
			// Keyring unavailable (headless Linux without secret service).
			return s.fromFile()
		}
		// A transient keyring error must not mint a new key, or the existing
		// rclone.conf becomes unreadable. Only use an existing file key.
		if _, ferr := os.Stat(filepath.Join(s.Dir, ".conf-key")); ferr == nil {
			return s.fromFile()
		}
		if _, cerr := os.Stat(filepath.Join(s.Dir, "rclone.conf")); cerr == nil {
			return "", "", fmt.Errorf("os keyring unavailable: %w", err)
		}
	}
	return s.fromFile()
}

func (s Source) fromFile() (string, string, error) {
	p := filepath.Join(s.Dir, ".conf-key")
	if b, err := os.ReadFile(p); err == nil {
		if pw := strings.TrimSpace(string(b)); pw != "" {
			return pw, "file " + p, nil
		}
	}
	pw, err := random()
	if err != nil {
		return "", "", err
	}
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return "", "", err
	}
	if err := os.WriteFile(p, []byte(pw+"\n"), 0o600); err != nil {
		return "", "", fmt.Errorf("write key file: %w", err)
	}
	return pw, "file " + p, nil
}

func random() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
