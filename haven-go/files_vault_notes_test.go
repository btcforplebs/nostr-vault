//go:build !(js && wasm)

package main

import (
	"bytes"
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The vault writes the file note itself for a new upload (files_vault_notes.go),
// so a file from an old app or another client still shows up live. All keys
// are throwaway.

// heldNoteChecks swaps the grace timer for a list the test runs by hand.
func heldNoteChecks(t *testing.T) *[]func() {
	t.Helper()
	var held []func()
	prev := filesAfterUpload
	filesAfterUpload = func(_ time.Duration, f func()) { held = append(held, f) }
	t.Cleanup(func() { filesAfterUpload = prev })
	return &held
}

func runHeld(held *[]func()) {
	fs := *held
	*held = nil
	for _, f := range fs {
		f()
	}
}

func uploadAs(t *testing.T, h *havenUnderTest, sk string, body []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPut, httpBase(h)+"/upload", bytes.NewReader(body))
	req.Header.Set("Authorization", blossomUploadAuth(t, sk, body))
	req.Header.Set("Content-Type", "image/png")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("upload: %d %s", resp.StatusCode, resp.Header.Get("X-Reason"))
	}
}

func notesFor(evs []nostr.Event, x string) []nostr.Event {
	var out []nostr.Event
	for _, ev := range evs {
		if ev.Kind == kindFileMetadata && ev.Tags.FindWithValue("x", x) != nil {
			out = append(out, ev)
		}
	}
	return out
}

// An upload signed with the account key (an old app, another client) gets a
// note signed by the vault's own /files key, and an open Media tab hears it.
func TestFilesVaultNotesAnUploadNoAppNoted(t *testing.T) {
	v := startFilesVault(t)
	held := heldNoteChecks(t)
	live := v.filesConn(t, v.devB.sk)
	live.send([]any{"REQ", "live", map[string]any{"kinds": []int{kindFileMetadata}, "limit": 0}})
	live.next("EOSE")

	body := []byte("an image from an old app")
	x := fileHash(string(body))
	uploadAs(t, v.h, v.h.ownerSK, body)
	if len(*held) == 0 {
		t.Fatal("no note check was set for the upload")
	}
	runHeld(held)

	msg := live.next("EVENT")
	var got nostr.Event
	if err := got.UnmarshalJSON(msg[2]); err != nil {
		t.Fatal(err)
	}
	if got.Kind != kindFileMetadata || got.Tags.FindWithValue("x", x) == nil {
		t.Fatalf("the live note: %+v", got)
	}
	if got.PubKey != filesVaultPubKey() || got.PubKey == v.h.owner {
		t.Errorf("signed by %s, want the vault's /files key, never the account key", got.PubKey)
	}
	if got.Tags.FindWithValue("p", v.h.owner) == nil || got.Tags.FindWithValue("m", "image/png") == nil ||
		got.Tags.FindWithValue("size", "24") == nil {
		t.Errorf("tags: %v", got.Tags)
	}
	if ok, _ := got.CheckSignature(); !ok {
		t.Error("bad signature")
	}
	if n := len(notesFor(v.notes(t), x)); n != 1 {
		t.Errorf("the owner reads %d notes for the file, want 1", n)
	}
}

// The app already sent its note (its device mesh key): the vault writes none.
func TestFilesVaultSkipsAFileTheAppNoted(t *testing.T) {
	v := startFilesVault(t)
	held := heldNoteChecks(t)
	body := []byte("an image from a new app")
	x := fileHash(string(body))
	uploadAs(t, v.h, v.h.ownerSK, body)
	if ok, msg := v.filesConn(t, "").publish(fileNote(t, v.devA.sk, x, v.h.owner)); !ok {
		t.Fatal(msg)
	}
	runHeld(held)
	notes := notesFor(v.notes(t), x)
	if len(notes) != 1 || notes[0].PubKey != v.devA.pk {
		t.Fatalf("notes for the file: %+v, want only the app's", notes)
	}
}

// The same file again (a second upload, a mirror) gets no second note.
func TestFilesVaultNotesAFileOnce(t *testing.T) {
	v := startFilesVault(t)
	held := heldNoteChecks(t)
	body := []byte("the same image twice")
	x := fileHash(string(body))
	uploadAs(t, v.h, v.h.ownerSK, body)
	runHeld(held)
	uploadAs(t, v.h, v.h.ownerSK, body)
	runHeld(held)
	if n := len(notesFor(v.notes(t), x)); n != 1 {
		t.Errorf("%d notes for one file, want 1", n)
	}
}

// Another account's upload is not the owner's media: no note.
func TestFilesVaultSkipsAnotherAccountsUpload(t *testing.T) {
	v := startFilesVault(t)
	held := heldNoteChecks(t)
	body := []byte("someone else's image")
	x := fileHash(string(body))
	uploadAs(t, v.h, v.account.sk, body)
	runHeld(held)
	if n := len(notesFor(v.notes(t), x)); n != 0 {
		t.Errorf("%d notes for another account's file, want 0", n)
	}
}

// Deleted before the grace ran out: no note for a file that is gone.
func TestFilesVaultSkipsAFileDeletedInTheGrace(t *testing.T) {
	v := startFilesVault(t)
	held := heldNoteChecks(t)
	body := []byte("here and gone")
	x := fileHash(string(body))
	uploadAs(t, v.h, v.h.ownerSK, body)
	if err := blossomServer.Store.Delete(context.Background(), x, v.h.owner); err != nil {
		t.Fatal(err)
	}
	runHeld(held)
	if n := len(notesFor(v.notes(t), x)); n != 0 {
		t.Errorf("%d notes for a deleted file, want 0", n)
	}
}
