//go:build !(js && wasm)

package main

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/fiatjaf/khatru/blossom"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// restoreFixture: an owner account and the vault's stores, wired into the
// package globals a restore reads (dbs, outboxDB...). Throwaway keys only.
type restoreFixture struct {
	t                    *testing.T
	ctx                  context.Context
	sk, pk               string
	otherSK, otherPK     string
	outbox, private      DBBackend
	inbox, feed, blossom DBBackend
}

func newRestoreFixture(t *testing.T) *restoreFixture {
	t.Helper()
	f := &restoreFixture{t: t, ctx: context.Background()}
	f.sk = nostr.GeneratePrivateKey()
	f.pk, _ = nostr.GetPublicKey(f.sk)
	f.otherSK = nostr.GeneratePrivateKey()
	f.otherPK, _ = nostr.GetPublicKey(f.otherSK)

	open := func(name string) DBBackend {
		db := newTestBackend(t, name)
		if err := db.Init(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(db.Close)
		return db
	}
	f.outbox, f.private, f.inbox, f.feed, f.blossom = open("outbox"), open("private"), open("inbox"), open("feed"), open("blossom")

	prevCfg, prevDBs := config, dbs
	prevOut, prevPriv, prevIn, prevFeed, prevBlob := outboxDB, privateDB, inboxDB, feedDB, blossomDB
	prevLists, prevListsImport := listsDB, listsImportDB
	t.Cleanup(func() {
		config, dbs = prevCfg, prevDBs
		outboxDB, privateDB, inboxDB, feedDB, blossomDB = prevOut, prevPriv, prevIn, prevFeed, prevBlob
		listsDB, listsImportDB = prevLists, prevListsImport
	})
	config = Config{
		OwnerPubKey:        f.pk,
		WhitelistedPubKeys: map[string]struct{}{f.pk: {}},
		BlacklistedPubKeys: map[string]struct{}{},
	}
	outboxDB, privateDB, inboxDB, feedDB, blossomDB = f.outbox, f.private, f.inbox, f.feed, f.blossom
	listsDB, listsImportDB = nil, nil
	dbs = map[string]DBBackend{"outbox": f.outbox, "private": f.private, "inbox": f.inbox, "feed": f.feed, "blossom": f.blossom}
	return f
}

func (f *restoreFixture) note(sk string, at time.Time, content string, tags ...nostr.Tag) *nostr.Event {
	f.t.Helper()
	ev := &nostr.Event{Kind: 1, CreatedAt: nostr.Timestamp(at.Unix()), Tags: nostr.Tags(tags), Content: content}
	if ev.Tags == nil {
		ev.Tags = nostr.Tags{}
	}
	if err := ev.Sign(sk); err != nil {
		f.t.Fatal(err)
	}
	return ev
}

func (f *restoreFixture) deletion(at time.Time, target *nostr.Event) *nostr.Event {
	f.t.Helper()
	ev := &nostr.Event{Kind: nostr.KindDeletion, CreatedAt: nostr.Timestamp(at.Unix()), Tags: nostr.Tags{{"e", target.ID}}}
	if err := ev.Sign(f.sk); err != nil {
		f.t.Fatal(err)
	}
	return ev
}

// zip writes a backup with the given entries (name -> raw lines).
func (f *restoreFixture) zip(entries map[string][]string) string {
	f.t.Helper()
	path := filepath.Join(f.t.TempDir(), "backup.zip")
	out, err := os.Create(path)
	if err != nil {
		f.t.Fatal(err)
	}
	zw := zip.NewWriter(out)
	for name, lines := range entries {
		w, err := zw.Create(name)
		if err != nil {
			f.t.Fatal(err)
		}
		for _, l := range lines {
			fmt.Fprintln(w, l)
		}
	}
	if err := zw.Close(); err != nil {
		f.t.Fatal(err)
	}
	out.Close()
	return path
}

func lines(evs ...*nostr.Event) []string {
	var out []string
	for _, ev := range evs {
		out = append(out, ev.String())
	}
	return out
}

func (f *restoreFixture) contents(db DBBackend, filter nostr.Filter) []string {
	f.t.Helper()
	ch, err := db.QueryEvents(f.ctx, filter)
	if err != nil {
		f.t.Fatal(err)
	}
	var got []string
	for ev := range ch {
		got = append(got, ev.Content)
	}
	return got
}

// Item 6: a bad line, or a store whose lines won't go in, no longer stops
// the restore: the good lines around it and every other store still land.
func TestRestoreSkipsBadLinesAndKeepsGoing(t *testing.T) {
	f := newRestoreFixture(t)
	now := time.Now()
	a, b := f.note(f.sk, now.Add(-2*time.Hour), "before"), f.note(f.sk, now.Add(-time.Hour), "after")
	feedNote := f.note(f.otherSK, now.Add(-time.Hour), "a followed note")
	path := f.zip(map[string][]string{
		"outbox.jsonl": {a.String(), "{not an event", b.String()},
		"feed.jsonl":   {"garbage", feedNote.String()},
	})
	if err := importFromZip(f.ctx, path); err != nil {
		t.Fatalf("restore: %v", err)
	}
	if got := f.contents(f.outbox, nostr.Filter{}); len(got) != 2 {
		t.Fatalf("outbox: %q, want both notes around the bad line", got)
	}
	if got := f.contents(f.feed, nostr.Filter{}); len(got) != 1 {
		t.Fatalf("feed: %q, want the note after the bad line", got)
	}
	st, err := importDBStats(f.ctx, f.feed, strings.NewReader("x\n"+feedNote.String()+"\n"))
	if err != nil || st.bad != 1 || st.dup != 1 {
		t.Fatalf("stats %+v err %v, want 1 bad and 1 duplicate", st, err)
	}
}

// Item 5: a restore honours NIP-09. A note deleted in the backup, or by a
// delete request the vault already holds, does not come back, in the
// outbox or in the stores nothing sweeps (private here).
func TestRestoreHonoursDeletions(t *testing.T) {
	f := newRestoreFixture(t)
	now := time.Now()
	gone := f.note(f.sk, now.Add(-3*time.Hour), "deleted note")
	kept := f.note(f.sk, now.Add(-3*time.Hour), "kept note")
	del := f.deletion(now.Add(-2*time.Hour), gone)

	draft := f.note(f.sk, now.Add(-3*time.Hour), "deleted draft")
	if err := f.outbox.SaveEvent(f.ctx, f.deletion(now.Add(-time.Hour), draft)); err != nil {
		t.Fatal(err)
	}
	// The target before its delete request, as well as after.
	late := f.note(f.sk, now.Add(-3*time.Hour), "deleted later in the file")
	lateDel := f.deletion(now.Add(-2*time.Hour), late)

	path := f.zip(map[string][]string{
		"outbox.jsonl":  lines(del, gone, kept, late, lateDel),
		"private.jsonl": lines(draft),
	})
	if err := importFromZip(f.ctx, path); err != nil {
		t.Fatalf("restore: %v", err)
	}
	for _, c := range f.contents(f.outbox, nostr.Filter{Kinds: []int{1}}) {
		if c != "kept note" {
			t.Fatalf("outbox holds %q after restore, want only the kept note", c)
		}
	}
	if got := f.contents(f.private, nostr.Filter{}); len(got) != 0 {
		t.Fatalf("private: %q, want the deleted draft left out", got)
	}
}

// Item 12: the owner check reads only the zip's own notes. A follower's
// backup whose feed holds one of yours is not yours.
func TestZipHasEventByReadsOnlyOwnNotes(t *testing.T) {
	f := newRestoreFixture(t)
	mine := f.note(f.sk, time.Now(), "mine, in their feed")
	theirs := f.note(f.otherSK, time.Now(), "their note")
	path := f.zip(map[string][]string{
		"outbox.jsonl": lines(theirs),
		"feed.jsonl":   lines(mine),
		"inbox.jsonl":  lines(mine),
	})
	if ok, err := zipHasEventBy(path, f.pk); err != nil || ok {
		t.Fatalf("follower's backup: ok=%v err=%v, want not yours", ok, err)
	}
}

// Items 12 and 13: restoring (Setup or Settings, both through importFromZip)
// takes only your own events into your own stores, and refuses a backup
// that isn't yours at all.
func TestRestoreKeepsOnlyYourOwnEvents(t *testing.T) {
	f := newRestoreFixture(t)
	now := time.Now()
	mine := f.note(f.sk, now.Add(-time.Hour), "my note")
	theirs := f.note(f.otherSK, now.Add(-time.Hour), "their note in my outbox")
	theirDraft := f.note(f.otherSK, now.Add(-time.Hour), "their draft")
	forMe := f.note(f.otherSK, now.Add(-time.Hour), "a reply to me", nostr.Tag{"p", f.pk})
	notForMe := f.note(f.otherSK, now.Add(-time.Hour), "a reply to someone else", nostr.Tag{"p", f.otherPK})

	path := f.zip(map[string][]string{
		"outbox.jsonl":  lines(mine, theirs),
		"private.jsonl": lines(theirDraft),
		"inbox.jsonl":   lines(forMe, notForMe),
	})
	if err := importFromZip(f.ctx, path); err != nil {
		t.Fatalf("restore: %v", err)
	}
	if got := f.contents(f.outbox, nostr.Filter{}); len(got) != 1 || got[0] != "my note" {
		t.Fatalf("outbox: %q, want only my note", got)
	}
	if got := f.contents(f.private, nostr.Filter{}); len(got) != 0 {
		t.Fatalf("private: %q, want nothing", got)
	}
	if got := f.contents(f.inbox, nostr.Filter{}); len(got) != 1 || got[0] != "a reply to me" {
		t.Fatalf("inbox: %q, want only the reply to me", got)
	}

	f2 := newRestoreFixture(t)
	foreign := f2.zip(map[string][]string{"outbox.jsonl": lines(f2.note(f2.otherSK, now, "not yours"))})
	if err := importFromZip(f2.ctx, foreign); !errors.Is(err, errNotYourBackup) {
		t.Fatalf("someone else's backup: %v, want errNotYourBackup", err)
	}
	if got := f2.contents(f2.outbox, nostr.Filter{}); len(got) != 0 {
		t.Fatalf("someone else's backup stored %q", got)
	}
}

// Item 18: a zip with nothing the vault can restore is an error, not
// "restored".
func TestRestoreOfNothingIsAnError(t *testing.T) {
	f := newRestoreFixture(t)
	config.OwnerPubKey = "" // so the owner check doesn't answer first
	path := f.zip(map[string][]string{"notes.txt": {"hello"}})
	if err := importFromZip(f.ctx, path); !errors.Is(err, errNothingRestored) {
		t.Fatalf("zip with no stores: %v, want errNothingRestored", err)
	}
	empty := f.zip(map[string][]string{"outbox.jsonl": {"garbage"}})
	if err := importFromZip(f.ctx, empty); !errors.Is(err, errNothingRestored) {
		t.Fatalf("zip with nothing importable: %v, want errNothingRestored", err)
	}
	// Restoring the same backup twice is not "nothing".
	ok := f.zip(map[string][]string{"outbox.jsonl": lines(f.note(f.sk, time.Now(), "mine"))})
	for i := 0; i < 2; i++ {
		if err := importFromZip(f.ctx, ok); err != nil {
			t.Fatalf("restore %d: %v", i+1, err)
		}
	}
}

// Item 4: the blob index (the relay's unsigned kind 24242 records) survives
// an export and restore; a forged or foreign record does not go in.
func TestRestoreKeepsBlobIndex(t *testing.T) {
	f := newRestoreFixture(t)
	src := newTestBackend(t, "blossom-src")
	if err := src.Init(); err != nil {
		t.Fatal(err)
	}
	defer src.Close()
	sha := strings.Repeat("ab", 32)
	wrap := blossom.EventStoreBlobIndexWrapper{Store: src, ServiceURL: "http://x"}
	if err := wrap.Keep(f.ctx, blossom.BlobDescriptor{SHA256: sha, Type: "image/jpeg", Size: 42, Uploaded: nostr.Now()}, f.pk); err != nil {
		t.Fatal(err)
	}
	if err := wrap.Keep(f.ctx, blossom.BlobDescriptor{SHA256: strings.Repeat("cd", 32), Type: "image/png", Size: 1, Uploaded: nostr.Now()}, f.otherPK); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := exportDB(f.ctx, src, &buf); err != nil {
		t.Fatal(err)
	}
	forged := &nostr.Event{PubKey: f.pk, Kind: 24242, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"x", strings.Repeat("ef", 32)}}}
	forged.ID = strings.Repeat("0", 64) // id doesn't match
	buf.WriteString(forged.String() + "\n")

	if _, err := importDBStats(f.ctx, f.blossom, &buf); err != nil {
		t.Fatal(err)
	}
	got, err := blossom.EventStoreBlobIndexWrapper{Store: f.blossom, ServiceURL: "http://x"}.Get(f.ctx, sha)
	if err != nil || got == nil || got.Type != "image/jpeg" {
		t.Fatalf("restored blob record: %+v err %v, want the jpeg", got, err)
	}
	ch, _ := f.blossom.QueryEvents(f.ctx, nostr.Filter{Kinds: []int{24242}})
	n := 0
	for range ch {
		n++
	}
	if n != 1 {
		t.Fatalf("%d blob records, want only the owner's real one", n)
	}
}

// Item 7: an export no longer stops at a second holding a page or more of
// events: everything before it is exported too.
func TestExportGetsPastABusySecond(t *testing.T) {
	db := newTestBackend(t, "export")
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	sk := nostr.GeneratePrivateKey()
	busy := nostr.Timestamp(time.Now().Add(-time.Hour).Unix())
	want := 0
	save := func(at nostr.Timestamp, content string) {
		ev := &nostr.Event{Kind: 1, CreatedAt: at, Tags: nostr.Tags{}, Content: content}
		ev.Sign(sk)
		if err := db.SaveEvent(ctx, ev); err != nil {
			t.Fatal(err)
		}
		want++
	}
	save(busy+10, "newer")
	for i := 0; i < 1100; i++ {
		save(busy, fmt.Sprintf("busy %d", i))
	}
	for i := 1; i <= 5; i++ {
		save(busy-nostr.Timestamp(i), fmt.Sprintf("older %d", i))
	}
	var buf bytes.Buffer
	if err := exportDB(ctx, db, &buf); err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(buf.String(), "\n"); got != want {
		t.Fatalf("exported %d events, want %d", got, want)
	}
	if !strings.Contains(buf.String(), `"older 5"`) {
		t.Fatal("events older than the busy second are missing")
	}
}

// Items 2 and 19: a half-written `<sha>.tmp` is never served as the blob,
// and a delete removes every served name, `<sha>.<ext>` included.
func TestBlobFilesSkipPartialsAndDeleteAll(t *testing.T) {
	prevFS, prevPath := fs, config.BlossomPath
	t.Cleanup(func() { fs, config.BlossomPath = prevFS, prevPath })
	fs = afero.NewMemMapFs()
	config.BlossomPath = "blossom/"
	sha := strings.Repeat("12", 32)
	write := func(name, body string) {
		if err := afero.WriteFile(fs, config.BlossomPath+name, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(sha+".tmp", "cut")
	for _, ext := range []string{"", "tmp", ".tmp", "jpg"} {
		if f, err := openBlobFile(sha, ext); err == nil {
			f.Close()
			t.Fatalf("ext %q: a .tmp was served as the blob", ext)
		}
	}
	write(sha+".corrupt", "bad")
	write(sha+".jpg", "photo")
	f, err := openBlobFile(sha, "")
	if err != nil {
		t.Fatalf("the .jpg copy: %v", err)
	}
	body, _ := io.ReadAll(f)
	f.Close()
	if string(body) != "photo" {
		t.Fatalf("served %q, want the .jpg", body)
	}

	write(sha, "photo")
	if err := deleteBlobFiles(sha); err != nil {
		t.Fatal(err)
	}
	if f, err := openBlobFile(sha, "jpg"); err == nil {
		f.Close()
		t.Fatal("blob still served after delete")
	}
	if err := deleteBlobFiles(sha); err == nil {
		t.Fatal("deleting a blob that isn't there: want an error")
	}
}

// Item 2: cut-off writes are cleared at start; one in flight is left alone.
func TestSweepStaleBlobTemps(t *testing.T) {
	prevFS, prevPath := fs, config.BlossomPath
	t.Cleanup(func() { fs, config.BlossomPath = prevFS, prevPath })
	fs = afero.NewMemMapFs()
	config.BlossomPath = "blossom/"
	now := time.Now()
	old, fresh := config.BlossomPath+strings.Repeat("aa", 32)+".tmp", config.BlossomPath+strings.Repeat("bb", 32)+".tmp"
	for _, p := range []string{old, fresh} {
		afero.WriteFile(fs, p, []byte("x"), 0o600)
	}
	fs.Chtimes(old, now.Add(-2*time.Hour), now.Add(-2*time.Hour))
	sweepStaleBlobTemps(now)
	if ok, _ := afero.Exists(fs, old); ok {
		t.Fatal("stale .tmp left")
	}
	if ok, _ := afero.Exists(fs, fresh); !ok {
		t.Fatal("in-flight .tmp removed")
	}
}

// Item 16: an unzip is capped by the free space, and writes files 0600
// whatever modes the zip carries.
func TestUnzipCapsSizeAndModes(t *testing.T) {
	dir := t.TempDir()
	archive := filepath.Join(dir, "media.zip")
	out, _ := os.Create(archive)
	zw := zip.NewWriter(out)
	h := &zip.FileHeader{Name: strings.Repeat("ab", 32) + ".jpg", Method: zip.Store}
	h.SetMode(0)
	w, _ := zw.CreateHeader(h)
	w.Write(bytes.Repeat([]byte("x"), 4096))
	zw.Close()
	out.Close()

	dest := filepath.Join(dir, "out")
	if err := UnzipDirectory(archive, dest); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(dest, h.Name))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v, want 0600", info.Mode().Perm())
	}

	prev := unzipFreeBytes
	t.Cleanup(func() { unzipFreeBytes = prev })
	unzipFreeBytes = func(string) (uint64, bool) { return unzipKeepFree + 1000, true }
	if err := UnzipDirectory(archive, filepath.Join(dir, "small")); !errors.Is(err, errUnzipTooBig) {
		t.Fatalf("archive bigger than the free space: %v, want errUnzipTooBig", err)
	}
	if left, _ := os.ReadDir(filepath.Join(dir, "small")); len(left) != 0 {
		t.Fatalf("%d files left behind by a refused unzip", len(left))
	}
}

// #1722 review: a blob record is unsigned, so a backup can hold any tags.
// khatru reads Tags[0..2] by position, so a short record crashed Get and
// List (List inside its goroutine, killing the process). What restores is
// rebuilt in Keep's shape, and an active type (text/html) is refused.
func TestRestoreRebuildsBlobRecordShape(t *testing.T) {
	f := newRestoreFixture(t)
	record := func(tags nostr.Tags) string {
		ev := &nostr.Event{PubKey: f.pk, Kind: 24242, CreatedAt: nostr.Now(), Tags: tags}
		ev.ID = ev.GetID()
		return ev.String() + "\n"
	}
	short := strings.Repeat("a1", 32)
	html := strings.Repeat("b2", 32)
	shuffled := strings.Repeat("c3", 32)
	var buf bytes.Buffer
	buf.WriteString(record(nostr.Tags{{"x", short}}))
	buf.WriteString(record(nostr.Tags{{"x", html}, {"type", "text/html"}, {"size", "10"}}))
	buf.WriteString(record(nostr.Tags{{"x", strings.Repeat("d4", 32)}, {"type", "image/png"}, {"size", "ten"}}))
	buf.WriteString(record(nostr.Tags{{"size", "7"}, {"extra"}, {"type", "image/png"}, {"x", shuffled}}))
	if _, err := importDBStats(f.ctx, f.blossom, &buf); err != nil {
		t.Fatal(err)
	}

	wrap := blossom.EventStoreBlobIndexWrapper{Store: f.blossom, ServiceURL: "http://x"}
	for _, sha := range []string{short, html, strings.Repeat("d4", 32)} {
		if got, err := wrap.Get(f.ctx, sha); err != nil || got != nil {
			t.Fatalf("%s restored as %+v (err %v), want refused", sha[:4], got, err)
		}
	}
	got, err := wrap.Get(f.ctx, shuffled)
	if err != nil || got == nil || got.Type != "image/png" || got.Size != 7 || got.SHA256 != shuffled {
		t.Fatalf("shuffled record: %+v err %v, want rebuilt png of 7 bytes", got, err)
	}
	ch, err := wrap.List(f.ctx, f.pk)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for range ch {
		n++
	}
	if n != 1 {
		t.Fatalf("List gave %d records, want 1", n)
	}
}

// unwritableStore refuses every write, as a full disk would.
type unwritableStore struct{ DBBackend }

func (unwritableStore) SaveEvent(context.Context, *nostr.Event) error {
	return errors.New("no space left on device")
}
func (unwritableStore) ReplaceEvent(context.Context, *nostr.Event) error {
	return errors.New("no space left on device")
}

// Audit I R1: a restore where good events could not be written says so,
// instead of "restored" with part of the backup missing.
func TestRestoreWithFailedWritesIsAnError(t *testing.T) {
	f := newRestoreFixture(t)
	dbs["private"] = unwritableStore{f.private}
	path := f.zip(map[string][]string{
		"outbox.jsonl":  lines(f.note(f.sk, time.Now(), "kept")),
		"private.jsonl": lines(f.note(f.sk, time.Now(), "lost")),
	})
	err := importFromZip(f.ctx, path)
	if !errors.Is(err, errRestoreIncomplete) {
		t.Fatalf("restore with a failed store: %v, want errRestoreIncomplete", err)
	}
	if got := f.contents(f.outbox, nostr.Filter{}); len(got) != 1 {
		t.Fatalf("the store that could write still restores, got %q", got)
	}
	if err := importDB(f.ctx, unwritableStore{f.feed}, strings.NewReader(lines(f.note(f.sk, time.Now(), "x"))[0]+"\n")); !errors.Is(err, errRestoreIncomplete) {
		t.Fatalf("jsonl import with failed writes: %v, want errRestoreIncomplete", err)
	}
}

// A stranger's archive is capped by bytes and entries, not just free space:
// a deflate bomb stops at the cap and leaves nothing past it.
func TestUnzipCappedStopsBombAndEntries(t *testing.T) {
	dir := t.TempDir()
	archive := filepath.Join(dir, "bomb.zip")
	out, _ := os.Create(archive)
	zw := zip.NewWriter(out)
	w, _ := zw.CreateHeader(&zip.FileHeader{Name: "a.png", Method: zip.Deflate})
	w.Write(bytes.Repeat([]byte{0}, 8<<20)) // 8 MB of zeros, a few KB packed
	for i := 0; i < 3; i++ {
		w, _ := zw.Create(fmt.Sprintf("small%d.png", i))
		w.Write([]byte("x"))
	}
	zw.Close()
	out.Close()

	dest := filepath.Join(dir, "capped")
	if err := UnzipDirectoryCapped(archive, dest, 1<<20, 100); !errors.Is(err, errUnzipTooBig) {
		t.Fatalf("8 MB entry under a 1 MB cap: %v, want errUnzipTooBig", err)
	}
	if left, _ := os.ReadDir(dest); len(left) != 0 {
		t.Fatalf("%d files left behind by a capped unzip", len(left))
	}
	if err := UnzipDirectoryCapped(archive, filepath.Join(dir, "few"), 16<<20, 3); err == nil {
		t.Fatal("4 entries under a 3-entry cap unpacked")
	}
	if err := UnzipDirectoryCapped(archive, filepath.Join(dir, "fits"), 16<<20, 4); err != nil {
		t.Fatalf("archive within both caps: %v", err)
	}
}
