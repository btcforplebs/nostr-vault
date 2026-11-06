//go:build !(js && wasm)

package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

// copyVault: one vault's stores wired into the package globals, in its own
// working dir (blobs under blossom/). Throwaway keys only.
type copyVault struct {
	dir string
}

func openCopyVault(t *testing.T, owner string) *copyVault {
	t.Helper()
	dir := t.TempDir()
	prevCfg, prevDBs := config, dbs
	prevOut, prevPriv, prevIn, prevFeed, prevBlob, prevChat := outboxDB, privateDB, inboxDB, feedDB, blossomDB, chatDB
	prevLists, prevListsImport := listsDB, listsImportDB
	prevWD, _ := os.Getwd()
	t.Cleanup(func() {
		config, dbs = prevCfg, prevDBs
		outboxDB, privateDB, inboxDB, feedDB, blossomDB, chatDB = prevOut, prevPriv, prevIn, prevFeed, prevBlob, prevChat
		listsDB, listsImportDB = prevLists, prevListsImport
		_ = os.Chdir(prevWD)
	})
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	setupSyncConfig(owner)
	config.OwnerPubKey = owner
	config.BlossomPath = "blossom/"
	if err := os.MkdirAll("blossom", 0o755); err != nil {
		t.Fatal(err)
	}
	open := func(name string) DBBackend {
		db := fallbackBackend(filepath.Join(dir, "db", name))
		if err := db.Init(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(db.Close)
		return db
	}
	outboxDB, privateDB, chatDB, inboxDB, blossomDB, feedDB = open("outbox"), open("private"), open("chat"), open("inbox"), open("blossom"), open("feed")
	listsDB, listsImportDB = nil, nil
	dbs = map[string]DBBackend{"outbox": outboxDB, "private": privateDB, "chat": chatDB, "inbox": inboxDB, "blossom": blossomDB, "feed": feedDB}
	return &copyVault{dir: dir}
}

// addBlob stores a file and its blob record, as an upload by uploader would.
func addBlob(t *testing.T, uploader string, data []byte) string {
	t.Helper()
	sum := sha256.Sum256(data)
	sha := hex.EncodeToString(sum[:])
	if err := os.WriteFile(config.BlossomPath+sha, data, 0o644); err != nil {
		t.Fatal(err)
	}
	rec := &nostr.Event{PubKey: uploader, Kind: 24242, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"x", sha}, {"type", "image/jpeg"}, {"size", fmt.Sprint(len(data))}}}
	rec.ID = rec.GetID()
	if err := blossomDB.SaveEvent(context.Background(), rec); err != nil {
		t.Fatal(err)
	}
	return sha
}

func saveEv(t *testing.T, db DBBackend, ev nostr.Event) {
	t.Helper()
	if err := db.SaveEvent(context.Background(), &ev); err != nil {
		t.Fatal(err)
	}
}

func countIn(t *testing.T, db DBBackend, f nostr.Filter) int {
	t.Helper()
	ch, err := db.QueryEvents(eventstore.SetNegentropy(context.Background()), f)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for range ch {
		n++
	}
	return n
}

func zipNames(t *testing.T, path string) map[string]*zip.File {
	t.Helper()
	zr, err := zip.OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { zr.Close() })
	out := map[string]*zip.File{}
	for _, f := range zr.File {
		out[f.Name] = f
	}
	return out
}

// startProof: the owner's NIP-98 for POST /copy/v2/start.
func startProof(t *testing.T, k testKey, at nostr.Timestamp, path string) string {
	t.Helper()
	ev := k.sign(t, nostr.Event{Kind: 27235, CreatedAt: at, Tags: nostr.Tags{{"u", "http://127.0.0.1:9/" + strings.TrimPrefix(path, "/")}, {"method", "POST"}, {"device", testDevice}}})
	raw, _ := json.Marshal(ev)
	return base64.StdEncoding.EncodeToString(raw)
}

// ─── audit #14, #15, #7 ────────────────────────────────────────────────────

// #14: a relay could file a real owner note under a made-up id; Mac sync and
// catch-up stored it.
func TestSyncedOwnerEventMustCarryItsOwnID(t *testing.T) {
	k := newTestKey(t)
	openCopyVault(t, k.pk)
	ctx := context.Background()
	out := &outboxNegStore{outbox: eventstore.RelayWrapper{Store: outboxDB}}
	real := k.sign(t, nostr.Event{Kind: 1, Content: "mine"})
	forged := real
	forged.ID = hex.EncodeToString(bytes.Repeat([]byte{0xab}, 32))
	if err := out.Publish(ctx, forged); err != nil {
		t.Fatal(err)
	}
	processOwnerEvent(ctx, nostr.RelayEvent{Event: &forged}, eventstore.RelayWrapper{Store: outboxDB})
	if n := countIn(t, outboxDB, nostr.Filter{}); n != 0 {
		t.Fatalf("a note under a made-up id was stored (%d)", n)
	}
	if err := out.Publish(ctx, real); err != nil {
		t.Fatal(err)
	}
	if n := countIn(t, outboxDB, nostr.Filter{IDs: []string{real.ID}}); n != 1 {
		t.Fatal("positive control: the real note was not stored")
	}
}

// #15: a note whose kind 5 is already here (a restore put both in) is never
// uploaded again.
func TestNegentropyUploadSkipsDeletedNotes(t *testing.T) {
	k := newTestKey(t)
	openCopyVault(t, k.pk)
	ctx := context.Background()
	note := k.sign(t, nostr.Event{Kind: 1, Content: "gone"})
	keep := k.sign(t, nostr.Event{Kind: 1, Content: "kept"})
	saveEv(t, outboxDB, note)
	saveEv(t, outboxDB, keep)
	up := func() map[string]bool {
		out := &outboxNegStore{outbox: eventstore.RelayWrapper{Store: outboxDB}}
		ch, err := out.QueryEvents(ctx, nostr.Filter{})
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]bool{}
		for ev := range ch {
			got[ev.ID] = true
		}
		return got
	}
	if !up()[note.ID] {
		t.Fatal("positive control: the note was not offered before its deletion")
	}
	saveEv(t, outboxDB, k.sign(t, nostr.Event{Kind: 5, Tags: nostr.Tags{{"e", note.ID}}}))
	got := up()
	if got[note.ID] {
		t.Fatal("a deleted note was offered for upload")
	}
	if !got[keep.ID] {
		t.Fatal("an unrelated note was held back")
	}
}

// #7: a second holding more than a page (1000) of events is exported whole.
func TestExportKeepsASecondBusierThanAPage(t *testing.T) {
	k := newTestKey(t)
	openCopyVault(t, k.pk)
	at := nostr.Now() - 100
	for i := 0; i < 1300; i++ {
		saveEv(t, outboxDB, k.sign(t, nostr.Event{Kind: 1, CreatedAt: at, Content: fmt.Sprint("same second ", i)}))
	}
	for i := 0; i < 50; i++ {
		saveEv(t, outboxDB, k.sign(t, nostr.Event{Kind: 1, CreatedAt: at - nostr.Timestamp(i+1), Content: fmt.Sprint("before ", i)}))
	}
	var buf bytes.Buffer
	if err := exportDB(context.Background(), outboxDB, &buf); err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(buf.String(), "\n"); n != 1350 {
		t.Fatalf("export wrote %d of 1350 events", n)
	}
}

// ─── A: the server ─────────────────────────────────────────────────────────

func newTestCopyServer(build func(dir, id string, p copyBuildProgress) (copyManifest, error)) *copyServer {
	return &copyServer{jobs: map[string]*copyJob{}, seen: map[string]time.Time{}, now: time.Now, build: build}
}

func TestCopyStartAuth(t *testing.T) {
	owner, other := newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	s := newTestCopyServer(func(dir, id string, p copyBuildProgress) (copyManifest, error) {
		return copyManifest{}, fmt.Errorf("not in this test")
	})
	post := func(auth string, hdr map[string]string) int {
		req := copyReq(http.MethodPost, "/copy/v2/start", nil)
		if auth != "" {
			req.Header.Set("Authorization", "Nostr "+auth)
		}
		for k, v := range hdr {
			req.Header.Set(k, v)
		}
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, req)
		return rec.Code
	}
	good := startProof(t, owner, nostr.Now(), "/copy/v2/start")
	cases := []struct {
		name string
		auth string
		hdr  map[string]string
		want int
	}{
		{"no proof", "", nil, 401},
		{"stale", startProof(t, owner, nostr.Now()-120, "/copy/v2/start"), nil, 401},
		{"other path", startProof(t, owner, nostr.Now(), "/copy/v2/x"), nil, 401},
		{"someone else", startProof(t, other, nostr.Now(), "/copy/v2/start"), nil, 403},
		{"through a public tunnel", good, map[string]string{"Cf-Connecting-Ip": "1.2.3.4"}, 404},
		{"the owner", good, nil, 200},
		{"the same proof again", good, nil, 401},
	}
	for _, c := range cases {
		if got := post(c.auth, c.hdr); got != c.want {
			t.Errorf("%s: %d, want %d", c.name, got, c.want)
		}
	}
	req := copyReq(http.MethodGet, "/copy/v2/abc", nil)
	req.Header.Set("Authorization", "Bearer "+strings.Repeat("0", 64))
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	if rec.Code != 401 {
		t.Errorf("unknown token: %d, want 401", rec.Code)
	}
}

func TestMeshDoorNeverServesTheCopy(t *testing.T) {
	for _, path := range []string{"/copy/v2/start", "/copy/v2/abc", "/copy/v2/sync/ids"} {
		req := copyReq(http.MethodPost, path, nil)
		rec := httptest.NewRecorder()
		meshHandler(rec, req)
		if rec.Code != http.StatusNotFound {
			t.Errorf("door %s: %d, want 404", path, rec.Code)
		}
	}
	// Through the web tunnel (Cloudflare headers) the copy port answers
	// nothing, even to a well-formed request.
	s := newTestCopyServer(nil)
	for _, hdr := range []string{"Cf-Connecting-Ip", "Cf-Ray"} {
		req := copyReq(http.MethodPost, "/copy/v2/start", nil)
		req.Header.Set(hdr, "1")
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, req)
		if rec.Code != http.StatusNotFound {
			t.Errorf("through the tunnel (%s): %d, want 404", hdr, rec.Code)
		}
	}
}

func TestCopyServesWholeChunksOnly(t *testing.T) {
	owner := newTestKey(t)
	openCopyVault(t, owner.pk)
	release := make(chan struct{})
	data := bytes.Repeat([]byte("x"), copyChunkSize+10)
	s := newTestCopyServer(func(dir, id string, p copyBuildProgress) (copyManifest, error) {
		<-release
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return copyManifest{}, err
		}
		if err := os.WriteFile(filepath.Join(dir, "notes.zip"), data, 0o600); err != nil {
			return copyManifest{}, err
		}
		part, err := hashCopyPart("notes", filepath.Join(dir, "notes.zip"))
		m := copyManifest{V: 2, ID: id, State: "ready", Owner: owner.pk, Parts: []copyPart{part}}
		m.ZipKey = copyZipKey(m.Parts)
		return m, err
	})
	req := copyReq(http.MethodPost, "/copy/v2/start", nil)
	req.Header.Set("Authorization", "Nostr "+startProof(t, owner, nostr.Now(), "/copy/v2/start"))
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	var started struct{ ID, Token string }
	_ = json.Unmarshal(rec.Body.Bytes(), &started)
	get := func(path, rng string) *httptest.ResponseRecorder {
		req := copyReq(http.MethodGet, path, nil)
		req.Header.Set("Authorization", "Bearer "+started.Token)
		if rng != "" {
			req.Header.Set("Range", rng)
		}
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, req)
		return rec
	}
	if c := get("/copy/v2/"+started.ID+"/notes", "bytes=0-4194303").Code; c != http.StatusConflict {
		t.Fatalf("while building: %d, want 409", c)
	}
	close(release)
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var m copyManifest
		_ = json.Unmarshal(get("/copy/v2/"+started.ID, "").Body.Bytes(), &m)
		if m.State == "ready" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	r := get("/copy/v2/"+started.ID+"/notes", "bytes=4194304-4194313")
	if r.Code != http.StatusPartialContent || !bytes.Equal(r.Body.Bytes(), data[copyChunkSize:]) {
		t.Fatalf("last chunk: %d, %d bytes", r.Code, r.Body.Len())
	}
	for _, rng := range []string{"bytes=1-4194304", "bytes=0-10", "bytes=8388608-8388610", "pieces"} {
		if c := get("/copy/v2/"+started.ID+"/notes", rng).Code; c != http.StatusRequestedRangeNotSatisfiable {
			t.Errorf("%s: %d, want 416", rng, c)
		}
	}
	req = copyReq(http.MethodPost, "/copy/v2/"+started.ID+"/done", nil)
	req.Header.Set("Authorization", "Bearer "+started.Token)
	s.ServeHTTP(httptest.NewRecorder(), req)
	if _, err := os.Stat(filepath.Join(copyCacheDir, started.ID)); !os.IsNotExist(err) {
		t.Fatal("done left A's copy on disk")
	}
	if c := get("/copy/v2/"+started.ID, "").Code; c != http.StatusNotFound {
		t.Fatalf("after done: %d, want 404", c)
	}
}

// ─── A: the build ──────────────────────────────────────────────────────────

func TestCopyBuildTakesOwnFilesAndSafeSettings(t *testing.T) {
	owner, other := newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	own := addBlob(t, owner.pk, []byte("my own photo"))
	saved := addBlob(t, owner.pk, []byte("a photo I saved from someone"))
	draft := addBlob(t, owner.pk, []byte("never posted"))
	theirs := addBlob(t, other.pk, []byte("their upload"))
	// The same file also has a newer record by someone else (read first):
	// it is still the owner's upload.
	rec := &nostr.Event{PubKey: other.pk, Kind: 24242, CreatedAt: nostr.Now() + 5, Tags: nostr.Tags{{"x", own}, {"type", "image/jpeg"}, {"size", "12"}}}
	rec.ID = rec.GetID()
	if err := blossomDB.SaveEvent(context.Background(), rec); err != nil {
		t.Fatal(err)
	}
	saveEv(t, outboxDB, owner.sign(t, nostr.Event{Kind: 1, Content: "look https://cdn.example/" + own + ".jpg"}))
	saveEv(t, outboxDB, owner.sign(t, nostr.Event{Kind: 1, Content: "https://cdn.example/" + theirs}))
	saveEv(t, feedDB, other.sign(t, nostr.Event{Kind: 1, Content: "https://cdn.example/" + saved}))
	saveEv(t, outboxDB, owner.sign(t, nostr.Event{Kind: 6, Content: `{"content":"https://cdn.example/` + saved + `"}`}))
	_ = os.WriteFile(copySettingsFile, []byte(`{"v":1,"updated_at":1,"keys":{"zaps_only":true}}`), 0o600)

	m, err := buildCopy(context.Background(), filepath.Join(copyCacheDir, "t1"), "t1", func(copyProgress) {})
	if err != nil {
		t.Fatal(err)
	}
	// Every file under the owner's own record is his (Logen, 2026-11-05):
	// posted, saved from someone else, never posted. Only a record by
	// another key stays out, even when an own note names it.
	if m.Settings != "included" || m.Files.Count != 3 {
		t.Fatalf("settings %q, files %d; want included, 3", m.Settings, m.Files.Count)
	}
	media := zipNames(t, filepath.Join(copyCacheDir, "t1", "media.zip"))
	for name, sha := range map[string]string{"own posted photo": own, "saved from someone else": saved, "draft": draft} {
		if media["media/"+sha] == nil {
			t.Errorf("%s left out", name)
		}
	}
	if media["media/"+theirs] != nil {
		t.Error("someone else's upload is in the media part")
	}
	notes := zipNames(t, filepath.Join(copyCacheDir, "t1", "notes.zip"))
	if notes["settings.json"] == nil {
		t.Fatal("safe settings left out")
	}
	rc, _ := notes["blossom.jsonl"].Open()
	raw, _ := io.ReadAll(rc)
	rc.Close()
	if strings.Count(string(raw), "\n") != 3 || strings.Contains(string(raw), theirs) {
		t.Fatalf("blob index not trimmed to the media part: %s", raw)
	}
	if copyZipKey(m.Parts) != m.ZipKey || copyManifestError(m, owner.pk, whitelist()) != "" {
		t.Fatalf("built manifest refused: %q", copyManifestError(m, owner.pk, whitelist()))
	}

	// A secret in the settings: the copy goes without them.
	_ = os.WriteFile(copySettingsFile, []byte(`{"v":1,"updated_at":1,"keys":{"dm_relays":["nsec1`+strings.Repeat("q", 58)+`"]}}`), 0o600)
	m, err = buildCopy(context.Background(), filepath.Join(copyCacheDir, "t2"), "t2", func(copyProgress) {})
	if err != nil {
		t.Fatal(err)
	}
	if m.Settings != "refused" || zipNames(t, filepath.Join(copyCacheDir, "t2", "notes.zip"))["settings.json"] != nil {
		t.Fatalf("secret-bearing settings: %q, want refused and not in the zip", m.Settings)
	}
}

// ─── A to B, end to end ────────────────────────────────────────────────────

// buildOnA builds a real copy in A's vault and returns its directory and
// manifest; the server stub serves it as if it were just built.
func buildOnA(t *testing.T, owner, other testKey, big []byte) (dir string, m copyManifest, wantNote string) {
	t.Helper()
	openCopyVault(t, owner.pk)
	own := addBlob(t, owner.pk, big)
	note := owner.sign(t, nostr.Event{Kind: 1, Content: "photo https://cdn.example/" + own})
	saveEv(t, outboxDB, note)
	saveEv(t, chatDB, other.sign(t, nostr.Event{Kind: 1059, Tags: nostr.Tags{{"p", owner.pk}}, Content: "sealed"}))
	saveEv(t, inboxDB, other.sign(t, nostr.Event{Kind: 1, Tags: nostr.Tags{{"p", owner.pk}}, Content: "reply"}))
	_ = os.WriteFile(copySettingsFile, []byte(`{"v":1,"updated_at":100,"keys":{"wot_depth":2}}`), 0o600)
	dir = t.TempDir()
	m, err := buildCopy(context.Background(), dir, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", func(copyProgress) {})
	if err != nil {
		t.Fatal(err)
	}
	return dir, m, note.ID
}

type flakyA struct {
	srv      *copyServer
	requests atomic.Int64
	corrupt  atomic.Int64 // corrupt this many chunk answers
	failAt   atomic.Int64 // fail chunk requests after this many (0 = never)
}

func (f *flakyA) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Range") != "" {
		n := f.requests.Add(1)
		if at := f.failAt.Load(); at > 0 && n > at {
			http.Error(w, "gone", http.StatusServiceUnavailable)
			return
		}
		if f.corrupt.Load() > 0 {
			f.corrupt.Add(-1)
			rec := httptest.NewRecorder()
			f.srv.ServeHTTP(rec, r)
			body := rec.Body.Bytes()
			if len(body) > 0 {
				body[0] ^= 0xff
			}
			w.WriteHeader(rec.Code)
			_, _ = w.Write(body)
			return
		}
	}
	f.srv.ServeHTTP(w, r)
}

func TestCopyFromAToBEndToEndWithResume(t *testing.T) {
	owner, other := newTestKey(t), newTestKey(t)
	big := bytes.Repeat([]byte("0123456789abcdef"), (2*copyChunkSize+1000)/16) // 3 chunks of media
	srcDir, built, noteID := buildOnA(t, owner, other, big)

	// A's server, serving the prebuilt copy from A's own directory.
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
		return m, nil
	})
	flaky := &flakyA{srv: s}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// A answers from its own working dir, as on a real device.
		_ = aWD
		flaky.ServeHTTP(w, r)
	}))
	defer ts.Close()

	// B: a fresh, empty vault for the same owner.
	openCopyVault(t, owner.pk)
	copyPollEvery = 10 * time.Millisecond
	t.Cleanup(func() { copyPollEvery = 2 * time.Second })
	// A's copies live in A's dir, not B's working dir.
	s.cacheDir = filepath.Join(aWD, copyCacheDir)
	var logs bytes.Buffer
	captureLog(t, &logs)

	// First run: one corrupt chunk (fetched again), then the link drops after 2 chunks.
	flaky.corrupt.Store(1)
	flaky.failAt.Store(3)
	c := newCopyClient("npub1peer", ts.URL)
	c.free = func(string) (uint64, bool) { return 1 << 40, true }
	if err := c.run(context.Background(), startProof(t, owner, nostr.Now(), "/copy/v2/start")); err == nil {
		t.Fatal("the dropped link went unnoticed")
	}
	if st := c.loadState(); st == nil || len(st.Done["notes"])+len(st.Done["media"]) == 0 {
		t.Fatal("no resume state after a cut copy")
	}
	firstRun := flaky.requests.Load()

	// Second run: no new proof needed; only the missing chunks come.
	flaky.failAt.Store(0)
	flaky.requests.Store(0)
	c2 := newCopyClient("npub1peer", ts.URL)
	c2.free = c.free
	if err := c2.run(context.Background(), ""); err != nil {
		t.Fatalf("resume: %v\n%s", err, logs.String())
	}
	total := int64(0)
	for _, p := range built.Parts {
		total += int64(len(p.Chunks))
	}
	if got := flaky.requests.Load(); got >= total {
		t.Fatalf("resume fetched %d chunks of %d: it started over (first run %d)", got, total, firstRun)
	}

	if countIn(t, outboxDB, nostr.Filter{IDs: []string{noteID}}) != 1 {
		t.Fatal("A's note did not arrive")
	}
	if countIn(t, chatDB, nostr.Filter{Kinds: []int{1059}}) != 1 {
		t.Fatal("the sealed DM did not arrive as stored (still a gift wrap)")
	}
	sum := sha256.Sum256(big)
	if copyBlobFile(hex.EncodeToString(sum[:])) == "" {
		t.Fatal("A's own photo did not arrive")
	}
	if countIn(t, blossomDB, nostr.Filter{Kinds: []int{24242}}) != 1 {
		t.Fatal("the photo's blob record was not restored")
	}
	if raw, err := os.ReadFile(copySettingsFile); err != nil || !strings.Contains(string(raw), "wot_depth") {
		t.Fatal("A's settings were not left for B's app")
	}
	if !strings.Contains(logs.String(), "COPY stage=done") {
		t.Fatalf("no COPY done line:\n%s", logs.String())
	}
	if _, err := os.Stat(filepath.Join(aWD, copyCacheDir)); err == nil {
		entries, _ := os.ReadDir(filepath.Join(aWD, copyCacheDir))
		if len(entries) != 0 {
			t.Fatal("A kept its copy after Done")
		}
	}
}

// needs_space stops before any chunk and names free/need on the failed line.
func TestCopyNeedsSpaceLineCarriesFreeAndNeed(t *testing.T) {
	owner, other := newTestKey(t), newTestKey(t)
	big := bytes.Repeat([]byte("0123456789abcdef"), (2*copyChunkSize+1000)/16) // 3 chunks of media
	srcDir, built, noteID := buildOnA(t, owner, other, big)

	// A's server, serving the prebuilt copy from A's own directory.
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
		return m, nil
	})
	flaky := &flakyA{srv: s}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// A answers from its own working dir, as on a real device.
		_ = aWD
		flaky.ServeHTTP(w, r)
	}))
	defer ts.Close()

	// B: a fresh, empty vault for the same owner.
	openCopyVault(t, owner.pk)
	copyPollEvery = 10 * time.Millisecond
	t.Cleanup(func() { copyPollEvery = 2 * time.Second })
	// A's copies live in A's dir, not B's working dir.
	s.cacheDir = filepath.Join(aWD, copyCacheDir)
	var logs bytes.Buffer
	captureLog(t, &logs)

	// First run: one corrupt chunk (fetched again), then the link drops after 2 chunks.
	flaky.corrupt.Store(1)
	flaky.failAt.Store(3)
	c := newCopyClient("npub1peer", ts.URL)
	c.free = func(string) (uint64, bool) { return 1000, true }
	if err := c.run(context.Background(), startProof(t, owner, nostr.Now(), "/copy/v2/start")); copyErrorCode(err) != "needs_space" {
		t.Fatalf("want needs_space, got %v", err)
	}
	var parts int64
	for _, p := range built.Parts {
		parts += p.Size
	}
	want := fmt.Sprintf("COPY stage=failed part=- bytes=1000/%d ", 2*parts+copyHeadroom)
	if !strings.Contains(logs.String(), want) {
		t.Fatalf("no %q in\n%s", want, logs.String())
	}
	if n := flaky.requests.Load(); n != 0 {
		t.Fatalf("%d chunk requests: it fetched before checking space", n)
	}
	_ = noteID
}

// captureLog sends log's output to buf for the test.
func captureLog(t *testing.T, buf *bytes.Buffer) {
	t.Helper()
	prev := log.Writer()
	log.SetOutput(buf)
	t.Cleanup(func() { log.SetOutput(prev) })
}

// ─── catch-up ──────────────────────────────────────────────────────────────

func TestCopyCatchUpBothWaysSendsDeletionsFirst(t *testing.T) {
	owner := newTestKey(t)
	openCopyVault(t, owner.pk) // B, in the package globals
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
	onlyA := owner.sign(t, nostr.Event{Kind: 1, Content: "written on A"})
	onlyB := owner.sign(t, nostr.Event{Kind: 1, Content: "written on B"})
	privA := owner.sign(t, nostr.Event{Kind: 30078, Tags: nostr.Tags{{"d", "x"}}, Content: "private on A"})
	gone := owner.sign(t, nostr.Event{Kind: 1, Content: "deleted on A, still stored there"})
	del := owner.sign(t, nostr.Event{Kind: 5, Tags: nostr.Tags{{"e", gone.ID}}})
	saveEv(t, aStores["outbox"], onlyA)
	saveEv(t, aStores["outbox"], gone)
	saveEv(t, aStores["outbox"], del)
	saveEv(t, aStores["private"], privA)
	saveEv(t, outboxDB, onlyB)

	s := newTestCopyServer(nil)
	s.syncDB = func(name string) DBBackend { return aStores[name] }
	token := copyRandomHex(32)
	s.tokens = []copyToken{{Hash: copyHashToken(token), Owner: owner.pk, Created: time.Now().Unix(), LastUsed: time.Now().Unix()}}
	s.loaded = true
	ts := httptest.NewServer(s)
	defer ts.Close()
	saveCopyPeerToken("npub1peer", token)

	res, err := newCopyClient("npub1peer", ts.URL).sync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if countIn(t, aStores["outbox"], nostr.Filter{IDs: []string{onlyB.ID}}) != 1 {
		t.Error("B's note did not reach A")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{onlyA.ID}}) != 1 {
		t.Error("A's note did not reach B")
	}
	if countIn(t, privateDB, nostr.Filter{IDs: []string{privA.ID}}) != 1 {
		t.Error("A's private event did not reach B")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{del.ID}}) != 1 {
		t.Error("A's deletion did not reach B")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{gone.ID}}) != 0 {
		t.Error("a note deleted on A was copied to B")
	}
	if res.Got == 0 || res.Sent == 0 {
		t.Errorf("result %+v", res)
	}
	if loadCopySync()[copyPeerKey("npub1peer")] == 0 {
		t.Error("no catch-up cursor saved")
	}

	// A bad token gets nothing.
	saveCopyPeerToken("npub1peer", copyRandomHex(32))
	if _, err := newCopyClient("npub1peer", ts.URL).sync(context.Background()); copyErrorCode(err) != "auth_refused" {
		t.Fatalf("a wrong token: %v, want auth_refused", err)
	}
}

// Pick 6 on the catch-up path: only own files are listed or served.
func TestCopySyncFilesAreOwnFilesOnly(t *testing.T) {
	owner, other := newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	own := addBlob(t, owner.pk, []byte("posted"))
	saved := addBlob(t, owner.pk, []byte("saved from someone"))
	theirs := addBlob(t, other.pk, []byte("their upload"))
	saveEv(t, outboxDB, owner.sign(t, nostr.Event{Kind: 1, Content: "https://x.example/" + own}))
	saveEv(t, outboxDB, owner.sign(t, nostr.Event{Kind: 1, Content: "https://x.example/" + theirs}))
	saveEv(t, feedDB, other.sign(t, nostr.Event{Kind: 1, Content: "https://x.example/" + saved}))
	s := newTestCopyServer(nil)
	token := copyRandomHex(32)
	s.tokens = []copyToken{{Hash: copyHashToken(token), Owner: owner.pk, LastUsed: time.Now().Unix()}}
	s.loaded = true
	get := func(path string) *httptest.ResponseRecorder {
		req := copyReq(http.MethodGet, path, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, req)
		return rec
	}
	list := get("/copy/v2/sync/files?since=0").Body.String()
	if !strings.Contains(list, own) || !strings.Contains(list, saved) || strings.Contains(list, theirs) {
		t.Fatalf("file list: %s", list)
	}
	for _, sha := range []string{own, saved} {
		if c := get("/copy/v2/sync/file/" + sha).Code; c != 200 {
			t.Fatalf("own file %s: %d", sha[:8], c)
		}
	}
	if c := get("/copy/v2/sync/file/" + theirs).Code; c != 404 {
		t.Fatalf("someone else's upload was served: %d", c)
	}
}

// havend as B starts the copy only when told both whom and where.
func TestCopyFromEnvNeedsPeerAndBase(t *testing.T) {
	spawned := false
	spawn := func(string, func()) { spawned = true }
	for _, env := range []map[string]string{{}, {"COPY_FROM": "npub1a"}, {"COPY_BASE": "http://127.0.0.1:9"}} {
		if rc := startCopyFromEnv(context.Background(), func(k string) string { return env[k] }, spawn); rc != 1 || spawned {
			t.Fatalf("%v: rc %d spawned %v", env, rc, spawned)
		}
	}
}
