//go:build !(js && wasm)

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
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
	"github.com/spf13/afero"
)

// Tron #1997 M1: a file deleted on one device never came off the others,
// and a device that caught up with one of them pulled it back.

func blobDeleteAuth(t *testing.T, k testKey, at nostr.Timestamp, shas ...string) *nostr.Event {
	t.Helper()
	tags := nostr.Tags{{"t", "delete"}, {"expiration", strconv.FormatInt(int64(at)+300, 10)}}
	for _, sha := range shas {
		tags = append(tags, nostr.Tag{"x", sha})
	}
	ev := k.sign(t, nostr.Event{Kind: 24242, CreatedAt: at, Tags: tags, Content: "Delete"})
	return &ev
}

// deleteItems: evs on the wire, with no account named (an account's own
// delete needs none).
func deleteItems(evs ...*nostr.Event) []copyDeleteItem {
	out := make([]copyDeleteItem, 0, len(evs))
	for _, ev := range evs {
		out = append(out, copyDeleteItem{Ev: ev})
	}
	return out
}

func copySyncServerFor(t *testing.T, owner testKey) (*copyServer, func(method, path string, body []byte) *httptest.ResponseRecorder) {
	t.Helper()
	s := newTestCopyServer(nil)
	token := copyRandomHex(32)
	s.tokens = []copyToken{{Hash: copyHashToken(token), Owner: owner.pk, LastUsed: time.Now().Unix()}}
	s.loaded = true
	return s, func(method, path string, body []byte) *httptest.ResponseRecorder {
		req := copyReq(method, path, bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, req)
		return rec
	}
}

// openDeletesVault: openCopyVault with the blob files on the real disk, as
// the engine has them (deleteBlobFiles goes through fs).
func openDeletesVault(t *testing.T, owner string) {
	t.Helper()
	openCopyVault(t, owner)
	prev := fs
	fs = afero.NewOsFs()
	t.Cleanup(func() { fs = prev })
}

func blobRecords(t *testing.T, sha string) int {
	t.Helper()
	return countIn(t, blossomDB, nostr.Filter{Kinds: []int{24242}, Tags: nostr.TagMap{"x": []string{sha}}})
}

// A's side: a peer's delete removes the file and its record, and the hash
// is left out of the file list and the file GET from then on.
func TestCopyDeleteListFromAPeerRemovesAndHidesTheFile(t *testing.T) {
	owner := newTestKey(t)
	openDeletesVault(t, owner.pk)
	gone := addBlob(t, owner.pk, []byte("deleted on the other Mac"))
	kept := addBlob(t, owner.pk, []byte("still wanted"))
	_, call := copySyncServerFor(t, owner)

	body, _ := json.Marshal(copyDeleteList{Deletes: deleteItems(blobDeleteAuth(t, owner, nostr.Now()+1, gone))})
	if rec := call(http.MethodPut, "/copy/v2/sync/deletes", body); rec.Code != 200 || !strings.Contains(rec.Body.String(), `"gone":1`) {
		t.Fatalf("PUT deletes: %d %s", rec.Code, rec.Body.String())
	}
	if copyBlobFile(gone) != "" || blobRecords(t, gone) != 0 {
		t.Fatal("the deleted file or its record is still here")
	}
	if copyBlobFile(kept) == "" {
		t.Fatal("a file not on the list went too")
	}
	list := call(http.MethodGet, "/copy/v2/sync/files?since=0", nil).Body.String()
	if strings.Contains(list, gone) || !strings.Contains(list, kept) {
		t.Fatalf("file list: %s", list)
	}
	// The list passes on to the next device that asks.
	if got := call(http.MethodGet, "/copy/v2/sync/deletes?since=0", nil).Body.String(); !strings.Contains(got, gone) {
		t.Fatalf("deletes list: %s", got)
	}
}

// A file still on disk (a record left by a second own account) but on the
// list is neither listed nor served.
func TestCopyDeleteListHidesAFileStillOnDisk(t *testing.T) {
	owner := newTestKey(t)
	openDeletesVault(t, owner.pk)
	sha := addBlob(t, owner.pk, []byte("a photo"))
	keepCopyDelete(blobDeleteAuth(t, owner, nostr.Now()+1, sha), owner.pk, time.Now())
	if copyBlobFile(sha) == "" {
		t.Fatal("setup: the file should still be on disk")
	}
	_, call := copySyncServerFor(t, owner)
	if list := call(http.MethodGet, "/copy/v2/sync/files?since=0", nil).Body.String(); strings.Contains(list, sha) {
		t.Fatalf("a deleted file was listed: %s", list)
	}
	if c := call(http.MethodGet, "/copy/v2/sync/file/"+sha, nil).Code; c != 404 {
		t.Fatalf("a deleted file was served: %d", c)
	}
}

// Uploaded again after its delete: the newer record wins, the file stays.
func TestCopyDeleteListLosesToANewerUpload(t *testing.T) {
	owner := newTestKey(t)
	openDeletesVault(t, owner.pk)
	sha := addBlob(t, owner.pk, []byte("posted again"))
	_, call := copySyncServerFor(t, owner)
	body, _ := json.Marshal(copyDeleteList{Deletes: deleteItems(blobDeleteAuth(t, owner, nostr.Now()-3600, sha))})
	call(http.MethodPut, "/copy/v2/sync/deletes", body)
	if copyBlobFile(sha) == "" {
		t.Fatal("an old delete removed a file uploaded after it")
	}
	if list := call(http.MethodGet, "/copy/v2/sync/files?since=0", nil).Body.String(); !strings.Contains(list, sha) {
		t.Fatalf("file list: %s", list)
	}
}

// Only an own account or an own device may delete: a stranger's signed
// delete, a broken signature or a non-delete verb changes nothing.
func TestCopyDeleteListRefusesStrangersAndBadEvents(t *testing.T) {
	owner, stranger := newTestKey(t), newTestKey(t)
	openDeletesVault(t, owner.pk)
	sha := addBlob(t, owner.pk, []byte("mine"))
	_, call := copySyncServerFor(t, owner)
	forged := blobDeleteAuth(t, owner, nostr.Now()+1, sha)
	forged.Sig = strings.Repeat("0", 128)
	upload := owner.sign(t, nostr.Event{Kind: 24242, CreatedAt: nostr.Now() + 1, Tags: nostr.Tags{{"t", "upload"}, {"x", sha}}})
	future := blobDeleteAuth(t, owner, nostr.Now()+3600, sha)
	for name, ev := range map[string]*nostr.Event{
		"stranger": blobDeleteAuth(t, stranger, nostr.Now()+1, sha),
		"bad sig":  forged,
		"upload":   &upload,
		"future":   future,
	} {
		body, _ := json.Marshal(copyDeleteList{Deletes: deleteItems(ev)})
		call(http.MethodPut, "/copy/v2/sync/deletes", body)
		if copyBlobFile(sha) == "" {
			t.Fatalf("%s: the file was deleted", name)
		}
	}
	if len(copyDeletesSince(0)) != 0 {
		t.Fatal("a refused delete was kept")
	}
}

// The Blossom DELETE here files its own signed event for the other devices.
func TestCopyOwnBlossomDeleteIsKept(t *testing.T) {
	owner := newTestKey(t)
	openDeletesVault(t, owner.pk)
	sha := addBlob(t, owner.pk, []byte("deleted here"))
	auth := blobDeleteAuth(t, owner, nostr.Now(), sha)
	if reject, _, _ := noteCopyDeleteAuth(context.Background(), auth, sha, ""); reject {
		t.Fatal("the note hook refused a delete")
	}
	keepOwnCopyDelete(sha)
	if got := copyDeletesSince(0); len(got) != 1 || got[0].Ev.ID != auth.ID || got[0].Owner != owner.pk {
		t.Fatalf("kept: %v", got)
	}
	// A DeleteBlob with no noted event (another path) keeps nothing.
	keepOwnCopyDelete(strings.Repeat("a", 64))
	if len(copyDeletesSince(0)) != 1 {
		t.Fatal("kept a delete it never saw")
	}
}

// deletesA: a peer A for B's catch-up, with its own delete list and files,
// that records what B asks in order and the deletes B hands over.
type deletesA struct {
	*fakeFilesA
	mu      sync.Mutex
	deletes []copyDeleteItem
	got     []copyDeleteItem
	paths   []string
	asked   []string // the since of each GET
}

func (d *deletesA) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	d.mu.Lock()
	d.paths = append(d.paths, r.URL.Path)
	d.mu.Unlock()
	if r.URL.Path == "/copy/v2/sync/deletes" {
		if r.Method == http.MethodPut {
			var in copyDeleteList
			_ = json.NewDecoder(r.Body).Decode(&in)
			d.mu.Lock()
			d.got = append(d.got, in.Deletes...)
			d.mu.Unlock()
			_ = json.NewEncoder(w).Encode(map[string]int{"gone": 0})
			return
		}
		d.mu.Lock()
		d.asked = append(d.asked, r.URL.Query().Get("since"))
		d.mu.Unlock()
		_ = json.NewEncoder(w).Encode(copyDeleteList{Deletes: d.deletes})
		return
	}
	d.fakeFilesA.ServeHTTP(w, r)
}

// B's side: A's deletes come off B before any file moves, B's own go to A,
// and a file B deleted is not pulled back from an A that still lists it.
func TestCopyCatchUpSwapsDeleteListsBeforeFiles(t *testing.T) {
	owner := newTestKey(t)
	openDeletesVault(t, owner.pk) // B
	onB := addBlob(t, owner.pk, []byte("on B, deleted on A"))
	backData := []byte("deleted on B, A still has it")
	sum := sha256.Sum256(backData)
	back := hex.EncodeToString(sum[:])
	mine := blobDeleteAuth(t, owner, nostr.Now()+1, back)
	keepCopyDelete(mine, owner.pk, time.Now())

	_, real := copySyncPair(t, owner) // saves A's token for npub1peer
	a := &deletesA{
		fakeFilesA: &fakeFilesA{real: real, pageSize: 10, data: map[string][]byte{back: backData},
			files: []copyFile{{SHA256: back, Pubkey: owner.pk, Type: "image/jpeg", Size: strconv.Itoa(len(backData)), CreatedAt: time.Now().Unix() - 60}}},
		deletes: deleteItems(blobDeleteAuth(t, owner, nostr.Now()+1, onB)),
	}
	ts := httptest.NewServer(a)
	t.Cleanup(ts.Close)
	res, err := newCopyClient("npub1peer", ts.URL).sync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if copyBlobFile(onB) != "" || res.Gone != 1 {
		t.Fatalf("A's delete did not come off B (gone=%d)", res.Gone)
	}
	if copyBlobFile(back) != "" || res.Files != 0 {
		t.Fatal("B pulled back a file it deleted")
	}
	if len(a.got) != 1 || a.got[0].Ev.ID != mine.ID {
		t.Fatalf("B's delete list did not reach A: %v", a.got)
	}
	firstDeletes, firstFiles := -1, -1
	for i, p := range a.paths {
		if p == "/copy/v2/sync/deletes" && firstDeletes < 0 {
			firstDeletes = i
		}
		if strings.HasPrefix(p, "/copy/v2/sync/file") && firstFiles < 0 {
			firstFiles = i
		}
	}
	if firstDeletes < 0 || (firstFiles >= 0 && firstFiles < firstDeletes) {
		t.Fatalf("files before the delete lists: %v", a.paths)
	}
}

// A notes-only (light) device swaps and applies the lists too: a file the
// owner deleted goes everywhere; nothing else is removed.
func TestCopyNotesOnlyCatchUpStillTakesDeletes(t *testing.T) {
	owner := newTestKey(t)
	openDeletesVault(t, owner.pk)
	onB := addBlob(t, owner.pk, []byte("on the phone, deleted on the Mac"))
	other := addBlob(t, owner.pk, []byte("kept on the phone"))
	_, real := copySyncPair(t, owner) // saves A's token for npub1peer
	a := &deletesA{fakeFilesA: &fakeFilesA{real: real, pageSize: 10}, deletes: deleteItems(blobDeleteAuth(t, owner, nostr.Now()+1, onB))}
	ts := httptest.NewServer(a)
	t.Cleanup(ts.Close)
	c := newCopyClient("npub1peer", ts.URL)
	c.notesOnly = true
	if _, err := c.sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if copyBlobFile(onB) != "" {
		t.Fatal("a light device kept a file the owner deleted")
	}
	if copyBlobFile(other) == "" {
		t.Fatal("a light device lost a file nobody deleted")
	}
}

// A device whose first copy set the notes mark still asks a peer for its
// whole delete list the first time, then only what is new.
func TestCopyFirstDeleteSwapWithAPeerTakesTheWholeList(t *testing.T) {
	owner := newTestKey(t)
	openDeletesVault(t, owner.pk)
	_, real := copySyncPair(t, owner)
	markCopySynced("npub1peer", time.Now().Unix()) // the first copy's mark
	a := &deletesA{fakeFilesA: &fakeFilesA{real: real, pageSize: 10}}
	ts := httptest.NewServer(a)
	t.Cleanup(ts.Close)
	for range 2 {
		if _, err := newCopyClient("npub1peer", ts.URL).sync(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if len(a.asked) != 2 || a.asked[0] != "0" || a.asked[1] == "0" {
		t.Fatalf("delete list asked since %v, want 0 then the mark", a.asked)
	}
}

// Tron #1997 D1: a delete reaches only as far as the original. Added
// account X deletes its own record of a photo the owner also holds: the
// other devices drop X's record and keep the owner's (and the file).
func TestCopyDeleteFromAnAccountRemovesOnlyItsRecord(t *testing.T) {
	owner, x := newTestKey(t), newTestKey(t)
	openDeletesVault(t, owner.pk)
	config.WhitelistedPubKeys[x.pk] = struct{}{}
	data := []byte("held by the owner and by X")
	sha := addBlob(t, owner.pk, data)
	addBlob(t, x.pk, data)
	_, call := copySyncServerFor(t, owner)
	body, _ := json.Marshal(copyDeleteList{Deletes: deleteItems(blobDeleteAuth(t, x, nostr.Now()+1, sha))})
	if rec := call(http.MethodPut, "/copy/v2/sync/deletes", body); rec.Code != 200 || !strings.Contains(rec.Body.String(), `"gone":0`) {
		t.Fatalf("PUT deletes: %d %s", rec.Code, rec.Body.String())
	}
	if copyBlobFile(sha) == "" {
		t.Fatal("X's delete removed the owner's file")
	}
	if n := countIn(t, blossomDB, nostr.Filter{Kinds: []int{24242}, Authors: []string{owner.pk}, Tags: nostr.TagMap{"x": []string{sha}}}); n != 1 {
		t.Fatalf("owner's record: %d, want 1", n)
	}
	if n := countIn(t, blossomDB, nostr.Filter{Kinds: []int{24242}, Authors: []string{x.pk}, Tags: nostr.TagMap{"x": []string{sha}}}); n != 0 {
		t.Fatalf("X's record: %d, want 0", n)
	}
	if list := call(http.MethodGet, "/copy/v2/sync/files?since=0", nil).Body.String(); !strings.Contains(list, sha) {
		t.Fatalf("the owner's file left the list: %s", list)
	}
	// Even a peer that claims the owner can't widen an account's delete.
	body, _ = json.Marshal(copyDeleteList{Deletes: []copyDeleteItem{{Ev: blobDeleteAuth(t, x, nostr.Now()+2, sha), Owner: owner.pk}}})
	call(http.MethodPut, "/copy/v2/sync/deletes", body)
	if copyBlobFile(sha) == "" {
		t.Fatal("a claimed owner widened X's delete")
	}
}

// A paired device's delete removes the owner's record, not another account's.
func TestCopyDeleteFromAPairedDeviceRemovesOnlyTheOwnersRecord(t *testing.T) {
	owner, x, vault, phone := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	openDeletesVault(t, owner.pk)
	pairMeshDevices(t, vault, phone)
	config.WhitelistedPubKeys[x.pk] = struct{}{}
	data := []byte("deleted from the phone")
	sha := addBlob(t, owner.pk, data)
	addBlob(t, x.pk, data)
	takeCopyDeletes(context.Background(), deleteItems(blobDeleteAuth(t, phone, nostr.Now()+1, sha)), "")
	if n := countIn(t, blossomDB, nostr.Filter{Kinds: []int{24242}, Authors: []string{owner.pk}, Tags: nostr.TagMap{"x": []string{sha}}}); n != 0 {
		t.Fatalf("owner's record: %d, want 0", n)
	}
	if copyBlobFile(sha) == "" || blobRecords(t, sha) != 1 {
		t.Fatal("the phone's delete reached X's record")
	}
}

// The signer's own p tag no longer makes a key a device here: a stranger
// naming this vault (or the sending peer) is refused, with or without a
// claimed account. Only the peer may vouch, and only for the owner.
func TestCopyDeleteSelfPickedPTagNoLongerWorks(t *testing.T) {
	owner, vault, stranger, peerDev := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	openDeletesVault(t, owner.pk)
	pairMeshDevices(t, vault)
	sha := addBlob(t, owner.pk, []byte("not the stranger's"))
	for _, p := range []string{vault.pk, peerDev.pk} {
		tags := nostr.Tags{{"t", "delete"}, {"x", sha}, {"p", p}}
		ev := stranger.sign(t, nostr.Event{Kind: 24242, CreatedAt: nostr.Now() + 1, Tags: tags})
		for _, claimed := range []string{"", stranger.pk} {
			if got := takeCopyDeletes(context.Background(), []copyDeleteItem{{Ev: &ev, Owner: claimed}}, peerDev.pk); got != 0 || copyBlobFile(sha) == "" {
				t.Fatalf("p=%s claimed=%q: the stranger's delete was taken", p[:8], claimed)
			}
		}
		if got := takeCopyDeletes(context.Background(), []copyDeleteItem{{Ev: &ev, Owner: owner.pk}}, ""); got != 0 || copyBlobFile(sha) == "" {
			t.Fatal("a claimed owner was taken with no peer to vouch")
		}
	}
	if len(copyDeletesSince(0)) != 0 {
		t.Fatal("a refused delete was kept")
	}
	// A device paired only to the peer: the peer filed it for the owner.
	ev := blobDeleteAuth(t, newTestKey(t), nostr.Now()+1, sha)
	if got := takeCopyDeletes(context.Background(), []copyDeleteItem{{Ev: ev, Owner: owner.pk}}, peerDev.pk); got != 1 {
		t.Fatal("a delete the peer vouched for was not taken")
	}
}

// Tron #1997 D2: DELETEs on the https port from any key, for hashes that
// aren't here, can't grow the pending map; an own account's are capped and
// expire.
func TestCopyPendingDeleteCannotGrow(t *testing.T) {
	owner, stranger := newTestKey(t), newTestKey(t)
	openDeletesVault(t, owner.pk)
	prevNow := copyPendingNow
	clock := time.Now()
	copyPendingNow = func() time.Time { return clock }
	copyPendingDeleteMu.Lock()
	copyPendingDelete = map[string]copyPending{}
	copyPendingDeleteMu.Unlock()
	t.Cleanup(func() {
		copyPendingNow = prevNow
		copyPendingDeleteMu.Lock()
		copyPendingDelete = map[string]copyPending{}
		copyPendingDeleteMu.Unlock()
	})
	pending := func() int {
		copyPendingDeleteMu.Lock()
		defer copyPendingDeleteMu.Unlock()
		return len(copyPendingDelete)
	}
	for range 2000 {
		sha := copyRandomHex(32)
		if reject, _, _ := noteCopyDeleteAuth(context.Background(), blobDeleteAuth(t, stranger, nostr.Now(), sha), sha, ""); reject {
			t.Fatal("the note hook refused")
		}
	}
	if n := pending(); n != 0 {
		t.Fatalf("a stranger's random DELETEs grew the map to %d", n)
	}
	for range 2000 {
		sha := copyRandomHex(32)
		noteCopyDeleteAuth(context.Background(), blobDeleteAuth(t, owner, nostr.Now(), sha), sha, "")
	}
	if n := pending(); n > copyPendingDeleteMax {
		t.Fatalf("an account's DELETEs grew the map to %d (cap %d)", n, copyPendingDeleteMax)
	}
	clock = clock.Add(copyPendingDeleteTTL + time.Second)
	sha := copyRandomHex(32)
	noteCopyDeleteAuth(context.Background(), blobDeleteAuth(t, owner, nostr.Now(), sha), sha, "")
	if n := pending(); n != 1 {
		t.Fatalf("expired entries stayed: %d", n)
	}
}

// The list is read from disk once per write, not per file (Tron #1997 S).
func TestCopyDeletesListIsCachedUntilWritten(t *testing.T) {
	owner := newTestKey(t)
	openDeletesVault(t, owner.pk)
	sha := addBlob(t, owner.pk, []byte("cached"))
	keepCopyDelete(blobDeleteAuth(t, owner, nostr.Now()+1, sha), owner.pk, time.Now())
	copyDeletesMu.Lock()
	first := loadCopyDeletes()
	second := loadCopyDeletes()
	copyDeletesMu.Unlock()
	if len(first) != 1 || fmt.Sprintf("%p", first) != fmt.Sprintf("%p", second) {
		t.Fatal("the delete list was parsed again with no write between")
	}
	other := addBlob(t, owner.pk, []byte("second"))
	keepCopyDelete(blobDeleteAuth(t, owner, nostr.Now()+1, other), owner.pk, time.Now())
	if d := copyDeletedAt(); len(d) != 2 {
		t.Fatalf("after a write: %d deletes, want 2", len(d))
	}
}
