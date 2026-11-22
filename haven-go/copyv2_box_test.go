//go:build !cshared && !(js && wasm)

package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

func TestBoxControlRefusesBadStarts(t *testing.T) {
	pk, _ := nostr.GetPublicKey(nostr.GeneratePrivateKey())
	npub, _ := nip19.EncodePublicKey(pk)
	ran := 0
	h := boxControl(context.Background(), func(string, func()) { ran++ })
	for _, c := range []struct{ path, body string }{
		{"/copy/sync", `{"peer":"` + pk + `","base":"http://127.0.0.1:4242"}`},        // hex, not npub
		{"/copy/sync", `{"peer":"` + npub + `","base":"http://10.0.0.5:4242"}`},       // not loopback
		{"/copy/sync", `{"peer":"` + npub + `","base":"https://127.0.0.1:4242"}`},     // not http
		{"/copy/sync", `{"peer":"` + npub + `","base":"http://127.0.0.1:4242/?x=1"}`}, // query
		{"/copy/first", `{"peer":"` + npub + `","base":"http://127.0.0.1:4242"}`},     // no proof
		{"/copy/sync", `not json`},
	} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(http.MethodPost, c.path, strings.NewReader(c.body)))
		if w.Code != http.StatusBadRequest {
			t.Fatalf("%s %s: %d, want 400", c.path, c.body, w.Code)
		}
	}
	if ran != 0 {
		t.Fatalf("a refused start ran %d copies", ran)
	}
}

func TestBoxControlStateAndBusy(t *testing.T) {
	t.Chdir(t.TempDir())
	old := boxCopy
	boxCopy = &boxCopies{path: boxCopyStateFile, now: old.now}
	defer func() { boxCopy = old }()
	pk, _ := nostr.GetPublicKey(nostr.GeneratePrivateKey())
	npub, _ := nip19.EncodePublicKey(pk)
	saveCopyPeerToken(npub, strings.Repeat("a", 64))

	held := make(chan func(), 1)
	h := boxControl(context.Background(), func(_ string, fn func()) { held <- fn })
	post := func() int {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/copy/sync", strings.NewReader(`{"peer":"`+npub+`","base":"http://127.0.0.1:1"}`)))
		return w.Code
	}
	if c := post(); c != http.StatusAccepted {
		t.Fatalf("first start %d", c)
	}
	state := func() boxCopyState {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/copy/state?peer="+npub+"&peer=junk", nil))
		var st boxCopyState
		json.NewDecoder(w.Body).Decode(&st)
		return st
	}
	if st := state(); !st.Busy || len(st.Devices) != 1 || !st.Devices[0].Token {
		t.Fatalf("while held: %+v", st)
	}
	if c := post(); c != http.StatusConflict {
		t.Fatalf("second start while one runs: %d, want 409", c)
	}
	(<-held)() // the catch-up runs: nothing listens on port 1, so it fails
	st := state()
	if st.Busy || st.Devices[0].Last == nil || st.Devices[0].Last.Kind != "sync" || st.Devices[0].Last.Error == "" {
		t.Fatalf("after the run: %+v %+v", st, st.Devices[0].Last)
	}
}
