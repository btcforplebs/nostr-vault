//go:build !(js && wasm)

package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/barrydeen/haven/pkg/trustrank"
)

// A catch-up cut off after its first steps (a phone leaving the app closes
// its mesh link) still leaves the phone with the Haven's trust rank: it is
// fetched before the deletes, notes and files (LogePhone, 2026-11-23: two
// cut runs, no rank all day).
func TestCopyCatchUpTakesTheTrustRankBeforeItIsCut(t *testing.T) {
	owner, _, bDir, s, _ := trustPair(t, 100)
	cut := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		if strings.HasSuffix(p, "/sync/accounts") || strings.HasSuffix(p, "/sync/device") || strings.HasSuffix(p, "/sync/trust") {
			s.ServeHTTP(w, r)
			return
		}
		// The link is gone: the connection drops with no answer.
		conn, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			conn.Close()
		}
	}))
	t.Cleanup(cut.Close)
	c := newCopyClient("npub1peer", cut.URL)
	if _, err := c.sync(context.Background()); err == nil {
		t.Fatal("a cut catch-up reported no error")
	}
	got, err := trustrank.ReadResult(bDir, owner.pk)
	if err != nil {
		t.Fatalf("the cut catch-up left the phone with no rank: %v", err)
	}
	if got.BuiltAt != 100 {
		t.Fatalf("copy is from %d", got.BuiltAt)
	}
}
