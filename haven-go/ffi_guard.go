package main

import (
	"encoding/hex"
	"fmt"
	"log/slog"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
)

// validSecretKeyHex: 32 bytes of hex, 1 <= k < n.
func validSecretKeyHex(sk string) bool {
	b, err := hex.DecodeString(sk)
	if err != nil || len(b) != 32 {
		return false
	}
	var k secp256k1.ModNScalar
	overflow := k.SetByteSlice(b)
	return !overflow && !k.IsZero()
}

// recoverExport stops a panic at the export, which then returns its zero
// value (nil). Use with a named result: defer recoverExport("Name").
func recoverExport(name string) {
	if r := recover(); r != nil {
		slog.Error(name+": recovered from panic", "panic", fmt.Sprint(r))
	}
}
