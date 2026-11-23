package trustrank

import (
	"context"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// seenRelay is listRelay that also keeps every filter it was asked.
type seenRelay struct {
	url     string
	mu      sync.Mutex
	filters []nostr.Filter
}

func (r *seenRelay) asked() []nostr.Filter {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.filters)
}

func newSeenRelay(t *testing.T, evs ...nostr.Event) *seenRelay {
	t.Helper()
	r := &seenRelay{}
	rl := khatru.NewRelay()
	rl.QueryEvents = append(rl.QueryEvents, func(_ context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		r.mu.Lock()
		r.filters = append(r.filters, f)
		r.mu.Unlock()
		ch := make(chan *nostr.Event, len(evs))
		for i := range evs {
			if f.Matches(&evs[i]) {
				ch <- &evs[i]
			}
		}
		close(ch)
		return ch, nil
	})
	srv := httptest.NewServer(rl)
	t.Cleanup(srv.Close)
	r.url = "ws" + strings.TrimPrefix(srv.URL, "http")
	return r
}

type person struct{ sk, pk string }

func people(n int) []person {
	out := make([]person, n)
	for i := range out {
		out[i].sk = nostr.GeneratePrivateKey()
		out[i].pk, _ = nostr.GetPublicKey(out[i].sk)
	}
	return out
}

func asksFor(ps []person) []Ask {
	var a []Ask
	for _, p := range ps {
		a = append(a, Ask{Pubkey: p.pk})
	}
	return a
}

func authorsKinds(f nostr.Filter) (authors []string, kinds []int) {
	return slices.Sorted(slices.Values(f.Authors)), f.Kinds
}

// One REQ asks the first relay for everyone; the next relay is asked only
// for the people (and kinds) still missing.
func TestRelayFetchBatchAsksNextRelayOnlyForMissing(t *testing.T) {
	p := people(3)
	a := newSeenRelay(t,
		signedList(t, p[0].sk, 3, 100, pk(1)),
		signedList(t, p[1].sk, 3, 100, pk(2)),
		signedList(t, p[1].sk, 10000, 100, pk(9)))
	b := newSeenRelay(t,
		signedList(t, p[0].sk, 10000, 100, pk(8)),
		signedList(t, p[2].sk, 3, 100, pk(3)),
		signedList(t, p[1].sk, 3, 500, pk(7))) // newer, but p1's kind 3 was already found
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	f := &RelayFetcher{Pool: nostr.NewSimplePool(ctx), Relays: []string{a.url, b.url}, Timeout: 3 * time.Second}
	got, err := f.Fetch(ctx, asksFor(p), 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got[p[0].pk].Mutes[0] != pk(8) || got[p[1].pk].Follows[0] != pk(2) || got[p[2].pk].Follows[0] != pk(3) {
		t.Fatalf("lists %+v", got)
	}
	if fs := a.asked(); len(fs) != 1 || len(fs[0].Authors) != 3 || len(fs[0].Kinds) != 2 {
		t.Fatalf("first relay: one filter for all 3, both kinds: %+v", fs)
	}
	fs := b.asked()
	var want3, want10000 []string
	for _, f := range fs {
		au, k := authorsKinds(f)
		switch {
		case slices.Equal(k, []int{3}):
			want3 = au
		case slices.Equal(k, []int{10000}):
			want10000 = au
		case slices.Equal(k, []int{3, 10000}):
			want3, want10000 = append(want3, au...), append(want10000, au...)
		}
	}
	if !slices.Equal(want3, []string{p[2].pk}) {
		t.Fatalf("second relay asked kind 3 for %v, want only p2", want3)
	}
	if slices.Contains(want10000, p[1].pk) || len(want10000) != 2 {
		t.Fatalf("second relay asked mutes for %v, want p0 and p2", want10000)
	}
}

// Mutes are asked on two answering relays at most; kind 3 on every relay.
func TestRelayFetchMutesOnlyOnTwoRelays(t *testing.T) {
	p := people(1)
	r1, r2 := newSeenRelay(t), newSeenRelay(t)
	r3 := newSeenRelay(t, signedList(t, p[0].sk, 3, 100, pk(1)), signedList(t, p[0].sk, 10000, 100, pk(2)))
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	f := &RelayFetcher{Pool: nostr.NewSimplePool(ctx), Relays: []string{r1.url, r2.url, r3.url}, Timeout: 3 * time.Second}
	got, err := f.Fetch(ctx, asksFor(p), 0)
	if err != nil {
		t.Fatal(err)
	}
	l := got[p[0].pk]
	if len(l.Follows) != 1 || l.MutesAt != 0 {
		t.Fatalf("relay 3: kind 3 only, got %+v", l)
	}
	for _, f := range r3.asked() {
		if slices.Contains(f.Kinds, 10000) {
			t.Fatalf("relay 3 was asked for mutes: %+v", f)
		}
	}
}

// A refresh's REQ since is raised to the floor; each person's own since is
// still applied to what comes back; a person with nothing stored (Since 0)
// gets a full read without any since.
func TestRelayFetchRefreshFloorAndPerPersonSince(t *testing.T) {
	p := people(3)
	r := newSeenRelay(t,
		signedList(t, p[0].sk, 3, 1500, pk(1)), // newer than the floor, older than p0's own since
		signedList(t, p[1].sk, 3, 2500, pk(2)), // changed
		signedList(t, p[2].sk, 3, 10, pk(3)))   // old, but nothing stored for p2
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	f := &RelayFetcher{Pool: nostr.NewSimplePool(ctx), Relays: []string{r.url}, Timeout: 3 * time.Second}
	asks := []Ask{{p[0].pk, 2000}, {p[1].pk, 100}, {p[2].pk, 0}}
	got, err := f.Fetch(ctx, asks, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := got[p[0].pk]; ok || got[p[1].pk].FollowsAt != 2500 || got[p[2].pk].FollowsAt != 10 {
		t.Fatalf("lists %+v", got)
	}
	for _, f := range r.asked() {
		switch {
		case slices.Contains(f.Authors, p[2].pk) && f.Since != nil:
			t.Fatalf("nothing stored: no since, got %+v", f)
		case slices.Contains(f.Authors, p[1].pk) && (f.Since == nil || *f.Since != 1000):
			t.Fatalf("since must be raised to the floor 1000: %+v", f)
		}
	}
}

// The budget holds a relay back until the bytes it sent fit the rate, and
// the batch is sized so one reply carries about a minute's budget.
func TestRelayBudgetWaitsAndSizesBatch(t *testing.T) {
	f := &RelayFetcher{Budget: 60_000} // 1,000 bytes a second
	if n := f.Batch(false); n != 2 {   // 60 KB budget / 20 KB first guess
		t.Fatalf("first full batch %d", n)
	}
	f.spend("r", time.Now(), 500) // half a second's worth
	start := time.Now()
	if err := f.waitBudget(context.Background(), "r"); err != nil {
		t.Fatal(err)
	}
	if d := time.Since(start); d < 400*time.Millisecond || d > 2*time.Second {
		t.Fatalf("waited %s, want ~0.5 s", d)
	}
	if err := f.waitBudget(context.Background(), "other"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	f.spend("r", time.Now(), 60_000)
	cancel()
	if err := f.waitBudget(ctx, "r"); err == nil {
		t.Fatal("a cancelled wait must return the error")
	}

	big := &RelayFetcher{}
	big.learn(false, 50_000*10, 10) // 50 KB a person
	if n := big.Batch(false); n != DefaultBudget/50_000 {
		t.Fatalf("full batch %d", n)
	}
	big.learn(true, 0, 100) // refresh replies empty
	if n := big.Batch(true); n != MaxBatch {
		t.Fatalf("refresh batch %d", n)
	}
}

// Fetch charges each relay for what it sent: the next ask to it waits.
func TestRelayFetchChargesTheBudget(t *testing.T) {
	p := people(1)
	r := newSeenRelay(t, signedList(t, p[0].sk, 3, 100, pk(1), pk(2), pk(3)))
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	f := &RelayFetcher{Pool: nostr.NewSimplePool(ctx), Relays: []string{r.url}, Timeout: 3 * time.Second, Budget: 60 * 400} // ~400 B/s
	if _, err := f.Fetch(ctx, asksFor(p), 0); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	if _, err := f.Fetch(ctx, asksFor(p), 0); err != nil {
		t.Fatal(err)
	}
	if d := time.Since(start); d < 500*time.Millisecond {
		t.Fatalf("a ~700 B list at 400 B/s must hold the next ask back, took %s", d)
	}
}
