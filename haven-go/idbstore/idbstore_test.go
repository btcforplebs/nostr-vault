//go:build js && wasm

package idbstore_test

import (
	"flag"
	"os"
	"testing"

	"github.com/barrydeen/haven/idbstore"
	"github.com/nbd-wtf/go-nostr"
	"github.com/stretchr/testify/require"
)

// The harness (harness/chrome_exec) runs each test binary twice in the same
// browser profile: IDBSTORE_PHASE=1, then a real page reload, then
// IDBSTORE_PHASE=2. Phase 2 only runs the tests that read what phase 1 wrote
// (TestPersist, TestBench) and TestContext.
func TestMain(m *testing.M) {
	flag.Parse()
	if os.Getenv("IDBSTORE_PHASE") == "2" {
		flag.Set("test.run", "^(TestPersist|TestBench|TestContext)$")
	}
	os.Exit(m.Run())
}

func TestIDBCombinations(t *testing.T) {
	runCombinations(t, &idbstore.IDBBackend{Name: "combinations"})
}

// Badger returns one copy per matching combination: authors {A,A} x kinds
// {1,1} gives the same event 4 times, and an event tagged t=a and t=b comes
// back twice for #t [a,b] (see TestBadgerDuplicateFilterValues). khatru
// forwards every copy to the client. The browser store returns each event once.
func TestIDBDuplicateFilterValues(t *testing.T) {
	db := &idbstore.IDBBackend{Name: "dupvalues"}
	require.NoError(t, db.Init())
	defer db.Close()
	a1 := mk(t, skA, 1, 10)
	save(t, db, a1)
	got := query(t, db, nostr.Filter{Authors: []string{pub(skA), pub(skA)}, Kinds: []int{1, 1}})
	require.Equal(t, []string{a1.ID}, ids(got))

	both := mk(t, skC, 1, 22, nostr.Tag{"t", "a"}, nostr.Tag{"t", "b"})
	save(t, db, both)
	got = query(t, db, nostr.Filter{Tags: nostr.TagMap{"t": {"a", "b"}}})
	require.Equal(t, []string{both.ID}, ids(got), "one event, two tag values")
}

func TestIDBLimits(t *testing.T)  { runLimits(t, &idbstore.IDBBackend{Name: "limits"}) }
func TestIDBReplace(t *testing.T) { runReplace(t, &idbstore.IDBBackend{Name: "replace"}) }
func TestIDBManyAuthors(t *testing.T) {
	runManyAuthors(t, &idbstore.IDBBackend{Name: "manyauthors"})
}

const persistCount = 500

// persistEvents is deterministic, so phase 2 can rebuild what phase 1 saved.
func persistEvents(t *testing.T) []*nostr.Event {
	out := make([]*nostr.Event, 0, persistCount)
	for i := 0; i < persistCount; i++ {
		out = append(out, mk(t, skA, 1, 5000+i, nostr.Tag{"t", "persist"}))
	}
	return out
}

func TestPersist(t *testing.T) {
	phase := os.Getenv("IDBSTORE_PHASE")
	if phase == "" {
		t.Skip("needs the reload harness (IDBSTORE_PHASE)")
	}
	db := &idbstore.IDBBackend{Name: "persist"}
	require.NoError(t, db.Init())
	defer db.Close()
	want := persistEvents(t)

	if phase == "1" {
		require.Empty(t, query(t, db, nostr.Filter{}), "fresh profile starts empty")
		save(t, db, want...)
		require.Len(t, query(t, db, nostr.Filter{Tags: nostr.TagMap{"t": {"persist"}}, Limit: 1000}), persistCount)
		return
	}

	// Phase 2: a new page, a new Go runtime, the same IndexedDB.
	got := query(t, db, nostr.Filter{Tags: nostr.TagMap{"t": {"persist"}}, Limit: 1000})
	require.Equal(t, ids(want), ids(got), "every event survived the reload")
	got = query(t, db, nostr.Filter{IDs: []string{want[0].ID, want[persistCount-1].ID}})
	require.Len(t, got, 2)
	require.Equal(t, want[persistCount-1], got[0], "content and signature intact")
	require.True(t, func() bool { ok, _ := got[0].CheckSignature(); return ok }())
}
