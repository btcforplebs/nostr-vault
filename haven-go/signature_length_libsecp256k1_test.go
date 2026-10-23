//go:build libsecp256k1

package main

import (
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

// The libsecp256k1 Sign hands &sk[0] to C, which reads 32 bytes: any other
// length must be refused before that, or it panics (empty) or reads past the
// slice (short).
func TestSignRejectsWrongKeyLengths(t *testing.T) {
	for _, sk := range []string{"", "01", nostr.GeneratePrivateKey()[:62], nostr.GeneratePrivateKey() + "00"} {
		evt := nostr.Event{Kind: 1, CreatedAt: nostr.Now()}
		if err := evt.Sign(sk); err == nil {
			t.Fatalf("Sign(%d hex chars): want an error", len(sk))
		}
	}
}
