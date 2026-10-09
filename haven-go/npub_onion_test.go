//go:build !cshared

package main

import (
	"testing"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// A secret key pasted into an npub field must not be decoded into a "pubkey",
// and a bad value must not stop the embedded relay (it returns "" instead).
func TestNPubToPubkeyRejectsNonNpub(t *testing.T) {
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	npub, _ := nip19.EncodePublicKey(pk)
	nsec, _ := nip19.EncodePrivateKey(sk)

	if got := nPubToPubkey("TEST", npub); got != pk {
		t.Fatalf("valid npub: got %q, want %q", got, pk)
	}
	for name, v := range map[string]string{"nsec": nsec, "garbage": "npub1notreal", "empty": ""} {
		if got := nPubToPubkey("TEST", v); got != "" {
			t.Errorf("%s: got %q, want \"\"", name, got)
		}
	}
}

func TestRelaySchemesForOnion(t *testing.T) {
	saved := config
	t.Cleanup(func() { config = saved })

	config = Config{RelayURL: "abc.onion"}
	if got := relayServiceURL("/inbox"); got != "http://abc.onion/inbox" {
		t.Errorf("onion service URL = %q", got)
	}
	if got := getWSScheme(config.RelayURL); got != "ws://" {
		t.Errorf("onion ws scheme = %q", got)
	}

	config = Config{RelayURL: "relay.example.com"}
	if got := relayServiceURL("/inbox"); got != "https://relay.example.com/inbox" {
		t.Errorf("clearnet service URL = %q", got)
	}
	if got := getWSScheme(config.RelayURL); got != "wss://" {
		t.Errorf("clearnet ws scheme = %q", got)
	}

	for url, want := range map[string]bool{
		"abc.onion":               true,
		"abc.onion:8080":          true,
		"ABC.ONION/inbox":         true,
		"onion.example.com":       false,
		"relay.onion.example.com": false,
		"example.com/x.onion":     false,
	} {
		if got := isOnionHost(url); got != want {
			t.Errorf("isOnionHost(%q) = %v, want %v", url, got, want)
		}
	}
}
