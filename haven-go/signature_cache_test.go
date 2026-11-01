package main

import (
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

// CheckSignature remembers what already verified (go-nostr sigcache.go) so a
// note sent by several relays is checked once. None of that may let a new
// event through. Run with and without -tags libsecp256k1.

func sigCacheNote(t *testing.T, content string) (nostr.Event, string) {
	t.Helper()
	sk := nostr.GeneratePrivateKey()
	evt := nostr.Event{Kind: 1, Content: content, CreatedAt: nostr.Now(), Tags: nostr.Tags{}}
	if err := evt.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return evt, sk
}

func mustVerify(t *testing.T, e nostr.Event, want bool, what string) {
	t.Helper()
	ok, _ := e.CheckSignature()
	if ok != want {
		t.Fatalf("%s: CheckSignature = %v, want %v", what, ok, want)
	}
}

func TestSigCacheRepeatIsAHit(t *testing.T) {
	nostr.ResetSigCache()
	evt, _ := sigCacheNote(t, "hello")
	mustVerify(t, evt, true, "first copy")
	mustVerify(t, evt, true, "second relay's copy")
	mustVerify(t, evt, true, "local relay re-check")
	if hits, misses := nostr.SigCacheStats(); hits != 2 || misses != 1 {
		t.Fatalf("hits=%d misses=%d, want 2 and 1", hits, misses)
	}
}

func TestSigCacheNeverPassesAChangedEvent(t *testing.T) {
	nostr.ResetSigCache()
	evt, _ := sigCacheNote(t, "original")
	other, _ := sigCacheNote(t, "someone else")
	mustVerify(t, evt, true, "original")
	mustVerify(t, other, true, "other")

	cases := map[string]func(e *nostr.Event){
		// The claimed id is kept: a cache keyed on it would pass these.
		"content, same claimed id": func(e *nostr.Event) { e.Content = "forged" },
		"tags, same claimed id":    func(e *nostr.Event) { e.Tags = nostr.Tags{{"p", other.PubKey}} },
		"created_at":               func(e *nostr.Event) { e.CreatedAt++ },
		"kind":                     func(e *nostr.Event) { e.Kind = 7 },
		"pubkey swapped":           func(e *nostr.Event) { e.PubKey = other.PubKey },
		"sig from another event":   func(e *nostr.Event) { e.Sig = other.Sig },
		"sig with one byte off":    func(e *nostr.Event) { e.Sig = sigCacheFlip(e.Sig, 10) },
		"sig last nibble off":      func(e *nostr.Event) { e.Sig = sigCacheFlip(e.Sig, 127) },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			e := evt
			mutate(&e)
			mustVerify(t, e, false, name)
			mustVerify(t, e, false, name+" (again)")
			mustVerify(t, evt, true, "original still valid after "+name)
		})
	}
}

func TestSigCacheDoesNotRememberFailures(t *testing.T) {
	nostr.ResetSigCache()
	evt, _ := sigCacheNote(t, "x")
	bad := evt
	bad.Sig = sigCacheFlip(bad.Sig, 0)
	mustVerify(t, bad, false, "bad sig")
	mustVerify(t, bad, false, "bad sig again")
	if hits, misses := nostr.SigCacheStats(); hits != 0 || misses != 2 {
		t.Fatalf("hits=%d misses=%d, want 0 and 2: a failure must be re-verified, never cached", hits, misses)
	}
}

func sigCacheFlip(s string, i int) string {
	b := []byte(s)
	if b[i] == '0' {
		b[i] = '1'
	} else {
		b[i] = '0'
	}
	return string(b)
}
