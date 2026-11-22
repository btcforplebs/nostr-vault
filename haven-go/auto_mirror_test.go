//go:build !(js && wasm)

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

func shaOf(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

// fakeBlossom serves /list/<pk>, /<sha> and named files, and counts hits.
type fakeBlossom struct {
	mu      sync.Mutex
	srv     *httptest.Server
	blobs   map[string][]byte // sha -> bytes, listed for owner
	named   map[string][]byte // path -> bytes (not hash-named)
	hits    map[string]int
	sawAuth bool
	listErr int
}

func newFakeBlossom(t *testing.T) *fakeBlossom {
	f := &fakeBlossom{blobs: map[string][]byte{}, named: map[string][]byte{}, hits: map[string]int{}}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.hits[r.URL.Path]++
		if r.Header.Get("Authorization") != "" {
			f.sawAuth = true
		}
		if strings.HasPrefix(r.URL.Path, "/list/") {
			if f.listErr != 0 {
				w.WriteHeader(f.listErr)
				return
			}
			var out []blobListEntry
			for sha := range f.blobs {
				out = append(out, blobListEntry{SHA256: sha, Type: "image/jpeg"})
			}
			json.NewEncoder(w).Encode(out)
			return
		}
		if b, ok := f.named[r.URL.Path]; ok {
			w.Header().Set("Content-Type", "image/jpeg")
			w.Write(b)
			return
		}
		name := strings.TrimPrefix(r.URL.Path, "/")
		if i := strings.IndexByte(name, '.'); i >= 0 {
			name = name[:i]
		}
		if b, ok := f.blobs[name]; ok {
			w.Header().Set("Content-Type", "image/jpeg")
			w.Write(b)
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeBlossom) hitsOn(p string) int { f.mu.Lock(); defer f.mu.Unlock(); return f.hits[p] }

// memVault is the vault side of a run: what is stored, by whom.
type memVault struct {
	mu     sync.Mutex
	stored map[string]string // sha -> account that downloaded it
	owners map[string]bool   // pubkey+sha: a record claimed for a file already here
	notes  []*nostr.Event
}

func (v *memVault) deps(t *testing.T, f *fakeBlossom, accounts ...string) autoMirrorDeps {
	dir := t.TempDir()
	return autoMirrorDeps{
		client:   f.srv.Client(),
		accounts: func() []string { return accounts },
		servers:  func(context.Context, string) []string { return []string{f.srv.URL} },
		notes: func(_ context.Context, pk string, until nostr.Timestamp) []*nostr.Event {
			var out []*nostr.Event
			for _, ev := range v.notes {
				if ev.PubKey == pk && (until == 0 || ev.CreatedAt <= until) {
					out = append(out, ev)
				}
			}
			return out
		},
		stored: func(sha string) bool { v.mu.Lock(); defer v.mu.Unlock(); _, ok := v.stored[sha]; return ok },
		store: func(_ context.Context, pk, file, sha, _ string) error {
			b, err := os.ReadFile(file)
			if err != nil || shaOf(b) != sha {
				return fmt.Errorf("bad file")
			}
			v.mu.Lock()
			v.stored[sha] = pk
			v.mu.Unlock()
			return nil
		},
		claim: func(_ context.Context, pk, sha string) (bool, error) {
			v.mu.Lock()
			defer v.mu.Unlock()
			if v.owners == nil {
				v.owners = map[string]bool{}
			}
			if v.stored[sha] == pk || v.owners[pk+sha] {
				return false, nil
			}
			v.owners[pk+sha] = true
			return true, nil
		},
		owns: func(pk, sha string) bool {
			v.mu.Lock()
			defer v.mu.Unlock()
			return v.stored[sha] == pk || v.owners[pk+sha]
		},
		room:    func() int64 { return maxBlobBytes },
		tempDir: dir,
		links:   loadAutoMirrorLinks(filepath.Join(dir, "links.json")),
		log:     func(string, ...any) {},
	}
}

func allowLoopback(t *testing.T) {
	old := forwardHostRefused
	forwardHostRefused = func(string) bool { return false }
	t.Cleanup(func() { forwardHostRefused = old })
}

func TestAutoMirrorDue(t *testing.T) {
	h := int64(3600)
	for _, c := range []struct {
		last, now int64
		want      bool
	}{{0, 100, true}, {1000, 1000 + 3*h - 1, false}, {1000, 1000 + 3*h, true}, {1000, 500, true}} {
		if got := autoMirrorDue(c.last, c.now); got != c.want {
			t.Errorf("due(%d,%d)=%v", c.last, c.now, got)
		}
	}
	off := autoMirrorSettings{Enabled: false, RunNowAt: 99}
	if run, _ := autoMirrorShouldRun(off, autoMirrorState{}, 100); run {
		t.Error("runs while off")
	}
	on := autoMirrorSettings{Enabled: true, RunNowAt: 99}
	if run, now := autoMirrorShouldRun(on, autoMirrorState{LastStart: 90, HandledRunNow: 50}, 100); !run || !now {
		t.Error("run now skips the 3 h wait")
	}
	if run, _ := autoMirrorShouldRun(on, autoMirrorState{LastStart: 90, HandledRunNow: 99}, 100); run {
		t.Error("a handled run now runs again")
	}
}

func TestNoteMediaLinksAndPicker(t *testing.T) {
	allowLoopback(t)
	sha := strings.Repeat("ab", 32)
	ev := &nostr.Event{Content: "look https://a.example/x.jpg and https://b.example/" + sha + " and https://c.example/page, https://a.example/x.jpg.",
		Tags: nostr.Tags{{"imeta", "url https://d.example/clip", "x " + strings.ToUpper(sha)}}}
	links := noteMediaLinks(ev)
	want := []string{"https://d.example/clip", "https://a.example/x.jpg", "https://b.example/" + sha}
	if strings.Join(links, " ") != strings.Join(want, " ") {
		t.Fatalf("links %v", links)
	}
	if imetaHashes(ev.Tags)["https://d.example/clip"] != sha {
		t.Fatal("imeta x lower-cased")
	}
	forwardHostRefused = forwardHostIsPrivate
	p := newLinkPicker(func(s string) bool { return s == strings.Repeat("cd", 32) })
	if p.offer("http://localhost/a.jpg", nil) || p.offer("http://192.168.1.2/a.jpg", nil) || p.offer("ftp://x.example/a.jpg", nil) {
		t.Fatal("private or non-http link picked")
	}
	if p.offer("https://x.example/"+strings.Repeat("cd", 32)+".png", nil) {
		t.Fatal("stored hash picked (rule 1)")
	}
	if !p.offer("https://b.example/"+sha, nil) || p.offer("https://other.example/x", func(string) string { return sha }) {
		t.Fatal("two links to one hash are one download")
	}
	if p.offer("https://b.example/"+sha, nil) {
		t.Fatal("same link twice")
	}
}

func TestAutoMirrorLinksLedger(t *testing.T) {
	file := filepath.Join(t.TempDir(), "l.json")
	l := loadAutoMirrorLinks(file)
	for i := 0; i < autoMirrorLinksMax+5; i++ {
		l.remember(fmt.Sprintf("https://x/%d", i), strings.Repeat("ab", 32))
	}
	l.remember("https://x/bad", "nothex")
	if err := l.save(file); err != nil {
		t.Fatal(err)
	}
	back := loadAutoMirrorLinks(file)
	if len(back.order) != autoMirrorLinksMax || back.hashFor("https://x/0") != "" || back.hashFor(fmt.Sprintf("https://x/%d", autoMirrorLinksMax+4)) == "" {
		t.Fatalf("kept %d, oldest dropped first", len(back.order))
	}
}

// A run fetches what the server lists and the notes link, never a stored
// file, signs nothing, files each under its account, and a second run
// downloads nothing (hash first, links remembered).
func TestAutoMirrorRun(t *testing.T) {
	allowLoopback(t)
	f := newFakeBlossom(t)
	owner, other := strings.Repeat("11", 32), strings.Repeat("22", 32)
	listed, held := []byte("listed photo"), []byte("already here")
	f.blobs[shaOf(listed)] = listed
	f.blobs[shaOf(held)] = held
	f.named["/pics/beach.jpg"] = []byte("beach, linked by name only")
	v := &memVault{stored: map[string]string{shaOf(held): owner}}
	v.notes = []*nostr.Event{
		{ID: "n1", PubKey: other, CreatedAt: 200, Content: "beach " + f.srv.URL + "/pics/beach.jpg"},
		{ID: "n2", PubKey: other, CreatedAt: 100, Content: "again " + f.srv.URL + "/" + shaOf(held) + ".jpg"},
	}
	d := v.deps(t, f, owner, other)
	res := runAutoMirror(context.Background(), d)
	// 2 downloads, plus other's claim on the owner's copy of held.
	if res.Saved != 3 || res.Skipped != 0 || len(res.Unreachable) != 0 {
		t.Fatalf("run 1: %+v", res)
	}
	if !v.owners[other+shaOf(held)] {
		t.Fatal("other's link to a file already here added no record for other")
	}
	if v.stored[shaOf(listed)] != owner || v.stored[shaOf([]byte("beach, linked by name only"))] != other {
		t.Fatalf("stored under the wrong account: %v", v.stored)
	}
	// held is fetched once in all: other's proof (the fake lists it for
	// other too); the owner, who holds it, fetches nothing.
	if f.hitsOn("/"+shaOf(held))+f.hitsOn("/"+shaOf(held)+".jpg") != 1 || !v.owners[other+shaOf(held)] || v.stored[shaOf(held)] != owner {
		t.Fatalf("held hits: list %d, other's link %d", f.hitsOn("/"+shaOf(held)), f.hitsOn("/"+shaOf(held)+".jpg"))
	}
	if f.sawAuth {
		t.Fatal("a box run sent an Authorization header: it has nothing to sign with")
	}
	before := f.hitsOn("/pics/beach.jpg")
	// The fake lists every file for every account, so run 2 proves for
	// other the file run 1 was downloading for owner (one more fetch).
	hits := f.hitsOn("/" + shaOf(listed))
	res = runAutoMirror(context.Background(), d)
	if res.Saved != 1 || !v.owners[other+shaOf(listed)] || f.hitsOn("/pics/beach.jpg") != before || f.hitsOn("/"+shaOf(listed)) != hits+1 {
		t.Fatalf("run 2: %+v, beach hits %d", res, f.hitsOn("/pics/beach.jpg"))
	}
	if res = runAutoMirror(context.Background(), d); res.Saved != 0 {
		t.Fatalf("run 3 did something: %+v", res)
	}
}

// At most 200 downloads per run; the rest come next run.
func TestAutoMirrorCap(t *testing.T) {
	allowLoopback(t)
	f := newFakeBlossom(t)
	for i := 0; i < 250; i++ {
		b := []byte(fmt.Sprintf("file %d", i))
		f.blobs[shaOf(b)] = b
	}
	v := &memVault{stored: map[string]string{}}
	d := v.deps(t, f, strings.Repeat("11", 32))
	res := runAutoMirror(context.Background(), d)
	if res.Saved != autoMirrorMaxPerRun || !res.CapReached {
		t.Fatalf("run 1: %+v", res)
	}
	res = runAutoMirror(context.Background(), d)
	if res.Saved != 50 || res.CapReached {
		t.Fatalf("run 2: %+v", res)
	}
}

// A file that is not the one its hash names is not stored; a list the
// server will not give without a signature is reported, not retried.
func TestAutoMirrorRefusals(t *testing.T) {
	allowLoopback(t)
	f := newFakeBlossom(t)
	real := []byte("real")
	fake := strings.Repeat("ef", 32)
	f.blobs[fake] = real // served under a hash it does not have
	v := &memVault{stored: map[string]string{}}
	res := runAutoMirror(context.Background(), v.deps(t, f, strings.Repeat("11", 32)))
	if res.Saved != 0 || res.Skipped != 1 || len(v.stored) != 0 {
		t.Fatalf("mismatch stored: %+v %v", res, v.stored)
	}
	f.listErr = http.StatusUnauthorized
	res = runAutoMirror(context.Background(), v.deps(t, f, strings.Repeat("11", 32)))
	if len(res.Unreachable) != 1 || res.Saved != 0 {
		t.Fatalf("401 list: %+v", res)
	}
}

// The tick keeps rule 3 on disk: one run per 3 h from its start, run now
// once, nothing while off, and a start written before anything is fetched.
func TestAutoMirrorTick(t *testing.T) {
	allowLoopback(t)
	dir := t.TempDir()
	wd, _ := os.Getwd()
	os.Chdir(dir)
	t.Cleanup(func() { os.Chdir(wd) })

	f := newFakeBlossom(t)
	v := &memVault{stored: map[string]string{}}
	runs := 0
	var startOnDisk int64
	deps := func() autoMirrorDeps {
		runs++
		var st autoMirrorState
		readJSONFile(autoMirrorStateFile, &st)
		startOnDisk = st.LastStart
		return v.deps(t, f, strings.Repeat("11", 32))
	}
	clock := time.Unix(1_000_000, 0)
	now := func() time.Time { return clock }
	tick := func() { autoMirrorTick(context.Background(), now, deps) }

	tick()
	if runs != 0 {
		t.Fatal("ran with no settings file (a Mac or phone engine)")
	}
	writeJSONFile(autoMirrorSettingsFile, autoMirrorSettings{Enabled: false})
	tick()
	if runs != 0 {
		t.Fatal("ran while off")
	}
	writeJSONFile(autoMirrorSettingsFile, autoMirrorSettings{Enabled: true})
	tick()
	if runs != 1 || startOnDisk != clock.Unix() {
		t.Fatalf("first run: runs %d, start on disk %d", runs, startOnDisk)
	}
	clock = clock.Add(2 * time.Hour)
	tick()
	if runs != 1 {
		t.Fatal("ran again inside 3 h")
	}
	writeJSONFile(autoMirrorSettingsFile, autoMirrorSettings{Enabled: true, RunNowAt: clock.Unix()})
	tick()
	tick()
	if runs != 2 {
		t.Fatalf("run now: %d runs, want exactly one more", runs)
	}
	clock = clock.Add(3 * time.Hour)
	tick()
	if runs != 3 {
		t.Fatal("did not run 3 h after the last start")
	}
	var st autoMirrorState
	readJSONFile(autoMirrorStateFile, &st)
	if st.Running || st.Last == nil || st.LastFinish != clock.Unix() {
		t.Fatalf("state: %+v", st)
	}
}
