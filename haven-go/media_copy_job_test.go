//go:build !(js && wasm)

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

type copyKey struct{ sk, pk string }

func newCopyKey(t *testing.T) copyKey {
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	return copyKey{sk, pk}
}

// uploadAuth signs a kind 24242 upload auth naming xs, valid for life.
func (k copyKey) uploadAuth(t *testing.T, now time.Time, life time.Duration, xs ...string) string {
	tags := nostr.Tags{{"t", "upload"}, {"expiration", strconv.FormatInt(now.Add(life).Unix(), 10)}}
	for _, x := range xs {
		tags = append(tags, nostr.Tag{"x", x})
	}
	ev := nostr.Event{Kind: 24242, CreatedAt: nostr.Timestamp(now.Unix()), Tags: tags, Content: "Upload"}
	if err := ev.Sign(k.sk); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(ev)
	return base64.StdEncoding.EncodeToString(b)
}

func TestParseUploadAuth(t *testing.T) {
	now := time.Unix(2_000_000, 0)
	k, other := newCopyKey(t), newCopyKey(t)
	x := strings.Repeat("ab", 32)
	ok := k.uploadAuth(t, now, time.Hour, x)
	if _, xs, b64, err := parseUploadAuth(ok, k.pk, now); err != nil || len(xs) != 1 || b64 == "" {
		t.Fatalf("good auth: %v", err)
	}
	if _, _, _, err := parseUploadAuth("Nostr "+ok, k.pk, now); err != nil {
		t.Fatalf("with Nostr prefix: %v", err)
	}
	raw, _ := base64.StdEncoding.DecodeString(ok)
	if _, _, _, err := parseUploadAuth(string(raw), k.pk, now); err != nil {
		t.Fatalf("plain JSON: %v", err)
	}
	many := make([]string, mediaCopyFilesPerAuth+1)
	for i := range many {
		many[i] = fmt.Sprintf("%064x", i+1)
	}
	tampered := strings.Replace(string(raw), x, strings.Repeat("cd", 32), 1)
	for name, c := range map[string]struct {
		auth, pk string
	}{
		"other signer":   {other.uploadAuth(t, now, time.Hour, x), k.pk},
		"expired":        {k.uploadAuth(t, now, -time.Second, x), k.pk},
		"too long":       {k.uploadAuth(t, now, 3*time.Hour, x), k.pk},
		"names no files": {k.uploadAuth(t, now, time.Hour), k.pk},
		"too many files": {k.uploadAuth(t, now, time.Hour, many...), k.pk},
		"bad hash":       {k.uploadAuth(t, now, time.Hour, "nothex"), k.pk},
		"tampered":       {tampered, k.pk},
		"garbage":        {"!!!", k.pk},
	} {
		if _, _, _, err := parseUploadAuth(c.auth, c.pk, now); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

// fakeServer answers HEAD /<sha> from its set.
func fakeServer(t *testing.T, has ...string) *httptest.Server {
	set := map[string]bool{}
	for _, h := range has {
		set[h] = true
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead && set[strings.TrimPrefix(r.URL.Path, "/")] {
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// Check finds what each server lacks; copy sends only what a valid auth of
// the caller names, only to the servers that lack it, with that auth.
func TestMediaCopyCheckThenCopy(t *testing.T) {
	k := newCopyKey(t)
	now := time.Unix(2_000_000, 0)
	f1, f2, f3 := strings.Repeat("a1", 32), strings.Repeat("b2", 32), strings.Repeat("c3", 32)
	a := fakeServer(t, f1, f2, f3)
	b := fakeServer(t, f1)
	var mu sync.Mutex
	var sent []blobForward
	var saved []mediaCopyState
	d := mediaCopyDeps{
		client:   a.Client(),
		accounts: func() []string { return []string{k.pk} },
		servers:  func(context.Context, string) []string { return []string{a.URL, b.URL} },
		ownFiles: func(context.Context, string) (map[string]string, error) {
			return map[string]string{f1: "image/jpeg", f2: "video/mp4", f3: ""}, nil
		},
		upload: func(_ context.Context, f *blobForward) (bool, error) {
			mu.Lock()
			defer mu.Unlock()
			sent = append(sent, *f)
			return true, nil
		},
		now:  func() time.Time { return now },
		save: func(st mediaCopyState) { saved = append(saved, st) },
	}
	st := runMediaCopy(context.Background(), d, mediaCopyRequest{ID: "1", Action: "check", Pubkey: k.pk}, mediaCopyState{})
	if st.Error != "" || st.Checked != 3 || len(st.Files) != 2 || st.Files[0].SHA256 != f2 || st.Files[0].Absent[0] != b.URL || len(st.Files[0].Absent) != 1 {
		t.Fatalf("check: %+v", st)
	}
	if st.Running || saved[len(saved)-1].Running {
		t.Fatal("finished job still running")
	}
	// One auth names f2 and a file that is not this account's.
	auth := k.uploadAuth(t, now, time.Hour, f2, strings.Repeat("dd", 32))
	st = runMediaCopy(context.Background(), d, mediaCopyRequest{ID: "2", Action: "copy", Pubkey: k.pk, Auths: []string{auth}}, st)
	if st.Copied != 1 || st.Failed != 0 || len(sent) != 1 || sent[0].target != b.URL || sent[0].sha256 != f2 || sent[0].contentType != "video/mp4" {
		t.Fatalf("copy: %+v sent %+v", st, sent)
	}
	raw, _ := base64.StdEncoding.DecodeString(sent[0].authB64)
	var ev nostr.Event
	if json.Unmarshal(raw, &ev) != nil || ev.PubKey != k.pk {
		t.Fatal("the upload did not carry the caller's auth")
	}
	for _, f := range st.Files {
		if f.SHA256 == f3 && f.Status != "waiting" {
			t.Fatalf("f3 not named by any auth: %+v", f)
		}
	}
}

func TestMediaCopyRefusals(t *testing.T) {
	k, other := newCopyKey(t), newCopyKey(t)
	now := time.Unix(2_000_000, 0)
	f2 := strings.Repeat("b2", 32)
	srv := fakeServer(t)
	uploads := 0
	d := mediaCopyDeps{
		client:   srv.Client(),
		accounts: func() []string { return []string{k.pk} },
		servers:  func(context.Context, string) []string { return []string{srv.URL} },
		ownFiles: func(context.Context, string) (map[string]string, error) { return map[string]string{f2: ""}, nil },
		upload:   func(context.Context, *blobForward) (bool, error) { uploads++; return true, nil },
		now:      func() time.Time { return now },
		save:     func(mediaCopyState) {},
	}
	st := runMediaCopy(context.Background(), d, mediaCopyRequest{Action: "copy", Pubkey: other.pk, Auths: []string{other.uploadAuth(t, now, time.Hour, f2)}}, mediaCopyState{})
	if st.Error == "" || uploads != 0 {
		t.Fatalf("an account not signed in here: %+v", st)
	}
	st = runMediaCopy(context.Background(), d, mediaCopyRequest{Action: "copy", Pubkey: k.pk, Auths: []string{other.uploadAuth(t, now, time.Hour, f2)}}, mediaCopyState{})
	if !strings.Contains(st.Error, "no usable signature") || uploads != 0 {
		t.Fatalf("another account's auth: %+v", st)
	}
	// No check yet: the server is asked first, then sent.
	st = runMediaCopy(context.Background(), d, mediaCopyRequest{Action: "copy", Pubkey: k.pk, Auths: []string{k.uploadAuth(t, now, time.Hour, f2)}}, mediaCopyState{})
	if st.Copied != 1 || uploads != 1 {
		t.Fatalf("copy without a check: %+v", st)
	}
	// An upload the server refuses is failed with its reason.
	d.upload = func(context.Context, *blobForward) (bool, error) { return true, fmt.Errorf("HTTP 413") }
	st = runMediaCopy(context.Background(), d, mediaCopyRequest{Action: "copy", Pubkey: k.pk, Auths: []string{k.uploadAuth(t, now, time.Hour, f2)}}, mediaCopyState{})
	if st.Failed != 1 || st.Files[0].Reasons[srv.URL] != "HTTP 413" {
		t.Fatalf("refused: %+v", st)
	}
}
