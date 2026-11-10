package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The catch-up's id list paged on created_at alone, so a second holding
// more events than a page was either skipped past or never got past, and
// the catch-up still counted itself done: notes missing on B for good.

func pageSmall(t *testing.T, n int) {
	t.Helper()
	prev := copySyncPage
	copySyncPage = n
	t.Cleanup(func() { copySyncPage = prev })
}

// busySeconds: owner notes on A, many sharing one second: 130 in one
// second, then 49, 50 and 51 (round a page of 50), one, 30, 40 and 25 (a
// page that ends partway into a second), and 20 a second apart.
func busySeconds(t *testing.T, owner testKey, db DBBackend) map[string]bool {
	t.Helper()
	all := map[string]bool{}
	add := func(at nostr.Timestamp, n int) {
		for i := range n {
			ev := owner.sign(t, nostr.Event{Kind: 1, CreatedAt: at, Content: fmt.Sprint("note ", at, " ", i)})
			saveEv(t, db, ev)
			all[ev.ID] = true
		}
	}
	top := nostr.Now() - 86400
	add(top, 130)
	add(top-1, 49)
	add(top-2, 50)
	add(top-3, 51)
	add(top-4, 1)
	add(top-5, 30)
	add(top-6, 40)
	add(top-7, 25)
	for i := range 20 {
		add(top-10-nostr.Timestamp(i), 1)
	}
	return all
}

func copySyncPair(t *testing.T, owner testKey) (aStores map[string]DBBackend, s *copyServer) {
	t.Helper()
	aDir := t.TempDir()
	aStores = map[string]DBBackend{}
	for _, name := range copySyncStores {
		db := fallbackBackend(filepath.Join(aDir, name))
		if err := db.Init(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(db.Close)
		aStores[name] = db
	}
	s = newTestCopyServer(nil)
	s.syncDB = func(name string) DBBackend { return aStores[name] }
	token := copyRandomHex(32)
	s.tokens = []copyToken{{Hash: copyHashToken(token), Owner: owner.pk, Created: time.Now().Unix(), LastUsed: time.Now().Unix()}}
	s.loaded = true
	saveCopyPeerToken("npub1peer", token)
	return aStores, s
}

// Every page of A's list, cursor to cursor, is every id once.
func TestCopyListIDsPagesAcrossBusySeconds(t *testing.T) {
	owner := newTestKey(t)
	openCopyVault(t, owner.pk)
	pageSmall(t, 50)
	aStores, _ := copySyncPair(t, owner)
	want := busySeconds(t, owner, aStores["outbox"])

	got := map[string]int{}
	until, after := int64(0), ""
	for pages := 0; ; pages++ {
		if pages > 100 {
			t.Fatal("the list never ended")
		}
		ids, more, err := copyListIDs(context.Background(), aStores["outbox"], 0, until, after)
		if err != nil {
			t.Fatal(err)
		}
		if len(ids) > copySyncPage {
			t.Fatalf("page of %d, over the page size %d", len(ids), copySyncPage)
		}
		for _, p := range ids {
			got[p[0].(string)]++
		}
		if !more {
			break
		}
		last := ids[len(ids)-1]
		until, after = last[1].(int64), last[0].(string)
	}
	for id := range want {
		if got[id] != 1 {
			t.Errorf("id %s listed %d times, want once", id[:8], got[id])
		}
	}
	if len(got) != len(want) {
		t.Fatalf("listed %d ids, A holds %d", len(got), len(want))
	}
}

// End to end: B gets every note of the busy seconds, and the round counts
// as done.
func TestCopyCatchUpLosesNothingInABusySecond(t *testing.T) {
	owner := newTestKey(t)
	openCopyVault(t, owner.pk) // B
	pageSmall(t, 50)
	aStores, s := copySyncPair(t, owner)
	want := busySeconds(t, owner, aStores["outbox"])
	ts := httptest.NewServer(s)
	defer ts.Close()

	if _, err := newCopyClient("npub1peer", ts.URL).sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if n := countIn(t, outboxDB, nostr.Filter{Authors: []string{owner.pk}}); n != len(want) {
		t.Fatalf("B has %d of A's %d notes", n, len(want))
	}
	if loadCopySync()[copyPeerKey("npub1peer")] == 0 {
		t.Fatal("a complete catch-up was not marked")
	}
}

// An A from before the cursor ignores after: its list cannot get past a
// second fuller than a page. B keeps what it got but does not mark the
// round done, so the next one asks again.
func TestCopyCatchUpAgainstAnOldAIsNotDone(t *testing.T) {
	owner := newTestKey(t)
	openCopyVault(t, owner.pk) // B
	pageSmall(t, 50)
	aStores, s := copySyncPair(t, owner)
	busySeconds(t, owner, aStores["outbox"])
	old := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		q.Del("after")
		r.URL.RawQuery = q.Encode()
		s.ServeHTTP(w, r)
	})
	ts := httptest.NewServer(old)
	defer ts.Close()

	if _, err := newCopyClient("npub1peer", ts.URL).sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if loadCopySync()[copyPeerKey("npub1peer")] != 0 {
		t.Fatal("a catch-up that could not page A's list was marked done")
	}
}
