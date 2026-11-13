package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/blossom"
	"github.com/nbd-wtf/go-nostr"
)

// barrydeen/haven#138 end to end: real khatru blossom (it decodes the token
// with StdEncoding only) behind normalizeNostrAuthHeader, as dynamicRelayHandler
// wires it. HEAD /upload is BUD-06's check: 200 when the token is good.
func TestBlossomUploadCheckAcceptsBUD11Tokens(t *testing.T) {
	relay := khatru.NewRelay()
	blossom.New(relay, "https://vault.example")
	normalized := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		normalizeNostrAuthHeader(r)
		relay.ServeHTTP(w, r)
	}))
	t.Cleanup(normalized.Close)
	bare := httptest.NewServer(relay)
	t.Cleanup(bare.Close)

	sk := nostr.GeneratePrivateKey()
	raw := uploadAuthJSON(t, sk, 24242, time.Now().Add(time.Hour), func(s string) bool {
		// Unpadded and with - or _ in url form, so StdEncoding alone must fail.
		return len(s)%3 != 0 && strings.ContainsAny(base64.RawURLEncoding.EncodeToString([]byte(s)), "-_")
	})

	check := func(base, token string) int {
		t.Helper()
		req, _ := http.NewRequest(http.MethodHead, base+"/upload", nil)
		req.Header.Set("Authorization", "Nostr "+token)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}

	// Control: without the rewrite, khatru refuses the BUD-11 form (the bug).
	if got := check(bare.URL, base64.RawURLEncoding.EncodeToString(raw)); got != 400 {
		t.Fatalf("bare khatru, unpadded base64url: got %d, want 400 (bug no longer reproduces?)", got)
	}

	for name, enc := range map[string]*base64.Encoding{
		"unpadded base64url": base64.RawURLEncoding, "padded base64url": base64.URLEncoding,
		"padded std": base64.StdEncoding, "unpadded std": base64.RawStdEncoding,
	} {
		if got := check(normalized.URL, enc.EncodeToString(raw)+" "); got != 200 {
			t.Errorf("%s: got %d, want 200", name, got)
		}
	}

	// Still refused: the signature, kind and expiry checks are khatru's, unchanged.
	badSig := map[string]any{}
	if err := json.Unmarshal(raw, &badSig); err != nil {
		t.Fatal(err)
	}
	sig := []byte(badSig["sig"].(string))
	sig[0] ^= 1
	badSig["sig"] = string(sig)
	badSigJSON, _ := json.Marshal(badSig)
	any := func(string) bool { return true }
	for name, token := range map[string]string{
		"garbage":       "!!!not-base64!!!",
		"not an event":  base64.RawURLEncoding.EncodeToString([]byte(`{"kind":24242}`)),
		"bad signature": base64.RawURLEncoding.EncodeToString(badSigJSON),
		"wrong kind":    base64.RawURLEncoding.EncodeToString(uploadAuthJSON(t, sk, 1, time.Now().Add(time.Hour), any)),
		"expired":       base64.RawURLEncoding.EncodeToString(uploadAuthJSON(t, sk, 24242, time.Now().Add(-time.Hour), any)),
	} {
		if got := check(normalized.URL, token); got != 400 {
			t.Errorf("%s: got %d, want 400", name, got)
		}
	}
}

// uploadAuthJSON signs an "upload" auth event, padding its content until the
// JSON satisfies want.
func uploadAuthJSON(t *testing.T, sk string, kind int, expires time.Time, want func(string) bool) []byte {
	t.Helper()
	for i := 0; i < 200; i++ {
		ev := nostr.Event{
			Kind: kind, CreatedAt: nostr.Now(), Content: "Upload " + strings.Repeat("?", i),
			Tags: nostr.Tags{{"t", "upload"}, {"expiration", strconv.FormatInt(expires.Unix(), 10)}},
		}
		if err := ev.Sign(sk); err != nil {
			t.Fatal(err)
		}
		raw, _ := json.Marshal(ev)
		if want(string(raw)) {
			return raw
		}
	}
	t.Fatal("no event JSON matched")
	return nil
}
