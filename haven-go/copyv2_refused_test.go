//go:build !(js && wasm)

package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// The iPad, 2026-11-24: a cut first copy resumed on a token the Mac then
// refused. run() wiped the folder and said auth_refused, the app dropped the
// pending copy, and nothing ever started it again, so the Mac's trust rank
// never came over. The resume now says token_refused (the app signs a new
// start with its mesh key), and copyRefusedPeers names the device until a
// new start is turned down too.
func TestRefusedTokenFirstCopyCanStartAgain(t *testing.T) {
	owner, self, mac := newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	pairMeshDevices(t, self, mac)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "auth_refused", http.StatusUnauthorized)
	}))
	defer ts.Close()

	peer := meshNpub(mac.pk)
	saveCopyPeerToken(peer, strings.Repeat("ab", 32))
	c := newCopyClient(peer, ts.URL)
	if err := os.MkdirAll(c.dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := c.saveState(&copyState{V: 1, ID: strings.Repeat("0", 32), Done: map[string][]int{}, Failures: map[string]int{}}); err != nil {
		t.Fatal(err)
	}
	if got := copyRefusedPeers(); len(got) != 0 {
		t.Fatalf("a copy still to resume is offered for a new start: %v", got)
	}

	if err := c.run(context.Background(), ""); copyErrorCode(err) != "token_refused" {
		t.Fatalf("resume on a refused token: %v, want token_refused (auth_refused drops the copy for good)", err)
	}
	if got := copyRefusedPeers(); !slices.Equal(got, []string{peer}) {
		t.Fatalf("refused peers %v, want the Mac", got)
	}

	// The new start is turned down as well: not offered again.
	if err := newCopyClient(peer, ts.URL).run(context.Background(), "proof"); copyErrorCode(err) != "auth_refused" {
		t.Fatalf("refused new start: %v, want auth_refused", err)
	}
	if _, err := os.Stat(filepath.Join(c.dir, copyStartFailedFile)); err != nil {
		t.Fatal("a refused new start left no mark")
	}
	if got := copyRefusedPeers(); len(got) != 0 {
		t.Fatalf("a device that refused a new start is offered again: %v", got)
	}
	if copyPeerToken(peer) == "" {
		t.Fatal("the held token was dropped")
	}
}

// Tron's review of #2537: A builds one copy at a time, so a new start while
// it builds another device's copy answers 200 and the job fails with busy.
// That is not a refusal: no mark, and the device is offered again.
func TestBusyNewStartIsOfferedAgain(t *testing.T) {
	owner, self, mac := newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	pairMeshDevices(t, self, mac)
	id := strings.Repeat("1", 32)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/copy/v2/start" {
			copyJSON(w, http.StatusOK, map[string]string{"id": id, "token": strings.Repeat("cd", 32), "state": "building"})
			return
		}
		copyJSON(w, http.StatusOK, map[string]any{"v": 2, "id": id, "state": "failed", "error": "busy"})
	}))
	defer ts.Close()

	peer := meshNpub(mac.pk)
	c := newCopyClient(peer, ts.URL)
	if err := c.run(context.Background(), "proof"); copyErrorCode(err) != "busy" {
		t.Fatalf("new start while A builds another copy: %v, want busy", err)
	}
	if _, err := os.Stat(filepath.Join(c.dir, copyStartFailedFile)); err == nil {
		t.Fatal("busy left a refusal mark: the copy would be stranded for good")
	}
	if got := copyRefusedPeers(); !slices.Equal(got, []string{peer}) {
		t.Fatalf("refused peers %v, want the Mac offered again after busy", got)
	}
}
