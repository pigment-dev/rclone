package accounts

import (
	"crypto/rand"
)

const idAlphabet = "abcdefghijkmnpqrstuvwxyz23456789"

func randID() string { return RandID(8) }

// RandID returns n random lowercase alphanumeric characters.
func RandID(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = idAlphabet[int(b[i])%len(idAlphabet)]
	}
	return string(b)
}

// NewID returns a protocol id like "acc_x1y2z3".
func NewID(prefix string) string { return prefix + "_" + RandID(6) }
