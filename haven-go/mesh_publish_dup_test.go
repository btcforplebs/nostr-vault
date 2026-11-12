//go:build !(js && wasm)

package main

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Tron's PR 1970 re-check (Logen's go, 2026-11-12): the phone sends to the
// author's own 10002 write relays at once, alongside the hand-off. When
// that list names the vault's own public relay (the usual own-relay
// setup), the https copy is an owner write the vault blasts, and the
// hand-off that follows found it "duplicate:", so the phone fanned it out
// as well: two blasts. The vault already sending that note now confirms
// the hand-off, so exactly one device blasts it. All keys are throwaway.
func TestMeshPublishForMeConfirmsANoteTheVaultAlreadyBlasted(t *testing.T) {
	ws, h := openPublishConn(t)
	url, got, ids := recordingRelay(t)
	config.BlastrRelays = []string{url}
	config.BlastrTimeoutSeconds = 1

	note := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "own relay first, then the hand-off"}
	note.Sign(h.ownerSK)
	direct := dialURL(t, h.base)
	if ok, msg := direct.publish(note); !ok {
		t.Fatalf("owner write on the vault's own relay: OK false %q", msg)
	}
	if !waitBlasted(ids, note.ID, 5*time.Second) {
		t.Fatal("the owner's direct write was not blasted")
	}
	if ok, msg := ws.publish(note); !ok || msg != "" {
		t.Errorf("hand-off of a note the vault is already sending: ok %v %q, want a plain OK true (the phone would fan it out again)", ok, msg)
	}
	time.Sleep(1500 * time.Millisecond)
	if n := got.Load(); n != 1 {
		t.Errorf("the vault sent the note %d times, want 1", n)
	}

	// Control: a note the vault holds but did not send (second-hand,
	// ?pulled=1) is still refused, so the phone sends it.
	pulled := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "stored here, never blasted"}
	pulled.Sign(h.ownerSK)
	if ok, msg := dialURL(t, h.base+"/?pulled=1").publish(pulled); !ok {
		t.Fatalf("pulled write: OK false %q", msg)
	}
	if ok, msg := ws.publish(pulled); ok || !strings.HasPrefix(msg, "duplicate:") {
		t.Errorf("hand-off of a note the vault holds but did not send: ok %v %q, want OK false duplicate:", ok, msg)
	}
	if waitBlasted(ids, pulled.ID, 1500*time.Millisecond) {
		t.Error("a pulled note was blasted")
	}
}

// Tron's PR 1970 low: when the blast queue cannot be written (disk full),
// keepForPublish must not say the note is kept, or the vault answers OK
// true with nothing on disk.
func TestKeepForPublishFailsWhenTheQueueCannotBeWritten(t *testing.T) {
	q := openBlastQueue(filepath.Join(t.TempDir(), "gone", blastPendingFile))
	note := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "nowhere to write"}
	note.Sign(nostr.GeneratePrivateKey())
	if q.keepForPublish(&note) {
		t.Error("keepForPublish said kept, but the queue file could not be written")
	}
	// Control: a writable queue keeps it.
	ok := openBlastQueue(filepath.Join(t.TempDir(), blastPendingFile))
	if !ok.keepForPublish(&note) {
		t.Error("keepForPublish failed on a writable queue")
	}
}
