//go:build cshared


package main

import (
	"context"
	"testing"

	"github.com/nbd-wtf/go-nostr/nip46"
)

// Signer audit 2026-11-05 #1: a request queued for account A must reach A's
// signer session even when bunker account B became the active one meanwhile.
func TestNIP46SessionForPicksTheNamedSessionNotTheActiveOne(t *testing.T) {
	ctxA, cancelA := context.WithCancel(context.Background())
	defer cancelA()
	ctxB, cancelB := context.WithCancel(context.Background())
	defer cancelB()
	a := &nip46Session{ctx: ctxA, cancel: cancelA, client: &nip46.BunkerClient{}}
	b := &nip46Session{ctx: ctxB, cancel: cancelB, client: &nip46.BunkerClient{}}

	nip46Mu.Lock()
	savedSessions, savedActive := nip46Sessions, nip46Active
	nip46Sessions = map[string]*nip46Session{"signer-a": a, "signer-b": b}
	nip46Active = "signer-b" // the person switched to B while A's request waited
	nip46Mu.Unlock()
	defer func() {
		nip46Mu.Lock()
		nip46Sessions, nip46Active = savedSessions, savedActive
		nip46Mu.Unlock()
	}()

	if got := nip46SessionFor("signer-a"); got != a {
		t.Fatalf("A's request went to %p, want A's session %p (active is B %p)", got, a, b)
	}
	if got := activeNIP46Session(); got != b {
		t.Fatalf("active session changed: %p", got)
	}
	if nip46SessionFor("") != nil || nip46SessionFor("signer-gone") != nil {
		t.Fatal("an unknown or empty key must not fall back to any session")
	}
	cancelA()
	if nip46SessionFor("signer-a") != nil {
		t.Fatal("a closed session must not be used")
	}
}

func TestNIP46CryptOpsCoverAllFour(t *testing.T) {
	for _, op := range []string{"nip44_encrypt", "nip44_decrypt", "nip04_encrypt", "nip04_decrypt"} {
		if _, ok := nip46CryptOps[op]; !ok {
			t.Fatalf("missing op %s", op)
		}
	}
	if len(nip46CryptOps) != 4 {
		t.Fatalf("unexpected ops: %d", len(nip46CryptOps))
	}
}
