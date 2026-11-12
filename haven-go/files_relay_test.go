//go:build !(js && wasm)

package main

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/fasthttp/websocket"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// /files (files_relay.go): the owner's media notes. All keys are throwaway.

type filesVault struct {
	h                *havenUnderTest
	self, devA, devB testKey
	account          testKey // a second account on this vault (whitelisted, not the owner)
}

func startFilesVault(t *testing.T) *filesVault {
	t.Helper()
	h := startHaven(t)
	v := &filesVault{h: h, self: newTestKey(t), devA: newTestKey(t), devB: newTestKey(t), account: newTestKey(t)}
	config.OwnerPubKey = h.owner
	config.WhitelistedPubKeys[v.account.pk] = struct{}{}
	pairMeshDevices(t, v.self, v.devA, v.devB)
	return v
}

func fileHash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func fileNote(t *testing.T, sk, x, owner string) nostr.Event {
	t.Helper()
	ev := nostr.Event{Kind: kindFileMetadata, CreatedAt: nostr.Now(), Tags: nostr.Tags{
		{"x", x}, {"m", "image/jpeg"}, {"size", "1234"}, {"p", owner},
		{"url", "https://media.example/" + x + ".jpg"}, {"client", "nostr-vault"},
	}}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

func filesDeletion(t *testing.T, sk, owner, x string, ids ...string) nostr.Event {
	t.Helper()
	ev := nostr.Event{Kind: nostr.KindDeletion, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"k", "1063"}, {"x", x}, {"p", owner}}}
	for _, id := range ids {
		ev.Tags = append(ev.Tags, nostr.Tag{"e", id})
	}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

// filesConn dials /files on this machine; with sk set it AUTHs as that key.
func (v *filesVault) filesConn(t *testing.T, sk string) *meshWS {
	t.Helper()
	ws := dialURL(t, v.h.base+filesPath)
	if sk != "" {
		if ws.challenge == "" {
			ws.next("AUTH")
		}
		if !ws.auth(ws.challenge, sk, v.h.base+filesPath) {
			t.Fatal("AUTH on /files was not taken")
		}
	}
	return ws
}

func (v *filesVault) notes(t *testing.T) []nostr.Event {
	t.Helper()
	evs, closed := v.filesConn(t, v.h.ownerSK).req("o", nostr.Filter{Kinds: []int{kindFileMetadata, nostr.KindDeletion}, Tags: nostr.TagMap{"p": []string{v.h.owner}}})
	if closed != "" {
		t.Fatalf("the owner's read was closed: %q", closed)
	}
	return evs
}

func TestFilesWriteGate(t *testing.T) {
	v := startFilesVault(t)
	owner := v.h.owner
	x := fileHash("a")
	ws := v.filesConn(t, "")

	refused := func(name string, ev nostr.Event, want string) {
		t.Helper()
		if ok, msg := ws.publish(ev); ok || !strings.Contains(msg, want) {
			t.Errorf("%s: ok %v, %q (want refused, %q)", name, ok, msg, want)
		}
	}
	refused("account key (the owner's)", fileNote(t, v.h.ownerSK, x, owner), "never an account key")
	refused("a whitelisted account that is not the owner", fileNote(t, v.account.sk, x, owner), "never an account key")
	refused("a stranger", fileNote(t, nostr.GeneratePrivateKey(), x, owner), "paired devices")
	refused("the vault's own key over a socket", fileNote(t, filesVaultSecret(), x, owner), "vault's own")

	kind1 := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "hi", Tags: nostr.Tags{{"p", owner}}}
	kind1.Sign(v.devA.sk)
	refused("wrong kind", kind1, "only file notes")
	refused("p is not the owner", fileNote(t, v.devA.sk, x, v.account.pk), "owner only")
	refused("x is not a hash", fileNote(t, v.devA.sk, "abc", owner), "x tag")
	future := fileNote(t, v.devA.sk, x, owner)
	future.CreatedAt = nostr.Timestamp(time.Now().Add(time.Hour).Unix())
	future.Sign(v.devA.sk)
	refused("dated ahead", future, "future")

	if ok, msg := ws.publish(fileNote(t, v.devA.sk, x, owner)); !ok {
		t.Fatalf("a paired device's note was refused: %q", msg)
	}
	if ok, msg := ws.publish(fileNote(t, v.self.sk, x, owner)); !ok {
		t.Fatalf("the vault's mesh key's note was refused: %q", msg)
	}
	again := fileNote(t, v.devA.sk, x, owner)
	again.Content = "another id"
	again.Sign(v.devA.sk)
	if ok, msg := ws.publish(again); ok || !strings.HasPrefix(msg, "duplicate:") {
		t.Errorf("a second note from one device for one file: ok %v, %q", ok, msg)
	}
	if n := len(v.notes(t)); n != 2 {
		t.Errorf("the owner reads %d notes, want 2", n)
	}
}

func TestFilesReadGate(t *testing.T) {
	v := startFilesVault(t)
	if ok, msg := v.filesConn(t, "").publish(fileNote(t, v.devA.sk, fileHash("r"), v.h.owner)); !ok {
		t.Fatal(msg)
	}
	f := nostr.Filter{Kinds: []int{kindFileMetadata}}

	anon := v.filesConn(t, "")
	if evs, closed := anon.req("a", f); len(evs) != 0 || !strings.HasPrefix(closed, "auth-required") {
		t.Errorf("no AUTH: %d events, closed %q", len(evs), closed)
	}
	anon.send([]any{"REQ", "live", map[string]any{"kinds": []int{kindFileMetadata}, "limit": 0}})
	if got := str(anon.next("CLOSED", "EOSE")[0]); got != "CLOSED" {
		t.Errorf("no AUTH: a live-only REQ was not refused")
	}
	if n := anon.count(f); n != 0 {
		t.Errorf("no AUTH: COUNT = %d, want 0", n)
	}

	for name, sk := range map[string]string{"a whitelisted account that is not the owner": v.account.sk, "a stranger": nostr.GeneratePrivateKey()} {
		ws := v.filesConn(t, sk)
		if evs, closed := ws.req("x", f); len(evs) != 0 || !strings.HasPrefix(closed, "restricted") {
			t.Errorf("%s: %d events, closed %q", name, len(evs), closed)
		}
		if n := ws.count(f); n != 0 {
			t.Errorf("%s: COUNT = %d, want 0", name, n)
		}
	}
	for name, sk := range map[string]string{"the owner": v.h.ownerSK, "a paired device": v.devB.sk, "the vault's mesh key": v.self.sk} {
		ws := v.filesConn(t, sk)
		if evs, closed := ws.req("ok", f); closed != "" || len(evs) != 1 {
			t.Errorf("%s: %d events, closed %q", name, len(evs), closed)
		}
		if n := ws.count(f); n != 1 {
			t.Errorf("%s: COUNT = %d, want 1", name, n)
		}
	}
}

// count sends a COUNT and returns the answer (khatru answers a refused one
// with a NOTICE and 0).
func (m *meshWS) count(f nostr.Filter) int {
	m.t.Helper()
	m.send([]any{"COUNT", "c", f})
	msg := m.next("COUNT")
	var body struct {
		Count int `json:"count"`
	}
	_ = json.Unmarshal(msg[2], &body)
	return body.Count
}

func TestFilesDeleteAcrossDevices(t *testing.T) {
	v := startFilesVault(t)
	owner, x := v.h.owner, fileHash("d")
	ws := v.filesConn(t, "")
	noteA := fileNote(t, v.devA.sk, x, owner)
	noteB := fileNote(t, v.devB.sk, x, owner)
	for _, n := range []nostr.Event{noteA, noteB} {
		if ok, msg := ws.publish(n); !ok {
			t.Fatal(msg)
		}
	}

	// A stranger's, an account key's and a malformed deletion delete nothing.
	if ok, _ := ws.publish(filesDeletion(t, nostr.GeneratePrivateKey(), owner, x, noteA.ID)); ok {
		t.Error("a stranger's deletion was taken")
	}
	if ok, _ := ws.publish(filesDeletion(t, v.account.sk, owner, x, noteA.ID)); ok {
		t.Error("an account key's deletion was taken")
	}
	noK := nostr.Event{Kind: nostr.KindDeletion, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"e", noteA.ID}, {"p", owner}}}
	noK.Sign(v.devB.sk)
	if ok, _ := ws.publish(noK); ok {
		t.Error("a deletion with no k tag was taken")
	}
	if n := len(v.notes(t)); n != 2 {
		t.Fatalf("after refused deletions the owner reads %d events, want 2", n)
	}

	// Device B deletes device A's note.
	del := filesDeletion(t, v.devB.sk, owner, x, noteA.ID)
	if ok, msg := ws.publish(del); !ok {
		t.Fatalf("device B deleting device A's note: %q", msg)
	}
	ids := map[string]bool{}
	for _, ev := range v.notes(t) {
		ids[ev.ID] = true
	}
	if ids[noteA.ID] || !ids[noteB.ID] || !ids[del.ID] {
		t.Errorf("after the deletion: %v (want B's note and the deletion)", ids)
	}
	if ok, _ := ws.publish(noteA); ok {
		t.Error("a deleted note was published again")
	}
}

func TestFilesUnpairedDeviceStopsBeingTrusted(t *testing.T) {
	v := startFilesVault(t)
	owner := v.h.owner
	ws := v.filesConn(t, "")
	noteA := fileNote(t, v.devA.sk, fileHash("u1"), owner)
	if ok, msg := ws.publish(noteA); !ok {
		t.Fatal(msg)
	}
	// Device A listens live, then is unpaired.
	liveA := v.filesConn(t, v.devA.sk)
	liveA.send([]any{"REQ", "live", map[string]any{"kinds": []int{kindFileMetadata}, "limit": 0}})
	liveA.next("EOSE")
	pairMeshDevices(t, v.self, v.devB)

	if ok, _ := ws.publish(fileNote(t, v.devA.sk, fileHash("u2"), owner)); ok {
		t.Error("an unpaired device's note was taken")
	}
	for _, ev := range v.notes(t) {
		if ev.PubKey == v.devA.pk {
			t.Error("an unpaired device's old note is still served")
		}
	}
	if ok, msg := ws.publish(fileNote(t, v.devB.sk, fileHash("u3"), owner)); !ok {
		t.Fatal(msg)
	}
	if liveA.gotEvent(500 * time.Millisecond) {
		t.Error("an unpaired device still hears new notes on its open subscription")
	}
	if _, closed := v.filesConn(t, v.devA.sk).req("r", nostr.Filter{Kinds: []int{kindFileMetadata}}); !strings.HasPrefix(closed, "restricted") {
		t.Errorf("an unpaired device's read closed with %q", closed)
	}
}

func TestFilesOverTheMeshDoor(t *testing.T) {
	v := startFilesVault(t)
	npub := withMeshNpub(t)
	door := startMeshDoor(t)
	pinned := "ws://" + npub + ".fips" + filesPath

	ws := dialDoor(t, door, filesPath)
	if ws.challenge == "" {
		ws.next("AUTH")
	}
	if ws.auth(ws.challenge, v.devA.sk, v.h.base+filesPath) {
		t.Fatal("a mesh AUTH naming the loopback URL was taken")
	}
	if !ws.auth(ws.challenge, v.devA.sk, pinned) {
		t.Fatal("a paired device's pinned mesh AUTH was not taken")
	}
	note := fileNote(t, v.devA.sk, fileHash("m"), v.h.owner)
	if ok, msg := ws.publish(note); !ok {
		t.Fatalf("a paired device's note over the mesh: %q", msg)
	}
	if evs, closed := ws.req("r", nostr.Filter{Kinds: []int{kindFileMetadata}}); closed != "" || len(evs) != 1 {
		t.Errorf("a paired device's read over the mesh: %d events, closed %q", len(evs), closed)
	}

	// The note is not in the outbox, over the mesh or here.
	if evs, _ := dialDoor(t, door, "/").req("o", nostr.Filter{Kinds: []int{kindFileMetadata}}); len(evs) != 0 {
		t.Errorf("the mesh outbox returned %d file notes", len(evs))
	}
	if evs, _ := dialURL(t, v.h.base).req("o", nostr.Filter{Kinds: []int{kindFileMetadata}}); len(evs) != 0 {
		t.Errorf("the outbox returned %d file notes", len(evs))
	}
}

// On the box the relay port is also the public URL: /files through a tunnel
// or a forwarding hop is refused.
func TestFilesNotServedThroughATunnel(t *testing.T) {
	v := startFilesVault(t)
	for _, h := range []http.Header{{"Cf-Ray": {"abc"}}, {"X-Forwarded-For": {"203.0.113.9"}}} {
		c, _, err := websocket.DefaultDialer.Dial(v.h.base+filesPath, h)
		if err == nil {
			c.Close()
			t.Errorf("/files opened with %v", h)
		}
	}
}

func TestFilesBackfillRunsOnce(t *testing.T) {
	v := startFilesVault(t)
	ctx := context.Background()
	x := fileHash("b")
	rec := nostr.Event{Kind: 24242, PubKey: v.h.owner, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"x", x}, {"type", "image/png"}, {"size", "99"}}}
	rec.ID = rec.GetID()
	if err := blossomDB.SaveEvent(ctx, &rec); err != nil {
		t.Fatal(err)
	}
	other := nostr.Event{Kind: 24242, PubKey: v.account.pk, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"x", fileHash("not the owner's")}, {"type", "image/png"}, {"size", "1"}}}
	other.ID = other.GetID()
	if err := blossomDB.SaveEvent(ctx, &other); err != nil {
		t.Fatal(err)
	}

	backfillFileNotes(ctx)
	notes := v.notes(t)
	if len(notes) != 1 || notes[0].PubKey != filesVaultPubKey() || notes[0].Tags.FindWithValue("x", x) == nil || notes[0].Tags.FindWithValue("m", "image/png") == nil {
		t.Fatalf("after the backfill: %+v", notes)
	}
	backfillFileNotes(ctx)
	if err := os.Remove(filesBackfillFile); err != nil {
		t.Fatal(err)
	}
	backfillFileNotes(ctx) // cut off before the marker: no second note
	if n := len(v.notes(t)); n != 1 {
		t.Errorf("after three runs the owner reads %d notes, want 1", n)
	}
}

// Logen's pick (b): a blob deleted from the vault posts a kind 5 that every
// open Media tab hears.
func TestFilesBlobDeletePostsADeletion(t *testing.T) {
	v := startFilesVault(t)
	x := fileHash("gone")
	ws := v.filesConn(t, "")
	note := fileNote(t, v.devA.sk, x, v.h.owner)
	if ok, msg := ws.publish(note); !ok {
		t.Fatal(msg)
	}
	live := v.filesConn(t, v.devB.sk)
	live.send([]any{"REQ", "live", map[string]any{"kinds": []int{nostr.KindDeletion}, "limit": 0}})
	live.next("EOSE")

	if err := afero.WriteFile(fs, config.BlossomPath+x, []byte("gone"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, del := range blossomServer.DeleteBlob { // the Blossom delete, as wired
		if err := del(context.Background(), x, "jpg"); err != nil {
			t.Fatal(err)
		}
	}
	msg := live.next("EVENT")
	var got nostr.Event
	if err := got.UnmarshalJSON(msg[2]); err != nil {
		t.Fatal(err)
	}
	if got.Kind != nostr.KindDeletion || got.PubKey != filesVaultPubKey() || got.Tags.FindWithValue("e", note.ID) == nil {
		t.Fatalf("the live deletion: %+v", got)
	}
	for _, ev := range v.notes(t) {
		if ev.ID == note.ID {
			t.Error("the note for a deleted blob is still served")
		}
	}
}

// Tron, #1974: an account key never counts as a device, even when the app's
// device list names it (as self or as a device).
func TestFilesAccountKeyInTheDeviceListStaysRefused(t *testing.T) {
	v := startFilesVault(t)
	owner := testKey{sk: v.h.ownerSK, pk: v.h.owner}
	pairMeshDevices(t, owner, v.account, v.devA)
	ws := v.filesConn(t, "")
	for name, sk := range map[string]string{"the owner as self": owner.sk, "a second account as a device": v.account.sk} {
		if ok, _ := ws.publish(fileNote(t, sk, fileHash(name), v.h.owner)); ok {
			t.Errorf("%s: a note signed with an account key was taken", name)
		}
	}
	if ok, msg := ws.publish(fileNote(t, v.devA.sk, fileHash("dev"), v.h.owner)); !ok {
		t.Fatalf("the paired device's note: %q", msg)
	}
	// The account listed as a device reads as nobody; the owner still reads.
	if _, closed := v.filesConn(t, v.account.sk).req("a", nostr.Filter{Kinds: []int{kindFileMetadata}}); !strings.HasPrefix(closed, "restricted") {
		t.Errorf("a second account listed as a device read /files: closed %q", closed)
	}
	if n := len(v.notes(t)); n != 1 {
		t.Errorf("the owner reads %d notes, want 1", n)
	}
}

// Tron, #1974: the files store never travels in a mesh copy, and neither a
// copy nor a backup zip that carries one is taken in.
func TestFilesStoreNeverTravels(t *testing.T) {
	owner, dev := newTestKey(t), newTestKey(t)
	cv := openCopyVault(t, owner.pk)
	prevFiles := filesDB
	t.Cleanup(func() { filesDB = prevFiles })
	filesDB = fallbackBackend(filepath.Join(cv.dir, "db", "files"))
	if err := filesDB.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(filesDB.Close)
	dbs["files"] = filesDB
	saveEv(t, filesDB, fileNote(t, dev.sk, fileHash("a"), owner.pk))
	saveEv(t, outboxDB, owner.sign(t, nostr.Event{Kind: 1, Content: "hello"}))

	dir := t.TempDir()
	if _, err := buildCopy(context.Background(), dir, "dddddddddddddddddddddddddddddddd", func(copyProgress) {}); err != nil {
		t.Fatal(err)
	}
	zr, err := zip.OpenReader(filepath.Join(dir, "notes.zip"))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, f := range zr.File {
		names = append(names, f.Name)
	}
	zr.Close()
	if slices.Contains(names, "files.jsonl") || !slices.Contains(names, "outbox.jsonl") {
		t.Errorf("the copy's notes.zip holds %v (want outbox.jsonl, no files.jsonl)", names)
	}

	// Taking one in: a zip that carries files.jsonl leaves the store alone.
	carried := fileNote(t, dev.sk, fileHash("carried"), owner.pk)
	note := owner.sign(t, nostr.Event{Kind: 1, Content: "carried along"})
	path := filepath.Join(t.TempDir(), "in.zip")
	f, _ := os.Create(path)
	zw := zip.NewWriter(f)
	for name, ev := range map[string]nostr.Event{"files.jsonl": carried, "outbox.jsonl": note} {
		w, _ := zw.Create(name)
		line, _ := json.Marshal(ev)
		_, _ = w.Write(append(line, '\n'))
	}
	zw.Close()
	f.Close()
	var stats copyRestoreStats
	if _, _, err := restoreCopyNotes(context.Background(), path, &stats); err != nil {
		t.Fatalf("restoring the copy: %v", err)
	}
	if err := importFromZip(context.Background(), path); err != nil {
		t.Fatalf("importing the zip: %v", err)
	}
	if n := countIn(t, filesDB, nostr.Filter{IDs: []string{carried.ID}}); n != 0 {
		t.Error("a files.jsonl in a copy or zip was taken in")
	}
	if n := countIn(t, outboxDB, nostr.Filter{IDs: []string{note.ID}}); n != 1 {
		t.Error("the outbox note beside it was not taken in (positive control)")
	}
}

// #1971's private readers read /files when the app names them; with no
// reader file (Android, the browser vault) only the owner does, never the
// whole whitelist.
func TestFilesReadersFollowThePrivateReaderSet(t *testing.T) {
	v := startFilesVault(t)
	if ok, msg := v.filesConn(t, "").publish(fileNote(t, v.devA.sk, fileHash("pr"), v.h.owner)); !ok {
		t.Fatal(msg)
	}
	f := nostr.Filter{Kinds: []int{kindFileMetadata}}
	reads := func(sk string) bool {
		evs, closed := v.filesConn(t, sk).req("r", f)
		return closed == "" && len(evs) == 1
	}
	if reads(v.account.sk) {
		t.Error("no reader file: a second account read /files")
	}
	addedNpub := newTestKey(t)
	config.WhitelistedPubKeys[addedNpub.pk] = struct{}{}
	config.PrivateReaderPubKeys = map[string]struct{}{v.h.owner: {}, v.account.pk: {}}
	t.Cleanup(func() { config.PrivateReaderPubKeys = nil })
	if !reads(v.account.sk) {
		t.Error("an account in the private-reader set could not read /files")
	}
	if reads(addedNpub.sk) {
		t.Error("an added npub outside the private-reader set read /files")
	}
	if !reads(v.h.ownerSK) {
		t.Error("the owner could not read /files")
	}
}
