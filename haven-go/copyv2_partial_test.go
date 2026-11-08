package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Health audit fix #1 (2026-11-08): mesh copy v2 says done only when
// everything it carried is here. Before, a store or file B failed to write
// was only logged; B told A to delete its zip, deleted its own parts and
// marked the peer synced, and the 7-day catch-up window never reached the
// gap again. Throwaway keys only.

// failingDB fails every write while fail is set: a full disk or a store
// error on B.
type failingDB struct {
	DBBackend
	fail atomic.Bool
}

func (f *failingDB) SaveEvent(ctx context.Context, ev *nostr.Event) error {
	if f.fail.Load() {
		return errors.New("disk full")
	}
	return f.DBBackend.SaveEvent(ctx, ev)
}

func (f *failingDB) ReplaceEvent(ctx context.Context, ev *nostr.Event) error {
	if f.fail.Load() {
		return errors.New("disk full")
	}
	return f.DBBackend.ReplaceEvent(ctx, ev)
}

// copyFromA serves a prebuilt copy (buildOnA) from A's own directory, with
// the manifest changed by edit. Returns the server, A's cache dir, and a
// counter of chunk requests.
func copyFromA(t *testing.T, srcDir string, built copyManifest, edit func(*copyManifest)) (*httptest.Server, string, *atomic.Int64) {
	t.Helper()
	aWD, _ := os.Getwd()
	s := newTestCopyServer(func(dir, id string, p copyBuildProgress) (copyManifest, error) {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return copyManifest{}, err
		}
		for _, n := range []string{"notes.zip", "media.zip"} {
			raw, err := os.ReadFile(filepath.Join(srcDir, n))
			if err != nil {
				return copyManifest{}, err
			}
			if err := os.WriteFile(filepath.Join(dir, n), raw, 0o600); err != nil {
				return copyManifest{}, err
			}
		}
		m := built
		m.ID = id
		if edit != nil {
			edit(&m)
		}
		return m, nil
	})
	s.cacheDir = filepath.Join(aWD, copyCacheDir)
	var chunks atomic.Int64
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "" {
			chunks.Add(1)
		}
		s.ServeHTTP(w, r)
	}))
	t.Cleanup(ts.Close)
	return ts, s.cacheDir, &chunks
}

func copyCacheEntries(dir string) int {
	entries, _ := os.ReadDir(dir)
	return len(entries)
}

// A store B fails to write: the copy is partial, not done. A keeps its zip,
// B keeps its parts and state, the peer is not marked synced. The next
// attempt restores from the parts B kept, with no chunk fetched again.
func TestCopyPartialRestoreKeepsTheCopyAndTriesAgain(t *testing.T) {
	owner, other := newTestKey(t), newTestKey(t)
	srcDir, built, noteID := buildOnA(t, owner, other, []byte("a photo"))
	ts, aCache, chunks := copyFromA(t, srcDir, built, nil)

	openCopyVault(t, owner.pk) // B
	copyPollEvery = 10 * time.Millisecond
	t.Cleanup(func() { copyPollEvery = 2 * time.Second })
	broken := &failingDB{DBBackend: outboxDB}
	broken.fail.Store(true)
	outboxDB = broken
	dbs["outbox"] = broken
	var logs bytes.Buffer
	captureLog(t, &logs)

	c := newCopyClient("npub1peer", ts.URL)
	c.free = func(string) (uint64, bool) { return 1 << 40, true }
	err := c.run(context.Background(), startProof(t, owner, nostr.Now(), "/copy/v2/start"))
	if copyErrorCode(err) != "partial" {
		t.Fatalf("a store B could not write: %v, want partial\n%s", err, logs.String())
	}
	if strings.Contains(logs.String(), "stage=done") {
		t.Fatalf("a partial copy said done:\n%s", logs.String())
	}
	if !strings.Contains(logs.String(), "stage=failed") || !strings.Contains(logs.String(), "partial") {
		t.Fatalf("no failed=partial line for the app:\n%s", logs.String())
	}
	if copyCacheEntries(aCache) == 0 {
		t.Fatal("A was told done and deleted its copy")
	}
	if _, err := os.Stat(filepath.Join(c.dir, "notes.zip")); err != nil {
		t.Fatalf("B deleted its parts: %v", err)
	}
	st := c.loadState()
	if st == nil || len(st.Partial) == 0 || st.Partial[0] != "outbox" {
		t.Fatalf("the state does not say what is missing: %+v", st)
	}
	if loadCopySync()[copyPeerKey("npub1peer")] != 0 {
		t.Fatal("a partial copy marked the peer synced: the catch-up would skip the gap")
	}

	// The disk has room again: the same copy finishes from B's parts.
	broken.fail.Store(false)
	fetched := chunks.Load()
	logs.Reset()
	c2 := newCopyClient("npub1peer", ts.URL)
	c2.free = c.free
	if err := c2.run(context.Background(), ""); err != nil {
		t.Fatalf("second attempt: %v\n%s", err, logs.String())
	}
	if chunks.Load() != fetched {
		t.Fatalf("the second attempt fetched %d chunks again", chunks.Load()-fetched)
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{noteID}}) != 1 {
		t.Fatal("A's note is still missing after the second attempt")
	}
	if !strings.Contains(logs.String(), "stage=done") {
		t.Fatalf("no done line:\n%s", logs.String())
	}
	if copyCacheEntries(aCache) != 0 {
		t.Fatal("A kept its copy after a done copy")
	}
	if loadCopySync()[copyPeerKey("npub1peer")] == 0 {
		t.Fatal("a done copy did not mark the peer synced")
	}
}

// A file the copy did not carry (the manifest counts it, the zip lacks it)
// can't come from the same zip: the copy is done, but the peer is not marked
// synced, so the first catch-up compares everything and asks A for it.
func TestCopyLeftOutFileLeavesTheCatchUpWindowOpen(t *testing.T) {
	owner, other := newTestKey(t), newTestKey(t)
	srcDir, built, _ := buildOnA(t, owner, other, []byte("a photo"))
	ts, _, _ := copyFromA(t, srcDir, built, func(m *copyManifest) { m.Files.Count++ })

	openCopyVault(t, owner.pk) // B
	copyPollEvery = 10 * time.Millisecond
	t.Cleanup(func() { copyPollEvery = 2 * time.Second })
	var logs bytes.Buffer
	captureLog(t, &logs)
	c := newCopyClient("npub1peer", ts.URL)
	c.free = func(string) (uint64, bool) { return 1 << 40, true }
	if err := c.run(context.Background(), startProof(t, owner, nostr.Now(), "/copy/v2/start")); err != nil {
		t.Fatalf("%v\n%s", err, logs.String())
	}
	if !strings.Contains(logs.String(), "left_out=1") {
		t.Fatalf("the done line does not say a file was left out:\n%s", logs.String())
	}
	if loadCopySync()[copyPeerKey("npub1peer")] != 0 {
		t.Fatal("a copy missing a file marked the peer synced: the catch-up would never ask for it")
	}
}

// fakeFilesA answers the catch-up's file list in pages of pageSize, newest
// first, honouring until (inclusive) unless ignoreUntil, and serves the
// files' bytes. Every other path goes to the real copy server.
type fakeFilesA struct {
	real        http.Handler
	files       []copyFile // newest first
	data        map[string][]byte
	pageSize    int
	ignoreUntil bool
	pages       atomic.Int64
}

func (f *fakeFilesA) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/copy/v2/sync/files":
		f.pages.Add(1)
		until, _ := strconv.ParseInt(r.URL.Query().Get("until"), 10, 64)
		after := r.URL.Query().Get("after")
		var out []copyFile
		for _, file := range f.files {
			if !f.ignoreUntil && until > 0 && (file.CreatedAt > until || (file.CreatedAt == until && file.SHA256 <= after)) {
				continue
			}
			out = append(out, file)
		}
		more := len(out) > f.pageSize
		if more {
			out = out[:f.pageSize]
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"files": out, "more": more})
	case strings.HasPrefix(r.URL.Path, "/copy/v2/sync/file/"):
		data, ok := f.data[strings.TrimPrefix(r.URL.Path, "/copy/v2/sync/file/")]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(data)
	default:
		f.real.ServeHTTP(w, r)
	}
}

func catchUpWithFakeFiles(t *testing.T, n, pageSize int, ignoreUntil bool) (*fakeFilesA, []string) {
	t.Helper()
	owner := newTestKey(t)
	openCopyVault(t, owner.pk) // B
	aDir := t.TempDir()
	aStores := map[string]DBBackend{}
	for _, name := range copySyncStores {
		db := fallbackBackend(filepath.Join(aDir, name))
		if err := db.Init(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(db.Close)
		aStores[name] = db
	}
	s := newTestCopyServer(nil)
	s.syncDB = func(name string) DBBackend { return aStores[name] }
	token := copyRandomHex(32)
	s.tokens = []copyToken{{Hash: copyHashToken(token), Owner: owner.pk, Created: time.Now().Unix(), LastUsed: time.Now().Unix()}}
	s.loaded = true
	fake := &fakeFilesA{real: s, data: map[string][]byte{}, pageSize: pageSize, ignoreUntil: ignoreUntil}
	var shas []string
	now := time.Now().Unix()
	for i := 0; i < n; i++ {
		data := []byte(fmt.Sprintf("own file %d", i))
		sum := sha256.Sum256(data)
		sha := hex.EncodeToString(sum[:])
		fake.data[sha] = data
		// Two files a second: a page edge can fall inside a second.
		fake.files = append(fake.files, copyFile{SHA256: sha, Pubkey: owner.pk, Type: "image/jpeg",
			Size: strconv.Itoa(len(data)), CreatedAt: now - int64(i/2)})
		shas = append(shas, sha)
	}
	sort.Slice(fake.files, func(i, j int) bool {
		if fake.files[i].CreatedAt != fake.files[j].CreatedAt {
			return fake.files[i].CreatedAt > fake.files[j].CreatedAt
		}
		return fake.files[i].SHA256 < fake.files[j].SHA256
	})
	ts := httptest.NewServer(fake)
	t.Cleanup(ts.Close)
	saveCopyPeerToken("npub1peer", token)
	if _, err := newCopyClient("npub1peer", ts.URL).sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	return fake, shas
}

// More own files than one list page: the catch-up pages back through all of
// them before it moves its cursor.
func TestCopyCatchUpPagesThroughEveryOwnFile(t *testing.T) {
	fake, shas := catchUpWithFakeFiles(t, 11, 3, false)
	missing := 0
	for _, sha := range shas {
		if copyBlobFile(sha) == "" {
			missing++
		}
	}
	if missing > 0 {
		t.Fatalf("%d of %d own files never came (%d list pages asked)", missing, len(shas), fake.pages.Load())
	}
	if loadCopySync()[copyPeerKey("npub1peer")] == 0 {
		t.Fatal("a catch-up that read every page did not save its cursor")
	}
}

// An A that ignores until sends the same page again: the catch-up stops
// (no loop) and does not move its cursor, so older files stay in reach.
func TestCopyCatchUpDoesNotMoveItsCursorPastFilesItCouldNotList(t *testing.T) {
	fake, _ := catchUpWithFakeFiles(t, 11, 3, true)
	if fake.pages.Load() > 3 {
		t.Fatalf("asked %d pages of an A that never pages", fake.pages.Load())
	}
	if loadCopySync()[copyPeerKey("npub1peer")] != 0 {
		t.Fatal("the cursor moved past files the catch-up could not list")
	}
}

// A's side: the file list pages by until (inclusive) and says when there is
// more.
func TestCopyOwnFilesListPages(t *testing.T) {
	owner := newTestKey(t)
	openCopyVault(t, owner.pk)
	for i := 0; i < copySyncMaxFiles+3; i++ {
		addBlob(t, owner.pk, []byte(fmt.Sprintf("file %d", i)))
	}
	first, more, err := copyOwnFilesSince(context.Background(), 0, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != copySyncMaxFiles || !more {
		t.Fatalf("first page: %d files, more=%v", len(first), more)
	}
	// Every file here shares one second: the cursor carries the sha256 too.
	last := first[len(first)-1]
	rest, more, err := copyOwnFilesSince(context.Background(), 0, last.CreatedAt, last.SHA256)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, f := range append(first, rest...) {
		seen[f.SHA256] = true
	}
	if more || len(rest) != 3 || len(seen) != copySyncMaxFiles+3 {
		t.Fatalf("second page: %d files, more=%v; %d of %d seen", len(rest), more, len(seen), copySyncMaxFiles+3)
	}
}
