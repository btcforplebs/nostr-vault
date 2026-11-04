package main

import (
	"context"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The native moving-in import's list history scan (list_history_scan.go), with fake relays: no relay is opened,
// nothing is published.

type fakeHistoryRelays struct {
	mu    sync.Mutex
	held  map[string][]*nostr.Event // url -> events it holds
	asked []nostr.Filter
}

func (r *fakeHistoryRelays) ask(_ context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
	r.mu.Lock()
	r.asked = append(r.asked, f)
	evs, ok := r.held[url]
	r.mu.Unlock()
	if !ok {
		return nil, false // down: no EOSE
	}
	var hits []*nostr.Event
	for _, ev := range evs {
		if f.Until != nil && ev.CreatedAt > *f.Until {
			continue
		}
		if f.Matches(ev) || (len(f.Kinds) > 0 && f.Kinds[0] == ev.Kind && f.Authors[0] == ev.PubKey && ev.Sig == strings.Repeat("0", 128)) {
			hits = append(hits, ev) // the forged one passes the relay's filter too: relays are untrusted
		}
	}
	sort.Slice(hits, func(i, j int) bool { return hits[i].CreatedAt > hits[j].CreatedAt })
	if f.Limit > 0 && len(hits) > f.Limit {
		hits = hits[:f.Limit]
	}
	return hits, true
}

func withFakeHistoryRelays(t *testing.T, held map[string][]*nostr.Event) *fakeHistoryRelays {
	t.Helper()
	r := &fakeHistoryRelays{held: held}
	prev := historyAsk
	historyAsk = r.ask
	t.Cleanup(func() { historyAsk = prev })
	return r
}

func TestHistoryScanAsksPerKindAndPages(t *testing.T) {
	f := newListHistoryFixture(t, historyBackends(t)[fallbackBackendName])
	var many []*nostr.Event
	for i := 0; i < 250; i++ {
		many = append(many, f.bookmarksFrom(i, 1, -i))
	}
	r := withFakeHistoryRelays(t, map[string][]*nostr.Event{"wss://hist.example": many})
	versions, answered := scanListHistory(context.Background(), []string{"wss://hist.example"}, []string{f.pk}, []int{10003})
	if len(versions) != 250 || answered != 1 {
		t.Fatalf("found %d, answered %d", len(versions), answered)
	}
	for _, q := range r.asked {
		if len(q.Kinds) != 1 || q.Kinds[0] != 10003 || len(q.Authors) != 1 || q.Authors[0] != f.pk || q.Limit < 50 {
			t.Fatalf("not one kind per request, limit ≥ 50: %+v", q)
		}
	}
	if r.asked[0].Until != nil || r.asked[1].Until == nil {
		t.Fatal("the first page asks from now; the next one with until")
	}
	if len(r.asked) > historyScanPages {
		t.Fatalf("asked %d pages, the cap is %d", len(r.asked), historyScanPages)
	}
	if versions[0].CreatedAt < versions[len(versions)-1].CreatedAt {
		t.Fatal("not newest first")
	}
}

func TestHistoryScanDropsWhatRelaysCantBeTrustedWith(t *testing.T) {
	f := newListHistoryFixture(t, historyBackends(t)[fallbackBackendName])
	good := f.bookmarks(3, 0)
	forged := *f.bookmarks(9, 10)
	forged.Sig = strings.Repeat("0", 128)
	strangerSk := nostr.GeneratePrivateKey()
	stranger := signedList(t, strangerSk, 10003, f.now, nil)
	wrongKind := signedList(t, f.sk, 10000, f.now, nil)
	ahead := signedList(t, f.sk, 10003, time.Now().Add(time.Hour), nil)
	withFakeHistoryRelays(t, map[string][]*nostr.Event{"wss://bad.example": {good, &forged, stranger, wrongKind, ahead}})
	versions, _ := scanListHistory(context.Background(), []string{"wss://bad.example"}, []string{f.pk}, []int{10003})
	if len(versions) != 1 || versions[0].ID != good.ID {
		t.Fatalf("kept %d versions, want only the genuine one", len(versions))
	}
}

func TestHistoryScanCountsOnlyEOSEAsAnAnswer(t *testing.T) {
	f := newListHistoryFixture(t, historyBackends(t)[fallbackBackendName])
	v := f.bookmarks(2, 0)
	withFakeHistoryRelays(t, map[string][]*nostr.Event{"wss://a.example": {v}, "wss://b.example": {v}})
	versions, answered := scanListHistory(context.Background(), []string{"wss://a.example", "wss://b.example", "wss://down.example"}, []string{f.pk}, []int{10003})
	if len(versions) != 1 || answered != 2 {
		t.Fatalf("versions %d (want 1, deduped), answered %d (want 2)", len(versions), answered)
	}
}

// The whole import step: files only what the vault doesn't hold, into the import store; the outbox and the vault's
// own history are untouched; a second run finds nothing new; the line says how many.
func TestImportListHistoryFilesOnlyNewVersions(t *testing.T) {
	t.Setenv(listHistoryOptInEnv, "1")
	open := historyBackends(t)[fallbackBackendName]
	f := newListHistoryFixture(t, open)
	withImportStore(t, open)
	current := f.bookmarks(10, 60)
	f.publish(current)
	old := []*nostr.Event{f.bookmarks(12, 40), f.bookmarks(11, 20)}
	prevSeeds := config.ImportSeedRelays
	config.ImportSeedRelays = []string{"wss://mine.example"}
	t.Cleanup(func() { config.ImportSeedRelays = prevSeeds })
	r := withFakeHistoryRelays(t, map[string][]*nostr.Event{"wss://mine.example": {current}, "wss://hist.nostr.land": append([]*nostr.Event{current}, old...)})
	res := importListHistory(context.Background())
	if res.Found != 2 || res.Answered != 2 || res.Asked != 3 {
		t.Fatalf("result %+v", res)
	}
	if got := f.importIDs(10003); len(got) != 2 {
		t.Fatalf("import store holds %v", got)
	}
	if got := f.versionIDs(10003, ""); len(got) != 1 || got[0] != current.ID {
		t.Fatalf("the vault's own history changed: %v", got)
	}
	if out := outboxCopies(t, f.outbox, f.pk, 10003); len(out) != 1 || out[0] != current.ID {
		t.Fatalf("the outbox changed: %v", out)
	}
	asked := map[int]bool{}
	for _, q := range r.asked {
		asked[q.Kinds[0]] = true
	}
	for _, k := range []int{3, 10000, 10002, 10003, 10063} {
		if !asked[k] {
			t.Fatalf("kind %d was not asked", k)
		}
	}
	if again := importListHistory(context.Background()); again.Found != 0 {
		t.Fatalf("a second run filed %d again", again.Found)
	}
}

// The user chooses (Logen 2026-11-04): with the box unticked no relay is asked and nothing is filed or logged.
func TestImportListHistoryAsksNothingUnlessTicked(t *testing.T) {
	for _, v := range []string{"", "0", "true"} {
		t.Setenv(listHistoryOptInEnv, v)
		r := withFakeHistoryRelays(t, map[string][]*nostr.Event{"wss://hist.nostr.land": nil})
		historyScanStatus.Store("Found 3 older versions of your lists.") // a last import's line
		if res := importListHistory(context.Background()); res != (historyScanResult{}) || len(r.asked) != 0 {
			t.Fatalf("%q: result %+v, %d asks", v, res, len(r.asked))
		}
		if s := ListHistoryScanStatus(); s != "" {
			t.Fatalf("%q: status %q, want none", v, s)
		}
	}
}

// Skip stops the scan; what it found before is still filed, and the import goes on (the parent context is live).
func TestSkipKeepsWhatTheScanFoundSoFar(t *testing.T) {
	t.Setenv(listHistoryOptInEnv, "1")
	open := historyBackends(t)[fallbackBackendName]
	f := newListHistoryFixture(t, open)
	withImportStore(t, open)
	prevSeeds := config.ImportSeedRelays
	config.ImportSeedRelays = nil
	t.Cleanup(func() { config.ImportSeedRelays = prevSeeds })
	old := []*nostr.Event{signedList(t, f.sk, 3, f.now.Add(-2*time.Hour), nil), signedList(t, f.sk, 3, f.now.Add(-time.Hour), nil)}
	var mu sync.Mutex
	later := 0
	prev := historyAsk
	historyAsk = func(ctx context.Context, url string, q nostr.Filter) ([]*nostr.Event, bool) {
		if url != "wss://hist.nostr.land" {
			return nil, false
		}
		if q.Kinds[0] == 3 {
			return old, true // asked first (historyScanKinds)
		}
		mu.Lock()
		later++
		first := later == 1
		mu.Unlock()
		if first {
			if s := ListHistoryScanStatus(); s != historyScanRunning {
				t.Errorf("status while scanning: %q", s)
			}
			if !SkipListHistoryScan() {
				t.Error("no scan to skip")
			}
		}
		<-ctx.Done()
		return nil, false
	}
	t.Cleanup(func() { historyAsk = prev })
	parent := context.Background()
	res := importListHistory(parent)
	if !res.Skipped || res.Found != 2 {
		t.Fatalf("result %+v, want skipped with 2 found", res)
	}
	if got := f.importIDs(3); len(got) != 2 {
		t.Fatalf("import store holds %v", got)
	}
	if SkipListHistoryScan() {
		t.Fatal("a finished scan can still be skipped")
	}
	if s := ListHistoryScanStatus(); s != "Found 2 older versions of your lists." {
		t.Fatalf("status after: %q", s)
	}
	if later > len(historyScanKinds) {
		t.Fatalf("kept asking after Skip: %d", later)
	}
}

func TestHistoryScanLine(t *testing.T) {
	cases := map[historyScanResult]string{
		{Found: 12, Answered: 3}:               "Found 12 older versions of your lists.",
		{Found: 1, Answered: 3}:                "Found 1 older version of your lists.",
		{Found: 0, Answered: 3}:                "No older versions of your lists found.",
		{Found: 0, Answered: 0}:                "Couldn't reach the relays to look for older versions of your lists.",
		{Found: 0, Answered: 0, Skipped: true}: "Skipped looking for older versions of your lists.",
		{Found: 2, Answered: 1, Skipped: true}: "Found 2 older versions of your lists.",
	}
	for r, want := range cases {
		if got := historyScanLine(r); got != want {
			t.Errorf("%+v: %q, want %q", r, got, want)
		}
	}
}

func TestHistoryRelaysAreTheArchivalSet(t *testing.T) {
	got := uniqueRelays(append([]string{"wss://hist.nostr.land/", "wss://Relay.Ditto.pub"}, historyRelays...))
	if len(got) != 2 {
		t.Fatalf("not deduped by normalized URL: %v", got)
	}
}
