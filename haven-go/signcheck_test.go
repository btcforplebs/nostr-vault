package main

import (
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

func signedBy(t *testing.T, sk string, req nostr.Event) nostr.Event {
	t.Helper()
	ev := req
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

func TestCheckRemoteSigned(t *testing.T) {
	skA, skB := nostr.GeneratePrivateKey(), nostr.GeneratePrivateKey()
	pkA, _ := nostr.GetPublicKey(skA)
	req := nostr.Event{
		PubKey: pkA, CreatedAt: 1790250000, Kind: 1,
		Tags:    nostr.Tags{{"t", "nostr"}, {"client", "Nostr Vault"}},
		Content: "tab\there \\ back \"quote\" ¯\\_(ツ)_/¯ \r\n émoji 🐝",
	}

	if err := checkRemoteSigned(req, signedBy(t, skA, req), pkA); err != nil {
		t.Fatalf("the correct signer must pass: %v", err)
	}

	cases := map[string]func() nostr.Event{
		"wrong account": func() nostr.Event { return signedBy(t, skB, req) },
		"content changed": func() nostr.Event {
			r := req
			r.Content += "!"
			return signedBy(t, skA, r)
		},
		"tag dropped": func() nostr.Event {
			r := req
			r.Tags = r.Tags[:1]
			return signedBy(t, skA, r)
		},
		"kind changed": func() nostr.Event {
			r := req
			r.Kind = 7
			return signedBy(t, skA, r)
		},
		"created_at changed": func() nostr.Event {
			r := req
			r.CreatedAt++
			return signedBy(t, skA, r)
		},
		"bad signature": func() nostr.Event {
			ev := signedBy(t, skA, req)
			ev.Sig = signedBy(t, skA, nostr.Event{Kind: 1, CreatedAt: 1}).Sig
			return ev
		},
	}
	for name, mk := range cases {
		if err := checkRemoteSigned(req, mk(), pkA); err == nil {
			t.Errorf("%s: accepted, must be rejected", name)
		}
	}
}
