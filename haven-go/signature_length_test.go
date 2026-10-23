package main

import (
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

// A pubkey or sig of the wrong length must be rejected with an error, never a
// panic. khatru checks signatures in a goroutine with no recover, so a panic
// here kills the app. Run with and without -tags libsecp256k1 (PR #1147).
func TestCheckSignatureRejectsWrongLengths(t *testing.T) {
	good := nostr.GeneratePrivateKey()
	evt := nostr.Event{Kind: 1, Content: "x", CreatedAt: nostr.Now()}
	if err := evt.Sign(good); err != nil {
		t.Fatal(err)
	}
	if ok, err := evt.CheckSignature(); !ok || err != nil {
		t.Fatalf("valid event: ok=%v err=%v", ok, err)
	}

	cases := map[string]func(e *nostr.Event){
		"long pubkey":  func(e *nostr.Event) { e.PubKey += "00" },
		"short pubkey": func(e *nostr.Event) { e.PubKey = e.PubKey[:62] },
		"long sig":     func(e *nostr.Event) { e.Sig += "00" },
		"short sig":    func(e *nostr.Event) { e.Sig = e.Sig[:126] },
		"empty both":   func(e *nostr.Event) { e.PubKey, e.Sig = "", "" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			e := evt
			mutate(&e)
			e.ID = e.GetID() // a hostile sender computes a matching ID
			if !e.CheckID() {
				t.Fatal("ID should match")
			}
			if ok, err := e.CheckSignature(); ok || err == nil {
				t.Fatalf("want an error, got ok=%v err=%v", ok, err)
			}
		})
	}
}
