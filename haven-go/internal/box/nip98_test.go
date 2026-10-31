package box

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestOwnerAuth(t *testing.T) {
	owner := newTestKey(t)
	other := newTestKey(t)
	now := time.Unix(1_800_000_000, 0)
	const url = "http://box.lan:8080/api/box/status"
	const moveURL = "http://box.lan:8080/api/box/move"
	moveBody := []byte(`{"path":"/mnt/usb/vault"}`)

	type tc struct {
		name   string
		method string
		target string
		host   string
		body   []byte
		header string
		want   int // 0 = accepted
	}
	cases := []tc{
		{"owner GET", "GET", "/api/box/status", "box.lan:8080", nil, owner.authHeader(t, "GET", url, nil, now), 0},
		{"owner POST with payload", "POST", "/api/box/move", "box.lan:8080", moveBody, owner.authHeader(t, "POST", moveURL, moveBody, now), 0},
		{"host case and https scheme ignored", "GET", "/api/box/status", "BOX.lan:8080", nil, owner.authHeader(t, "GET", "https://box.lan:8080/api/box/status", nil, now), 0},
		{"no header", "GET", "/api/box/status", "box.lan:8080", nil, "", 401},
		{"not base64", "GET", "/api/box/status", "box.lan:8080", nil, "Nostr !!!", 401},
		{"other key", "GET", "/api/box/status", "box.lan:8080", nil, other.authHeader(t, "GET", url, nil, now), 403},
		{"too old", "GET", "/api/box/status", "box.lan:8080", nil, owner.authHeader(t, "GET", url, nil, now.Add(-61*time.Second)), 401},
		{"from the future", "GET", "/api/box/status", "box.lan:8080", nil, owner.authHeader(t, "GET", url, nil, now.Add(61*time.Second)), 401},
		{"wrong method", "POST", "/api/box/status", "box.lan:8080", nil, owner.authHeader(t, "GET", url, nil, now), 401},
		{"wrong path", "GET", "/api/box/storage", "box.lan:8080", nil, owner.authHeader(t, "GET", url, nil, now), 401},
		{"wrong host", "GET", "/api/box/status", "evil.lan:8080", nil, owner.authHeader(t, "GET", url, nil, now), 401},
		{"wrong port", "GET", "/api/box/status", "box.lan:9090", nil, owner.authHeader(t, "GET", url, nil, now), 401},
		{"query not signed", "GET", "/api/box/status?x=1", "box.lan:8080", nil, owner.authHeader(t, "GET", url, nil, now), 401},
		{"POST without payload", "POST", "/api/box/move", "box.lan:8080", moveBody, owner.authHeader(t, "POST", moveURL, nil, now), 401},
		{"POST empty body, no payload", "POST", "/api/box/update", "box.lan:8080", nil, owner.authHeader(t, "POST", "http://box.lan:8080/api/box/update", nil, now), 0},
		{"GET with unsigned body", "GET", "/api/box/status", "box.lan:8080", []byte("x"), owner.authHeader(t, "GET", url, nil, now), 401},
		{"POST body swapped", "POST", "/api/box/move", "box.lan:8080", []byte(`{"path":"/mnt/other"}`), owner.authHeader(t, "POST", moveURL, moveBody, now), 401},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a := NewOwnerAuth(owner.pk)
			a.Now = func() time.Time { return now }
			r := httptest.NewRequest(c.method, c.target, bytes.NewReader(c.body))
			r.Host = c.host
			if c.header != "" {
				r.Header.Set("Authorization", c.header)
			}
			body, err := a.Check(r)
			if c.want == 0 {
				if err != nil {
					t.Fatalf("want accepted, got %v", err)
				}
				if !bytes.Equal(body, c.body) && !(len(body) == 0 && len(c.body) == 0) {
					t.Fatalf("body %q, want %q", body, c.body)
				}
				return
			}
			ae, ok := err.(*AuthError)
			if !ok || ae.Status != c.want {
				t.Fatalf("want %d, got %v", c.want, err)
			}
		})
	}
}

func TestOwnerAuthWrongKindAndBadSig(t *testing.T) {
	owner := newTestKey(t)
	now := time.Now()
	a := NewOwnerAuth(owner.pk)
	h := owner.authHeader(t, "GET", "http://b/api/box/status", nil, now)
	raw, _ := base64.StdEncoding.DecodeString(strings.TrimPrefix(h, "Nostr "))
	// Flip the kind: the id/sig no longer match, and the kind is wrong.
	for _, mutated := range []string{
		strings.Replace(string(raw), `"kind":27235`, `"kind":1`, 1),
		strings.Replace(string(raw), `"method"`, `"methoD"`, 1),
	} {
		r := httptest.NewRequest("GET", "/api/box/status", nil)
		r.Host = "b"
		r.Header.Set("Authorization", "Nostr "+base64.StdEncoding.EncodeToString([]byte(mutated)))
		if _, err := a.Check(r); err == nil {
			t.Fatalf("mutated proof accepted: %s", mutated)
		}
	}
}

// A proof whose fields all pass but whose signature does not cover them.
func TestOwnerAuthTamperedSignatureRefused(t *testing.T) {
	owner := newTestKey(t)
	now := time.Now()
	h := owner.authHeader(t, "GET", "http://b/api/box/status", nil, now)
	raw, _ := base64.StdEncoding.DecodeString(strings.TrimPrefix(h, "Nostr "))
	var ev map[string]any
	json.Unmarshal(raw, &ev)
	ev["created_at"] = ev["created_at"].(float64) - 1
	tampered, _ := json.Marshal(ev)
	r := httptest.NewRequest("GET", "/api/box/status", nil)
	r.Host = "b"
	r.Header.Set("Authorization", "Nostr "+base64.StdEncoding.EncodeToString(tampered))
	if _, err := NewOwnerAuth(owner.pk).Check(r); err == nil || !strings.Contains(err.Error(), "signature") {
		t.Fatalf("tampered proof: %v", err)
	}
}

func TestOwnerAuthReplayRefused(t *testing.T) {
	owner := newTestKey(t)
	a := NewOwnerAuth(owner.pk)
	h := owner.authHeader(t, "GET", "http://b/api/box/status", nil, time.Now())
	try := func() error {
		r := httptest.NewRequest("GET", "/api/box/status", nil)
		r.Host = "b"
		r.Header.Set("Authorization", h)
		_, err := a.Check(r)
		return err
	}
	if err := try(); err != nil {
		t.Fatal(err)
	}
	if err := try(); err == nil || err.(*AuthError).Status != http.StatusUnauthorized {
		t.Fatalf("replay: want 401, got %v", err)
	}
}

func TestOwnerAuthBodyCap(t *testing.T) {
	owner := newTestKey(t)
	a := NewOwnerAuth(owner.pk)
	big := bytes.Repeat([]byte("a"), maxBodyBytes+1)
	r := httptest.NewRequest("POST", "/api/box/move", bytes.NewReader(big))
	r.Host = "b"
	r.Header.Set("Authorization", owner.authHeader(t, "POST", "http://b/api/box/move", big, time.Now()))
	if _, err := a.Check(r); err == nil || err.(*AuthError).Status != http.StatusRequestEntityTooLarge {
		t.Fatalf("want 413, got %v", err)
	}
}

// Tron, PR 1407: the signature does not cover the id as sent, so a replay
// under a rewritten id must be refused by the id check, not slip past the
// replay cache.
func TestOwnerAuthReplayWithRewrittenIDRefused(t *testing.T) {
	owner := newTestKey(t)
	a := NewOwnerAuth(owner.pk)
	h := owner.authHeader(t, "POST", "http://b/api/box/update", nil, time.Now())
	try := func(header string) error {
		r := httptest.NewRequest("POST", "/api/box/update", nil)
		r.Host = "b"
		r.Header.Set("Authorization", header)
		_, err := a.Check(r)
		return err
	}
	if err := try(h); err != nil {
		t.Fatal(err)
	}
	raw, _ := base64.StdEncoding.DecodeString(strings.TrimPrefix(h, "Nostr "))
	for i := 0; i < 5; i++ {
		var ev map[string]any
		json.Unmarshal(raw, &ev)
		ev["id"] = strings.Repeat(string("0123456789"[i]), 64)
		forged, _ := json.Marshal(ev)
		err := try("Nostr " + base64.StdEncoding.EncodeToString(forged))
		if err == nil || err.(*AuthError).Status != http.StatusUnauthorized || !strings.Contains(err.Error(), "id") {
			t.Fatalf("replay %d with rewritten id: want 401 on the id, got %v", i, err)
		}
	}
}
