package trustrank

import (
	"context"
	"encoding/json"
	"os"
	"sync"
	"testing"
	"time"
)

type fakeNet struct {
	mu    sync.Mutex
	lists map[string]List
	calls []string
	since map[string]int64
}

func (f *fakeNet) Fetch(_ context.Context, pk string, since int64) (List, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, pk)
	if f.since == nil {
		f.since = map[string]int64{}
	}
	f.since[pk] = since
	l, ok := f.lists[pk]
	if !ok || (since > 0 && l.CreatedAt < since) {
		return List{}, false, nil
	}
	return l, true, nil
}

func (f *fakeNet) called(pk string) bool {
	for _, c := range f.calls {
		if c == pk {
			return true
		}
	}
	return false
}

// me follows 5 friends. All 5 follow "good"; 1 follows "weak". good and weak
// each follow "far". far follows "beyond" (hop 4: never read or ranked).
func net() *fakeNet {
	var friends []string
	for i := 0; i < 5; i++ {
		friends = append(friends, pk(10+i))
	}
	n := &fakeNet{lists: map[string]List{pk(0): {CreatedAt: 1, Follows: friends}}}
	for i, f := range friends {
		fs := []string{pk(1)} // good
		if i == 0 {
			fs = append(fs, pk(2)) // weak
		}
		n.lists[f] = List{CreatedAt: 1, Follows: fs}
	}
	n.lists[pk(1)] = List{CreatedAt: 1, Follows: []string{pk(3)}}
	n.lists[pk(2)] = List{CreatedAt: 1, Follows: []string{pk(3)}}
	n.lists[pk(3)] = List{CreatedAt: 1, Follows: []string{pk(4)}}
	return n
}

func crawler(t *testing.T, n *fakeNet, dir string) *Crawler {
	t.Helper()
	s, err := OpenStore(dir+"/wot_deep", 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return &Crawler{Store: s, Dir: dir, Owner: pk(0), Fetch: n, Params: DefaultParams(), Bar: 0,
		Wait: func(context.Context) bool { return true }}
}

func TestCrawlReadsOnlyTrustedListsAndStopsAtHop3(t *testing.T) {
	n := net()
	dir := t.TempDir()
	c := crawler(t, n, dir)
	// Pick a bar between weak's and good's score.
	res, err := c.RunPass(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	good, _, _ := res.Score(pk(1))
	weak, _, _ := res.Score(pk(2))
	if !(good > weak && weak > 0) {
		t.Fatalf("good %.3f weak %.3f", good, weak)
	}
	if n.called(pk(3)) {
		t.Fatal("a hop-3 list must never be read")
	}
	if _, hop, ok := res.Score(pk(3)); !ok || hop != 3 {
		t.Fatal("hop 3 must be ranked")
	}
	if _, _, ok := res.Score(pk(4)); ok {
		t.Fatal("hop 4 must not be in the map")
	}

	n2 := net()
	c2 := crawler(t, n2, t.TempDir())
	c2.Bar = (good + weak) / 2
	if _, err := c2.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if !n2.called(pk(1)) || n2.called(pk(2)) {
		t.Fatalf("only lists of people over the bar are read: %v", n2.calls)
	}

	b, err := os.ReadFile(ResultPath(dir, pk(0)))
	if err != nil {
		t.Fatal(err)
	}
	var rf ResultFile
	if err := json.Unmarshal(b, &rf); err != nil || rf.Account != pk(0) || len(rf.People) == 0 || rf.MaxHop != 3 {
		t.Fatalf("result file: %v %+v", err, rf)
	}
}

func TestCrawlPausesAndResumesWhereItStopped(t *testing.T) {
	n := net()
	dir := t.TempDir()
	c := crawler(t, n, dir)
	allowed := 3 // owner + 2 friends, then the window opens
	c.Wait = func(context.Context) bool { allowed--; return allowed >= 0 }
	if _, err := c.RunPass(context.Background(), false); err != ErrStopped {
		t.Fatalf("want ErrStopped, got %v", err)
	}
	st := LoadState(dir, pk(0))
	if st.Hop != 2 || st.Next != 2 {
		t.Fatalf("checkpoint %+v", st)
	}
	before := len(n.calls)
	c.Wait = func(context.Context) bool { return true }
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	// The resume reads the 3 friends left and good/weak, not the first ones again.
	if got := len(n.calls) - before; got != 5 {
		t.Fatalf("resume made %d reads: %v", got, n.calls[before:])
	}
	if st := LoadState(dir, pk(0)); st.FullAt == 0 || st.Next != 0 || st.Hop != 1 {
		t.Fatalf("finished pass checkpoint %+v", st)
	}
}

func TestRefreshAsksOnlyForNewerLists(t *testing.T) {
	n := net()
	c := crawler(t, n, t.TempDir())
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	n.lists[pk(11)] = List{CreatedAt: 5, Follows: []string{pk(1), pk(5)}}
	n.calls = nil
	res, err := c.RunPass(context.Background(), true)
	if err != nil {
		t.Fatal(err)
	}
	if n.since[pk(11)] != 2 || n.since[pk(0)] != 2 {
		t.Fatalf("refresh must ask since the stored time: %v", n.since)
	}
	if _, _, ok := res.Score(pk(5)); !ok {
		t.Fatal("the changed list must be picked up")
	}
}

func TestCrawlStopsCleanlyWhenFull(t *testing.T) {
	n := net()
	dir := t.TempDir()
	s, _ := OpenStore(dir+"/wot_deep", 300)
	defer s.Close()
	c := &Crawler{Store: s, Dir: dir, Owner: pk(0), Fetch: n, Params: DefaultParams(),
		Wait: func(context.Context) bool { return true }}
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatalf("a full store keeps what it has and ranks it: %v", err)
	}
	if n.called(pk(1)) {
		t.Fatal("after the store is full, no more lists are fetched")
	}
}

func TestCrawlPaceHonoursCancel(t *testing.T) {
	c := crawler(t, net(), t.TempDir())
	c.Pace = time.Hour
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := c.RunPass(ctx, false); err != ErrStopped {
		t.Fatalf("want ErrStopped, got %v", err)
	}
}
