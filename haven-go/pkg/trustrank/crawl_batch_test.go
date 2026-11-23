package trustrank

import (
	"context"
	"errors"
	"testing"
	"time"
)

// In batches: a pause between batches resumes after the last batch read;
// a fetch error keeps the place before the failed batch.
func TestCrawlBatchesResumeAndErrorKeepPlace(t *testing.T) {
	n := net()
	n.batch = 3
	dir := t.TempDir()
	c := crawler(t, n, dir)
	allowed := 2 // owner's batch, then the first 3 friends
	c.Wait = func(context.Context) bool { allowed--; return allowed >= 0 }
	if _, err := c.RunPass(context.Background(), false); err != ErrStopped {
		t.Fatalf("want ErrStopped, got %v", err)
	}
	if st := LoadState(dir, pk(0)); st.Hop != 2 || st.Next != 3 || st.Last != pk(12) {
		t.Fatalf("checkpoint %+v", st)
	}
	before := len(n.calls)
	c.Wait = func(context.Context) bool { return true }
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if got := n.calls[before:]; len(got) != 4 || got[0] != pk(13) || got[1] != pk(14) {
		t.Fatalf("resume must read 13, 14 then hop 3: %v", got)
	}
	for _, b := range n.batches {
		if b > 3 {
			t.Fatalf("batch over Batch(): %v", n.batches)
		}
	}

	n2 := net()
	n2.batch = 3
	dir2 := t.TempDir()
	d := &downNet{fakeNet: n2, n: 4} // owner, then friends 10-12; 13-14 fail
	c2 := crawler(t, n2, dir2)
	c2.Fetch = d
	if _, err := c2.RunPass(context.Background(), false); !errors.Is(err, ErrNoRelay) {
		t.Fatalf("want ErrNoRelay, got %v", err)
	}
	if st := LoadState(dir2, pk(0)); st.Last != pk(12) || st.FullAt != 0 {
		t.Fatalf("place must be before the failed batch: %+v", st)
	}
}

// A refresh passes a floor a day before the last finished pass; a full pass
// passes none.
func TestCrawlRefreshFloor(t *testing.T) {
	n := net()
	c := crawler(t, n, t.TempDir())
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	for _, fl := range n.floors {
		if fl != 0 {
			t.Fatalf("full pass floor %v", n.floors)
		}
	}
	full := LoadState(c.Dir, pk(0)).DoneStart
	n.floors = nil
	if _, err := c.RunPass(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	if want := full - 86400; len(n.floors) == 0 || n.floors[0] != want {
		t.Fatalf("refresh floor %v, want %d", n.floors, want)
	}
}

// A checkpoint made under other weights is dropped: the pass starts again
// at hop 1 (the owner's list read again) and keeps the finished-pass times,
// so a refresh still gets its floor.
func TestCrawlParamsVersionChangeRestartsBatchedPass(t *testing.T) {
	n := net()
	n.batch = 3
	dir := t.TempDir()
	c := crawler(t, n, dir)
	c.ParamsVersion = 1
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	full, start := LoadState(dir, pk(0)).FullAt, LoadState(dir, pk(0)).DoneStart
	allowed := 2
	c.Wait = func(context.Context) bool { allowed--; return allowed >= 0 }
	if _, err := c.RunPass(context.Background(), true); err != ErrStopped {
		t.Fatalf("want ErrStopped, got %v", err)
	}
	if st := LoadState(dir, pk(0)); st.Hop != 2 || st.Last == "" || st.ParamsVersion != 1 {
		t.Fatalf("checkpoint %+v", st)
	}
	n.calls, n.floors = nil, nil
	c.ParamsVersion = 2
	c.Wait = func(context.Context) bool { return true }
	if _, err := c.RunPass(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	if len(n.calls) == 0 || n.calls[0] != pk(0) {
		t.Fatalf("new weights must start at hop 1: %v", n.calls)
	}
	st := LoadState(dir, pk(0))
	if st.ParamsVersion != 2 || st.FullAt != full || n.floors[0] != start-86400 {
		t.Fatalf("state %+v floors %v", st, n.floors)
	}
}

// A full pass that pauses for days: the next refresh's floor is a day before
// the pass started, not before it finished, so someone read on day 0 who
// changes their list on day 1 is still asked for it.
func TestCrawlRefreshFloorFromPassStart(t *testing.T) {
	n := net()
	n.batch = 3
	dir := t.TempDir()
	c := crawler(t, n, dir)
	day0 := time.Unix(1_800_000_000, 0)
	now := day0
	c.Now = func() time.Time { return now }
	allowed := 2 // owner, then the first 3 friends on day 0
	c.Wait = func(context.Context) bool { allowed--; return allowed >= 0 }
	if _, err := c.RunPass(context.Background(), false); err != ErrStopped {
		t.Fatalf("want ErrStopped, got %v", err)
	}
	if st := LoadState(dir, pk(0)); st.PassStart != day0.Unix() {
		t.Fatalf("pass start not kept in the checkpoint: %+v", st)
	}
	now = day0.Add(3 * 24 * time.Hour)
	c.Wait = func(context.Context) bool { return true }
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	st := LoadState(dir, pk(0))
	if st.DoneStart != day0.Unix() || st.FullAt != now.Unix() || st.PassStart != 0 {
		t.Fatalf("state %+v", st)
	}
	n.floors = nil
	if _, err := c.RunPass(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	if want := day0.Unix() - 86400; len(n.floors) == 0 || n.floors[0] != want {
		t.Fatalf("refresh floor %v, want %d (a day before the pass started)", n.floors, want)
	}
}
