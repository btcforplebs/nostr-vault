package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// Moving in pulls the user's older list versions from history relays (Lazarus; Logen 2026-11-04). /lists takes
// exactly that write: one of this vault's apps (AUTHed as a whitelisted key, as a read is) filing a protected list
// signed by one of this vault's accounts. The version goes to the import store (list_history_import.go): never the
// outbox, never the vault's own history. /lists serves both.

func authedAs(pk string) context.Context {
	return context.WithValue(context.Background(), 0, &khatru.WebSocket{AuthedPublicKey: pk})
}

// withImportStore opens the import store beside the fixture's history store.
func withImportStore(t *testing.T, open func(string) DBBackend) {
	t.Helper()
	db := open("listsimport")
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	prev := listsImportDB
	listsImportDB = db
	t.Cleanup(func() { listsImportDB = prev })
}

// read: what /lists answers for one list, newest first. imported: the filter asks for the imported versions.
func (f *listHistoryFixture) read(kind int, imported bool) []*nostr.Event {
	f.t.Helper()
	flt := nostr.Filter{Authors: []string{f.pk}, Kinds: []int{kind}}
	if imported {
		flt.Tags = nostr.TagMap{"v": {"imported"}}
	}
	ch, err := queryListHistory(f.ctx, listsDB, flt)
	if err != nil {
		f.t.Fatal(err)
	}
	var evs []*nostr.Event
	for ev := range ch {
		evs = append(evs, ev)
	}
	return evs
}

func eventIDs(evs []*nostr.Event) []string {
	ids := make([]string, len(evs))
	for i, ev := range evs {
		ids[i] = ev.ID
	}
	return ids
}

// served: what Recover a List gets for one list, newest first: the plain read and the imported read together.
func (f *listHistoryFixture) served(kind int) []string {
	f.t.Helper()
	return eventIDs(mergeVersions(f.read(kind, false), f.read(kind, true)))
}

func (f *listHistoryFixture) importIDs(kind int) []string {
	f.t.Helper()
	vs, err := listVersions(f.ctx, listsImportDB, f.pk, kind, "")
	if err != nil {
		f.t.Fatal(err)
	}
	ids := make([]string, len(vs))
	for i, v := range vs {
		ids[i] = v.ID
	}
	return ids
}

func importFixture(t *testing.T, open func(string) DBBackend) (*listHistoryFixture, func(*nostr.Event)) {
	f := newListHistoryFixture(t, open)
	withImportStore(t, open)
	rl := initListsRelay()
	if len(rl.ReplaceEvent) != 1 {
		t.Fatalf("want one replace hook, got %d", len(rl.ReplaceEvent))
	}
	return f, func(ev *nostr.Event) {
		t.Helper()
		if err := rl.ReplaceEvent[0](authedAs(f.pk), ev); err != nil {
			t.Fatal(err)
		}
	}
}

func has(ids []string, id string) bool {
	for _, x := range ids {
		if x == id {
			return true
		}
	}
	return false
}

func TestListHistoryWritePolicy(t *testing.T) {
	for name, open := range historyBackends(t) {
		t.Run(name, func(t *testing.T) {
			f := newListHistoryFixture(t, open)
			mine := f.bookmarks(3, 0)
			deviceSk := nostr.GeneratePrivateKey()
			device, _ := nostr.GetPublicKey(deviceSk)
			config.WhitelistedPubKeys[device] = struct{}{}
			other := nostr.GeneratePrivateKey()
			otherPk, _ := nostr.GetPublicKey(other)
			theirs := signedList(t, other, 10003, f.now, nil)
			note := signedList(t, f.sk, 1, f.now, nil)
			ahead := signedList(t, f.sk, 10003, time.Now().Add(time.Hour), nil)
			cases := []struct {
				name   string
				ctx    context.Context
				ev     *nostr.Event
				reject string // "" = accepted; else the reason's prefix
			}{
				{"no auth", context.Background(), mine, "auth-required"},
				{"authed as a stranger", authedAs(otherPk), mine, "restricted"},
				{"not an account of this vault", authedAs(f.pk), theirs, "restricted"},
				{"not a list", authedAs(f.pk), note, "blocked"},
				{"dated ahead", authedAs(f.pk), ahead, "invalid"},
				{"over the mesh", meshCtx(), mine, "restricted"},
				{"the browser vault's device key", authedAs(device), mine, ""},
				{"the owner's own list", authedAs(f.pk), mine, ""},
			}
			for _, c := range cases {
				rejected, why := rejectListHistoryWrite(c.ctx, c.ev)
				if c.reject == "" && rejected {
					t.Errorf("%s: refused (%s)", c.name, why)
				}
				if c.reject != "" && (!rejected || !strings.HasPrefix(why, c.reject)) {
					t.Errorf("%s: want %q, got rejected=%v %q", c.name, c.reject, rejected, why)
				}
			}
		})
	}
}

// An imported version goes to the import store only: the outbox (the current list) and the vault's own history are
// untouched, and /lists serves both stores, newest first, each version once.
func TestListHistoryImportIsFiledApart(t *testing.T) {
	for name, open := range historyBackends(t) {
		t.Run(name, func(t *testing.T) {
			f, file := importFixture(t, open)
			current := f.bookmarks(10, 60)
			f.publish(current)
			old := []*nostr.Event{f.bookmarks(12, 40), f.bookmarks(11, 20), f.bookmarks(2, 10)}
			for _, ev := range old {
				file(ev)
			}
			file(old[0])  // the same version twice is one
			file(current) // one the vault already holds isn't filed again
			if got := f.versionIDs(10003, ""); len(got) != 1 || got[0] != current.ID {
				t.Fatalf("the vault's own history changed: %v", got)
			}
			if got := f.importIDs(10003); len(got) != 3 {
				t.Fatalf("import store holds %v", got)
			}
			if out := outboxCopies(t, f.outbox, f.pk, 10003); len(out) != 1 || out[0] != current.ID {
				t.Fatalf("the outbox changed: %v", out)
			}
			want := []string{current.ID, old[0].ID, old[1].ID, old[2].ID}
			if got := f.served(10003); strings.Join(got, ",") != strings.Join(want, ",") {
				t.Fatalf("/lists served %v, want %v", got, want)
			}
		})
	}
}

// Tron, PR 1637: the wipe alarm the apps run reads /lists with a plain filter, so a plain read serves only the
// versions the vault filed itself. A filter with {"#v": ["imported"]} gets the imported ones, and only those.
func TestListHistoryImportedServedOnlyWhenAsked(t *testing.T) {
	for name, open := range historyBackends(t) {
		t.Run(name, func(t *testing.T) {
			f, file := importFixture(t, open)
			current := f.bookmarks(10, 60)
			f.publish(current)
			old := f.bookmarks(200, 10) // a big list, cut on purpose long ago
			file(old)
			if got := eventIDs(f.read(10003, false)); len(got) != 1 || got[0] != current.ID {
				t.Fatalf("a plain read served %v, want only the vault's own %s", got, current.ID)
			}
			if got := eventIDs(f.read(10003, true)); len(got) != 1 || got[0] != old.ID {
				t.Fatalf("an imported read served %v, want only %s", got, old.ID)
			}
			// No author or kind named: all of the owners' lists, still split the same way.
			ch, err := queryListHistory(f.ctx, listsDB, nostr.Filter{})
			if err != nil {
				t.Fatal(err)
			}
			for ev := range ch {
				if ev.ID == old.ID {
					t.Fatal("an open plain read served an imported version")
				}
			}
		})
	}
}

// Tron's PR 1637 must-fix: an import must never make the vault let go of a version it was keeping. The vault holds
// a full list, its wipe and 25 edits since (the full one pinned); an import files a slow drain 39..2 dated between
// them; the next edit trims. The full copy must still be there.
func TestListHistoryImportNeverErodesAPin(t *testing.T) {
	for name, open := range historyBackends(t) {
		t.Run(name, func(t *testing.T) {
			f, file := importFixture(t, open)
			full := f.bookmarks(40, 0)
			wiped := f.bookmarks(1, 100)
			f.publish(full, wiped)
			for i := 0; i < 25; i++ {
				f.publish(f.bookmarksFrom(200+i, 2, 101+i))
			}
			f.mustKeep(full, "before import")
			for n := 39; n >= 2; n-- {
				file(f.bookmarks(n, 40-n))
			}
			// What the vault's own history would hold after the next edit had there been no import.
			own, err := listVersions(f.ctx, f.history, f.pk, 10003, "")
			if err != nil {
				t.Fatal(err)
			}
			next := f.bookmarksFrom(200, 3, 130)
			want := map[string]bool{}
			all := mergeVersions(own, []*nostr.Event{next})
			drop := map[string]bool{}
			for _, d := range listHistoryToDrop(all) {
				drop[d.ID] = true
			}
			for _, v := range all {
				if !drop[v.ID] {
					want[v.ID] = true
				}
			}
			f.publish(next)
			f.mustKeep(full, "after import + next edit")
			after := f.versionIDs(10003, "")
			if len(after) != len(want) {
				t.Fatalf("the vault's own history holds %d, without the import it would hold %d", len(after), len(want))
			}
			for _, id := range after {
				if !want[id] {
					t.Fatal("the vault's own history differs from what it holds without an import")
				}
			}
			if !has(f.served(10003), full.ID) {
				t.Fatal("/lists no longer serves the pre-wipe copy")
			}
		})
	}
}

// Imported versions are trimmed against everything at the next edit, and only imported ones are deleted; an
// imported copy from before a wipe (a pin of the whole list) stays.
func TestListHistoryImportKeepsAnImportedPreWipeCopy(t *testing.T) {
	for name, open := range historyBackends(t) {
		t.Run(name, func(t *testing.T) {
			f, file := importFixture(t, open)
			full := f.bookmarks(40, 0) // the list before it was wiped, known only to a history relay
			wiped := f.bookmarks(1, 1)
			var edits []*nostr.Event
			for i := 0; i < 30; i++ {
				edits = append(edits, f.bookmarksFrom(100+i, 2, 2+i))
			}
			// The vault itself only ever saw the 30 edits since.
			f.publish(edits...)
			own := f.versionIDs(10003, "")
			// Newest first, as the app files them.
			file(wiped)
			file(full)
			if got := len(f.importIDs(10003)); got != 2 {
				t.Fatalf("import store holds %d, want 2 (not trimmed as they arrive)", got)
			}
			f.publish(f.bookmarksFrom(100, 3, 40))
			served := f.served(10003)
			if !has(served, full.ID) || !has(served, wiped.ID) {
				t.Fatalf("the imported pre-wipe copy (or its wipe) was let go: %d served", len(served))
			}
			if after := f.versionIDs(10003, ""); has(after, full.ID) || has(after, wiped.ID) {
				t.Fatal("an imported version reached the vault's own history")
			}
			_ = own
		})
	}
}

// An import can't grow one list without end: at listHistoryImportMax it trims (imported versions only).
func TestListHistoryImportIsBounded(t *testing.T) {
	f, file := importFixture(t, historyBackends(t)[fallbackBackendName])
	current := f.bookmarks(3, 10_000)
	f.publish(current)
	for i := 0; i < listHistoryImportMax+5; i++ {
		file(f.bookmarksFrom(i, 1, -i))
	}
	if got := len(f.importIDs(10003)); got >= listHistoryImportMax {
		t.Fatalf("import store holds %d versions after an import of %d", got, listHistoryImportMax+5)
	}
	if !has(f.versionIDs(10003, ""), current.ID) {
		t.Fatal("an import trim reached the vault's own history")
	}
}

// A backup restore of the import store keeps every version (not one per list, as a plain store would).
func TestListHistoryImportSurvivesABackupRestore(t *testing.T) {
	f, file := importFixture(t, historyBackends(t)[fallbackBackendName])
	evs := []*nostr.Event{f.bookmarks(5, 1), f.bookmarks(4, 2), f.bookmarks(3, 3)}
	for _, ev := range evs {
		file(ev)
	}
	var buf bytes.Buffer
	if err := exportDB(f.ctx, listsImportDB, &buf); err != nil {
		t.Fatal(err)
	}
	for _, ev := range evs {
		if err := listsImportDB.DeleteEvent(f.ctx, ev); err != nil {
			t.Fatal(err)
		}
	}
	if err := importDB(f.ctx, listsImportDB, &buf); err != nil {
		t.Fatal(err)
	}
	if got := len(f.importIDs(10003)); got != 3 {
		t.Fatalf("restored %d of 3 imported versions", got)
	}
}
