package main

import (
	"encoding/base64"
	"net/http/httptest"
	"testing"
)

func TestNormalizeNostrAuthHeaderAcceptsAllBase64Forms(t *testing.T) {
	// Lengths 1..6 cover every padding remainder; "?>" bytes force - and _ in url form.
	for _, s := range []string{`{`, `{"k`, `{"ki`, `{"kin`, `{"kind`, `{"?>?>`} {
		raw := []byte(s)
		want := "Nostr " + base64.StdEncoding.EncodeToString(raw)
		for name, enc := range map[string]*base64.Encoding{
			"std": base64.StdEncoding, "rawstd": base64.RawStdEncoding,
			"url": base64.URLEncoding, "rawurl": base64.RawURLEncoding,
		} {
			r := httptest.NewRequest("PUT", "/upload", nil)
			r.Header.Set("Authorization", "Nostr "+enc.EncodeToString(raw)+" ")
			normalizeNostrAuthHeader(r)
			if got := r.Header.Get("Authorization"); got != want {
				t.Errorf("%s %q: got %q want %q", name, s, got, want)
			}
		}
	}
}

func TestNormalizeNostrAuthHeaderLeavesOthersAlone(t *testing.T) {
	for _, h := range []string{"", "Bearer abc", "Nostr !!!not base64"} {
		r := httptest.NewRequest("PUT", "/upload", nil)
		if h != "" {
			r.Header.Set("Authorization", h)
		}
		normalizeNostrAuthHeader(r)
		if got := r.Header.Get("Authorization"); got != h {
			t.Errorf("%q changed to %q", h, got)
		}
	}
}
