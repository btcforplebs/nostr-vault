package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

type listHistoryFixture struct {
	t       *testing.T
	ctx     context.Context
	sk, pk  string
	outbox  DBBackend // as the relay sees it: history wrapper inside
	history DBBackend
	now     time.Time
}

// historyBackends: every native store this build has (Badger always, LMDB
// where available), or the WASM store.
func historyBackends(t *testing.T) map[string]func(name string) DBBackend {
	out := map[string]func(string) DBBackend{
		fallbackBackendName: func(name string) DBBackend { return newTestBackend(t, name) },
	}
	if lmdbFactory != nil {
		out["LMDB"] = func(name string) DBBackend {
			dir := t.TempDir() + "/" + name
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			return lmdbFactory(dir)
		}
	}
	return out
}

func newListHistoryFixture(t *testing.T, open func(string) DBBackend) *listHistoryFixture {
	t.Helper()
	inner, history := open("outbox"), open("lists")
	for _, db := range []DBBackend{inner, history} {
		if err := db.Init(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(db.Close)
	}
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	config = Config{WhitelistedPubKeys: map[string]struct{}{pk: {}}, BlacklistedPubKeys: map[string]struct{}{}}
	prev := listsDB
	listsDB = history
	t.Cleanup(func() { listsDB = prev })
	return &listHistoryFixture{
		t: t, ctx: context.Background(), sk: sk, pk: pk,
		outbox:  newListHistoryDB(inner, func() DBBackend { return listsDB }),
		history: history, now: time.Now().Add(-time.Hour),
	}
}

// bookmarks signs a kind 10003 with items 0..n-1, `minutes` after the
// fixture's base.
func (f *listHistoryFixture) bookmarks(n, minutes int) *nostr.Event {
	return f.bookmarksFrom(0, n, minutes)
}

// bookmarksFrom: items first..first+n-1, each a distinct event id.
func (f *listHistoryFixture) bookmarksFrom(first, n, minutes int) *nostr.Event {
	tags := nostr.Tags{}
	for i := first; i < first+n; i++ {
		// A real-looking id: LMDB indexes a tag by its first bytes, so ids
		// sharing a prefix would collide inside one event.
		id := sha256.Sum256([]byte(fmt.Sprint(i)))
		tags = append(tags, nostr.Tag{"e", hex.EncodeToString(id[:])})
	}
	return signedList(f.t, f.sk, 10003, f.now.Add(time.Duration(minutes)*time.Minute), tags)
}

func (f *listHistoryFixture) publish(evs ...*nostr.Event) {
	f.t.Helper()
	for _, ev := range evs {
		if err := f.outbox.ReplaceEvent(f.ctx, ev); err != nil {
			f.t.Fatal(err)
		}
	}
}

func (f *listHistoryFixture) versionIDs(kind int, d string) []string {
	f.t.Helper()
	vs, err := listVersions(f.ctx, f.history, f.pk, kind, d)
	if err != nil {
		f.t.Fatal(err)
	}
	ids := make([]string, len(vs))
	for i, v := range vs {
		ids[i] = v.ID
	}
	return ids
}

// The outbox's own copies of a list (every stored one, not the capped query).
func outboxCopies(t *testing.T, db DBBackend, pk string, kind int) []string {
	t.Helper()
	ch, err := db.QueryEvents(context.Background(), nostr.Filter{Authors: []string{pk}, Limit: 500})
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for ev := range ch {
		if ev.Kind == kind {
			ids = append(ids, ev.ID)
		}
	}
	return ids
}

func forEachHistoryBackend(t *testing.T, run func(t *testing.T, f *listHistoryFixture)) {
	skipWithoutFS(t)
	for name, open := range historyBackends(t) {
		t.Run(name, func(t *testing.T) { run(t, newListHistoryFixture(t, open)) })
	}
}

// Every version an owner publishes is kept, newest first, including one that
// arrives after a newer copy; the outbox still holds only the newest.
func TestListHistoryKeepsEveryOwnerVersion(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		v1, v2, v3 := f.bookmarks(3, 1), f.bookmarks(4, 2), f.bookmarks(5, 3)
		f.publish(v1, v3, v2) // v2 arrives late, older than v3
		got := f.versionIDs(10003, "")
		want := []string{v3.ID, v2.ID, v1.ID}
		if strings.Join(got, ",") != strings.Join(want, ",") {
			t.Fatalf("versions = %v, want %v", got, want)
		}
		if copies := outboxCopies(t, f.outbox, f.pk, 10003); len(copies) != 1 || copies[0] != v3.ID {
			t.Fatalf("outbox copies = %v, want only the newest %s", copies, v3.ID)
		}
		// Publishing the same version again keeps one copy, without an error.
		f.publish(v3)
		if err := recordListVersion(f.ctx, f.history, v3); err != nil {
			t.Fatalf("a repeat version: %v", err)
		}
		if got := f.versionIDs(10003, ""); len(got) != 3 {
			t.Fatalf("after a repeat: %d versions, want 3", len(got))
		}
	})
}

// A stranger's list and an owner's note are not kept.
func TestListHistoryIgnoresStrangersAndNonLists(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		stranger := nostr.GeneratePrivateKey()
		spk, _ := nostr.GetPublicKey(stranger)
		f.publish(signedList(t, stranger, 10003, f.now, nostr.Tags{{"e", hexid('1')}}))
		note := signedList(t, f.sk, 1, f.now, nil)
		if err := f.outbox.SaveEvent(f.ctx, note); err != nil {
			t.Fatal(err)
		}
		article := signedList(t, f.sk, 30023, f.now, nostr.Tags{{"d", "post"}})
		f.publish(article)
		for _, author := range []string{spk, f.pk} {
			ch, err := f.history.QueryEvents(f.ctx, nostr.Filter{Authors: []string{author}, Limit: 100})
			if err != nil {
				t.Fatal(err)
			}
			for ev := range ch {
				t.Fatalf("history kept kind %d by %s", ev.Kind, ev.PubKey[:8])
			}
		}
	})
}

// Addressable lists keep their versions per d.
func TestListHistoryKeepsSetsApartByD(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		a1 := signedList(t, f.sk, 30003, f.now, nostr.Tags{{"d", "reading"}, {"e", hexid('1')}})
		a2 := signedList(t, f.sk, 30003, f.now.Add(time.Minute), nostr.Tags{{"d", "reading"}})
		b1 := signedList(t, f.sk, 30003, f.now, nostr.Tags{{"d", "recipes"}, {"e", hexid('2')}})
		f.publish(a1, a2, b1)
		if got := f.versionIDs(30003, "reading"); len(got) != 2 {
			t.Fatalf("reading: %d versions, want 2", len(got))
		}
		if got := f.versionIDs(30003, "recipes"); len(got) != 1 || got[0] != b1.ID {
			t.Fatalf("recipes = %v, want [%s]", got, b1.ID)
		}
	})
}

// Retention: the newest 20, plus the version a wipe replaced, which stays
// however many edits come after it until the list is rebuilt to its size.
func TestListHistoryPinsTheVersionBeforeAWipe(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		full := f.bookmarks(24, 0)
		f.publish(full, f.bookmarks(0, 1)) // wiped
		for i := 0; i < 30; i++ {          // then many small edits
			f.publish(f.bookmarks(1+i%2, 2+i))
		}
		got := f.versionIDs(10003, "")
		if len(got) != listHistoryKeep+2 {
			t.Fatalf("%d versions kept, want %d (20 + the pinned pair)", len(got), listHistoryKeep+2)
		}
		if got[len(got)-1] != full.ID {
			t.Fatalf("oldest kept = %s, want the pre-wipe list %s", got[len(got)-1], full.ID)
		}
		// Restored (a newer copy as large): the pin is let go on the next trim.
		f.publish(f.bookmarks(24, 100), f.bookmarks(24, 101))
		got = f.versionIDs(10003, "")
		if len(got) != listHistoryKeep {
			t.Fatalf("after restore: %d versions, want %d", len(got), listHistoryKeep)
		}
		for _, id := range got {
			if id == full.ID {
				t.Fatal("the old copy stayed pinned after the list was restored")
			}
		}
	})
}

// A stream of wipes cannot grow the store without end: at most 5 pinned.
// Each wiped list is smaller than the one before, so none counts as rebuilt
// and every one would stay pinned without the cap.
func TestListHistoryCapsPinnedCopies(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		minute := 0
		var bigs []*nostr.Event
		for wipe := 0; wipe < 12; wipe++ {
			big := f.bookmarks(60-wipe, minute)
			bigs = append(bigs, big)
			f.publish(big, f.bookmarks(0, minute+1))
			minute += 2
			for i := 0; i < listHistoryKeep; i++ {
				f.publish(f.bookmarks(1+i%2, minute))
				minute++
			}
		}
		got := f.versionIDs(10003, "")
		if len(got) != listHistoryKeep+2*listHistoryPinnedMax {
			t.Fatalf("%d versions kept, want %d (20 + 5 pinned pairs)", len(got), listHistoryKeep+2*listHistoryPinnedMax)
		}
		kept := map[string]bool{}
		for _, id := range got {
			kept[id] = true
		}
		for i, big := range bigs {
			newestFive := i >= len(bigs)-listHistoryPinnedMax
			if kept[big.ID] != newestFive {
				t.Fatalf("wiped list %d kept=%v, want %v (the newest 5 pinned)", i, kept[big.ID], newestFive)
			}
		}
	})
}

// The /lists relay serves every version, newest first, with the usual filters.
func TestListsRelayServesVersions(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		v1, v2, v3 := f.bookmarks(3, 1), f.bookmarks(0, 2), f.bookmarks(3, 3)
		follows := signedList(t, f.sk, 3, f.now, nostr.Tags{{"p", hexid('9')}})
		f.publish(v1, v2, v3, follows)
		read := func(flt nostr.Filter) []string {
			ch, err := queryListHistory(f.ctx, f.history, flt)
			if err != nil {
				t.Fatal(err)
			}
			var ids []string
			for ev := range ch {
				ids = append(ids, ev.ID)
			}
			return ids
		}
		if got := read(nostr.Filter{Kinds: []int{10003}, Authors: []string{f.pk}}); strings.Join(got, ",") != strings.Join([]string{v3.ID, v2.ID, v1.ID}, ",") {
			t.Fatalf("bookmarks = %v", got)
		}
		if got := read(nostr.Filter{Kinds: []int{10003}, Authors: []string{f.pk}, Limit: 1}); len(got) != 1 || got[0] != v3.ID {
			t.Fatalf("limit 1 = %v", got)
		}
		since := v2.CreatedAt
		if got := read(nostr.Filter{Kinds: []int{10003}, Since: &since}); len(got) != 2 {
			t.Fatalf("since v2 = %v, want 2", got)
		}
		if got := read(nostr.Filter{Authors: []string{f.pk}}); len(got) != 4 {
			t.Fatalf("all lists = %d, want 4", len(got))
		}
		stranger := nostr.GeneratePrivateKey()
		spk, _ := nostr.GetPublicKey(stranger)
		if got := read(nostr.Filter{Authors: []string{spk}}); len(got) != 0 {
			t.Fatalf("a stranger's author filter served %v", got)
		}
	})
}

// /lists takes no write without owner auth (list_history_import_test.go has the one it takes), needs owner auth to read and refuses mesh connections.
func TestListsRelayIsOwnerOnlyAndReadOnly(t *testing.T) {
	config = Config{WhitelistedPubKeys: map[string]struct{}{hexid('0'): {}}}
	rl := initListsRelay()
	if reject, _ := rejectListHistoryWrite(context.Background(), &nostr.Event{Kind: 10003}); !reject {
		t.Fatal("an EVENT was accepted")
	}
	if len(rl.RejectEvent) == 0 {
		t.Fatal("no write policy on /lists")
	}
	unauthed := context.Background()
	rejected := false
	for _, p := range rl.RejectFilter {
		if reject, _ := p(unauthed, nostr.Filter{Kinds: []int{10003}}); reject {
			rejected = true
		}
	}
	if !rejected {
		t.Fatal("a REQ without auth was served")
	}
	countRejected := false
	for _, p := range rl.RejectCountFilter {
		if reject, _ := p(unauthed, nostr.Filter{Kinds: []int{10003}}); reject {
			countRejected = true
		}
	}
	if !countRejected {
		t.Fatal("a COUNT without auth was answered")
	}
}

// Seeding at start files the current lists once; a second run adds nothing.
func TestListHistorySeedIsIdempotent(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		inner := f.outbox.(*listHistoryDB).DBBackend
		current := f.bookmarks(5, 1)
		if err := inner.ReplaceEvent(f.ctx, current); err != nil { // stored before this feature
			t.Fatal(err)
		}
		set := signedList(t, f.sk, 30003, f.now, nostr.Tags{{"d", "a"}, {"e", hexid('1')}})
		if err := inner.ReplaceEvent(f.ctx, set); err != nil {
			t.Fatal(err)
		}
		seedListHistory(f.ctx, inner, f.history)
		seedListHistory(f.ctx, inner, f.history)
		if got := f.versionIDs(10003, ""); len(got) != 1 || got[0] != current.ID {
			t.Fatalf("seeded bookmarks = %v, want [%s]", got, current.ID)
		}
		if got := f.versionIDs(30003, "a"); len(got) != 1 {
			t.Fatalf("seeded set = %v, want 1", got)
		}
	})
}

// A backup restored into the history keeps every version, not just the
// newest (the outbox's import rule would collapse it).
func TestListHistoryRestoreKeepsEveryVersion(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		v1, v2, v3 := f.bookmarks(10, 1), f.bookmarks(0, 2), f.bookmarks(2, 3)
		var lines strings.Builder
		for _, ev := range []*nostr.Event{v3, v1, v2} {
			fmt.Fprintln(&lines, ev)
		}
		if err := importDB(f.ctx, f.history, strings.NewReader(lines.String())); err != nil {
			t.Fatal(err)
		}
		if got := f.versionIDs(10003, ""); len(got) != 3 {
			t.Fatalf("restored history = %d versions, want 3", len(got))
		}
	})
}

// The profile (kind 0) is kept the same way (Logen 2026-11-02), and a
// blanked profile pins the one before it.
func TestListHistoryKeepsProfileVersions(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		full := signedProfile(t, f.sk, f.now, `{"name":"Logen","about":"photos","picture":"https://x/p.jpg"}`)
		f.publish(full, signedProfile(t, f.sk, f.now.Add(time.Minute), `{}`))
		for i := 0; i < 25; i++ {
			f.publish(signedProfile(t, f.sk, f.now.Add(time.Duration(2+i)*time.Minute), fmt.Sprintf(`{"name":"n%d"}`, i)))
		}
		got := f.versionIDs(0, "")
		if len(got) != listHistoryKeep+2 || got[len(got)-1] != full.ID {
			t.Fatalf("profile versions = %d (oldest %s), want %d ending with the pre-wipe profile", len(got), got[len(got)-1], listHistoryKeep+2)
		}
	})
}

func signedProfile(t *testing.T, sk string, at time.Time, content string) *nostr.Event {
	t.Helper()
	ev := signedList(t, sk, 0, at, nil)
	ev.Content = content
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

func (f *listHistoryFixture) mustKeep(ev *nostr.Event, why string) {
	f.t.Helper()
	for _, id := range f.versionIDs(ev.Kind, ev.Tags.GetD()) {
		if id == ev.ID {
			return
		}
	}
	f.t.Fatalf("the pre-wipe list was deleted: %s", why)
}

// A list refilled to the same size with other items is not a restore: the
// pin holds (Tron, PR 1567 review, must-fix 1).
func TestListHistoryRefillWithOtherItemsKeepsThePin(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		full := f.bookmarksFrom(0, 15, 0)
		f.publish(full, f.bookmarks(0, 1), f.bookmarksFrom(100, 15, 2))
		for i := 0; i < 25; i++ {
			f.publish(f.bookmarksFrom(100, 14+i%2, 3+i))
		}
		f.mustKeep(full, "refilled with 15 other items")
	})
}

// A late copy, older than the wipe but newer than the pinned list, can't
// move the pin off it (Tron, PR 1567 review, must-fix 2).
func TestListHistoryLateCopyDoesNotMoveThePin(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		full := f.bookmarks(20, 0)
		f.publish(full, f.bookmarks(0, 2))
		for i := 0; i < 25; i++ {
			f.publish(f.bookmarks(1+i%2, 3+i))
		}
		f.publish(f.bookmarks(11, 1)) // arrives late, dated between
		for i := 0; i < 5; i++ {
			f.publish(f.bookmarks(1+i%2, 40+i))
		}
		f.mustKeep(full, "a late 11-item copy arrived")
	})
}

// A slow tidy after a wipe pins nothing of its own, so it can't push the
// wipe's list out of the 5 pins (Tron, PR 1567 re-check, case 1).
func TestListHistoryTidyAfterAWipeKeepsThePin(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		full := f.bookmarks(20, 0)
		f.publish(full, f.bookmarks(0, 1))
		minute := 2
		for n := 40; n >= 9; n-- { // rebuilt with other items, then removed one at a time
			f.publish(f.bookmarksFrom(100, n, minute))
			minute++
		}
		for i := 0; i < 10; i++ {
			f.publish(f.bookmarksFrom(100, 9, minute))
			minute++
		}
		f.mustKeep(full, "a tidy from 40 down to 9")
	})
}

// A second wipe after a few swaps pins at most two lists, so the first
// wipe's list stays (Tron, PR 1567 re-check, case 2).
func TestListHistorySecondWipeKeepsTheFirstPin(t *testing.T) {
	forEachHistoryBackend(t, func(t *testing.T, f *listHistoryFixture) {
		full := f.bookmarks(20, 0)
		f.publish(full, f.bookmarks(0, 1))
		minute := 2
		for i := 0; i < 6; i++ { // rebuilt with 12, swapping one item each time
			f.publish(f.bookmarksFrom(100+i, 12, minute))
			minute++
		}
		f.publish(f.bookmarks(0, minute))
		minute++
		for i := 0; i < 25; i++ {
			f.publish(f.bookmarksFrom(200, 1+i%2, minute))
			minute++
		}
		f.mustKeep(full, "a second wipe after six swaps")
		if got := len(f.versionIDs(10003, "")); got > listHistoryKeep+2*3 {
			t.Fatalf("%d versions kept, want at most %d", got, listHistoryKeep+6)
		}
	})
}

// The wipe-alarm nudge (docs/LIST_WIPE_ALARM.md): a version new to the
// history says so through the outbox, once; one arriving late stays silent.
func TestListVersionNotifyOnlyForNewRecentVersions(t *testing.T) {
	f := newListHistoryFixture(t, historyBackends(t)[fallbackBackendName])
	config.NotifyMaxAgeHours = 24
	var buf strings.Builder
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	fresh := f.bookmarks(3, 0)
	f.publish(fresh)
	want := "🔔NOTIFY|type=listversion|kind=10003|author=" + f.pk + "|id=" + fresh.ID + "|recipient=" + f.pk + "|preview="
	if strings.Count(buf.String(), want) != 1 {
		t.Fatalf("want one marker for a fresh version, got %q", buf.String())
	}
	buf.Reset()
	f.publish(fresh)
	if strings.Contains(buf.String(), "type=listversion") {
		t.Fatalf("the same version again must stay silent: %q", buf.String())
	}
	old := signedList(f.t, f.sk, 10003, time.Unix(1_000_000, 0), nostr.Tags{{"t", "x"}})
	f.publish(old)
	if strings.Contains(buf.String(), "type=listversion") {
		t.Fatalf("an old version must stay silent: %q", buf.String())
	}
	if ids := f.versionIDs(10003, ""); len(ids) != 2 {
		t.Fatalf("both versions kept, got %v", ids)
	}
}
