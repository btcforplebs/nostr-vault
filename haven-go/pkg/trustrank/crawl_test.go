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
	if !ok || (since > 0 && l.Newest() < since) {
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
	n := &fakeNet{lists: map[string]List{pk(0): {FollowsAt: 1, MutesAt: 1, Follows: friends}}}
	for i, f := range friends {
		fs := []string{pk(1)} // good
		if i == 0 {
			fs = append(fs, pk(2)) // weak
		}
		n.lists[f] = List{FollowsAt: 1, MutesAt: 1, Follows: fs}
	}
	n.lists[pk(1)] = List{FollowsAt: 1, MutesAt: 1, Follows: []string{pk(3)}}
	n.lists[pk(2)] = List{FollowsAt: 1, MutesAt: 1, Follows: []string{pk(3)}}
	n.lists[pk(3)] = List{FollowsAt: 1, MutesAt: 1, Follows: []string{pk(4)}}
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
	n.lists[pk(11)] = List{FollowsAt: 5, MutesAt: 5, Follows: []string{pk(1), pk(5)}}
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
	if st := LoadState(dir, pk(0)); !st.Capped || st.FullAt != 0 {
		t.Fatalf("a capped pass is not a finished pass: %+v", st)
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

// Tron's #2372 case: at hop 3, 21's list mutes 20, which drops 20 under the
// bar, so the reader list built on resume is shorter. The resume must still
// read 22's list (an index-based place skipped it).
func TestCrawlResumeAfterReaderListShrinks(t *testing.T) {
	build := func(mute bool) *fakeNet {
		var friends []string
		for i := 0; i < 5; i++ {
			friends = append(friends, pk(10+i))
		}
		n := &fakeNet{lists: map[string]List{pk(0): {FollowsAt: 1, MutesAt: 1, Follows: friends}}}
		for _, f := range friends {
			n.lists[f] = List{FollowsAt: 1, MutesAt: 1, Follows: []string{pk(20), pk(21), pk(22), pk(23)}}
		}
		for i := 20; i <= 23; i++ {
			n.lists[pk(i)] = List{FollowsAt: 1, MutesAt: 1, Follows: []string{pk(30 + i)}}
		}
		if mute {
			n.lists[pk(21)] = List{FollowsAt: 1, MutesAt: 1, Follows: []string{pk(51)}, Mutes: []string{pk(20)}}
		}
		return n
	}
	resBefore, err := crawler(t, build(false), t.TempDir()).RunPass(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	resAfter, err := crawler(t, build(true), t.TempDir()).RunPass(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	before, _, _ := resBefore.Score(pk(20))
	after, _, _ := resAfter.Score(pk(20))
	s21, _, _ := resAfter.Score(pk(21))
	if !(before > after && s21 > (before+after)/2) {
		t.Fatalf("20 before %.3f after %.3f, 21 %.3f", before, after, s21)
	}

	n := build(true)
	dir := t.TempDir()
	c := crawler(t, n, dir)
	c.Bar = (before + after) / 2
	allowed := 1 + 5 + 2 // owner, 5 friends, then 20 and 21 at hop 3
	c.Wait = func(context.Context) bool { allowed--; return allowed >= 0 }
	if _, err := c.RunPass(context.Background(), false); err != ErrStopped {
		t.Fatalf("want ErrStopped, got %v", err)
	}
	if st := LoadState(dir, pk(0)); st.Hop != 3 || st.Last != pk(21) {
		t.Fatalf("checkpoint %+v", st)
	}
	before2 := len(n.calls)
	c.Wait = func(context.Context) bool { return true }
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	got := n.calls[before2:]
	if len(got) != 2 || got[0] != pk(22) || got[1] != pk(23) {
		t.Fatalf("resume must read 22 then 23: %v", got)
	}
}

// A refresh checkpoint is not resumed as a full pass (or the other way).
func TestCrawlCheckpointKeepsPassKind(t *testing.T) {
	n := net()
	dir := t.TempDir()
	c := crawler(t, n, dir)
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	allowed := 3
	c.Wait = func(context.Context) bool { allowed--; return allowed >= 0 }
	if _, err := c.RunPass(context.Background(), true); err != ErrStopped {
		t.Fatalf("want ErrStopped, got %v", err)
	}
	if st := LoadState(dir, pk(0)); !st.Refresh || st.Hop != 2 {
		t.Fatalf("checkpoint %+v", st)
	}
	n.calls = nil
	c.Wait = func(context.Context) bool { return true }
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if !n.called(pk(0)) || n.since[pk(0)] != 0 {
		t.Fatalf("a full pass after a refresh checkpoint starts at hop 1: %v", n.calls)
	}
}

// A future-dated list is stored at now+maxSkew, not its own time.
func TestCrawlClampsFutureCreatedAt(t *testing.T) {
	n := net()
	now := time.Unix(1_000_000, 0)
	n.lists[pk(0)] = List{FollowsAt: 9_000_000_000, MutesAt: 9_000_000_000, Follows: n.lists[pk(0)].Follows}
	c := crawler(t, n, t.TempDir())
	c.Now = func() time.Time { return now }
	if _, err := c.RunPass(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if at, _ := c.Store.CreatedAt(pk(0)); at != now.Add(maxSkew).Unix() {
		t.Fatalf("stored at %d", at)
	}
}
