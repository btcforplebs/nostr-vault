//go:build !(js && wasm)

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
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

	body, _ := json.Marshal(copyDeleteList{Deletes: []*nostr.Event{blobDeleteAuth(t, owner, nostr.Now()+1, gone)}})
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
	keepCopyDelete(blobDeleteAuth(t, owner, nostr.Now()+1, sha), time.Now())
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
	body, _ := json.Marshal(copyDeleteList{Deletes: []*nostr.Event{blobDeleteAuth(t, owner, nostr.Now()-3600, sha)}})
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
		body, _ := json.Marshal(copyDeleteList{Deletes: []*nostr.Event{ev}})
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
	if got := copyDeletesSince(0); len(got) != 1 || got[0].ID != auth.ID {
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
	deletes []*nostr.Event
	got     []*nostr.Event
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
	keepCopyDelete(mine, time.Now())

	_, real := copySyncPair(t, owner) // saves A's token for npub1peer
	a := &deletesA{
		fakeFilesA: &fakeFilesA{real: real, pageSize: 10, data: map[string][]byte{back: backData},
			files: []copyFile{{SHA256: back, Pubkey: owner.pk, Type: "image/jpeg", Size: strconv.Itoa(len(backData)), CreatedAt: time.Now().Unix() - 60}}},
		deletes: []*nostr.Event{blobDeleteAuth(t, owner, nostr.Now()+1, onB)},
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
	if len(a.got) != 1 || a.got[0].ID != mine.ID {
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
	a := &deletesA{fakeFilesA: &fakeFilesA{real: real, pageSize: 10}, deletes: []*nostr.Event{blobDeleteAuth(t, owner, nostr.Now()+1, onB)}}
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
