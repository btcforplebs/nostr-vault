package main

import (
	"strings"
	"testing"

	"github.com/nbd-wtf/go-nostr/nip04"
)

func TestValidSecretKeyHex(t *testing.T) {
	n := "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"
	for _, bad := range []string{"", "00", strings.Repeat("0", 64), n, strings.Repeat("f", 64), strings.Repeat("g", 64), strings.Repeat("1", 63)} {
		if validSecretKeyHex(bad) {
			t.Errorf("accepted %q", bad)
		}
	}
	for _, good := range []string{strings.Repeat("0", 63) + "1", "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140", strings.Repeat("ab", 32)} {
		if !validSecretKeyHex(good) {
			t.Errorf("refused %q", good)
		}
	}
}

func TestRecoverExportStopsPanic(t *testing.T) {
	got := func() (out *int) {
		defer recoverExport("test")
		var m map[string]int
		m["x"] = 1 // panics
		v := 1
		return &v
	}()
	if got != nil {
		t.Fatalf("want nil result after a panic, got %v", *got)
	}
}

// A kind-4 DM or bunker reply from anyone reaches nip04.Decrypt; these
// payloads made it panic, which ends the app in the c-shared build.
func TestNIP04DecryptRefusesMalformedPayload(t *testing.T) {
	key := make([]byte, 32)
	for _, content := range []string{
		"AAAA?iv=AAAA",                                         // IV 3 bytes
		"AAAA?iv=AAAAAAAAAAAAAAAAAAAAAA==",                     // ciphertext 3 bytes
		"?iv=AAAAAAAAAAAAAAAAAAAAAA==",                         // empty ciphertext
		"AAAAAAAAAAAAAAAAAAAAAA==?iv=AAAAAAAAAAAAAAAAAAAAAA==", // one block, bad padding
	} {
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("Decrypt(%q) panicked: %v", content, r)
				}
			}()
			if _, err := nip04.Decrypt(content, key); err == nil {
				t.Errorf("Decrypt(%q) gave no error", content)
			}
		}()
	}
	// A real round trip still works.
	enc, err := nip04.Encrypt("hello ✨", key)
	if err != nil {
		t.Fatal(err)
	}
	if dec, err := nip04.Decrypt(enc, key); err != nil || dec != "hello ✨" {
		t.Fatalf("round trip: %q %v", dec, err)
	}
}
