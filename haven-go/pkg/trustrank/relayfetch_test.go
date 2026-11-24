package trustrank

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// listRelay serves a fixed set of events, filtered the way a relay would.
func listRelay(t *testing.T, evs ...nostr.Event) string {
	t.Helper()
	rl := khatru.NewRelay()
	rl.QueryEvents = append(rl.QueryEvents, func(_ context.Context, f nostr.Filter) (chan *nostr.Event, error) {
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
	return "ws" + strings.TrimPrefix(srv.URL, "http")
}

func signedList(t *testing.T, sk string, kind int, at int64, p ...string) nostr.Event {
	t.Helper()
	ev := nostr.Event{Kind: kind, CreatedAt: nostr.Timestamp(at)}
	for _, x := range p {
		ev.Tags = append(ev.Tags, nostr.Tag{"p", x})
	}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

// Tron's #2372 case: the first relay is stale (kind 3 @100 only); the second
// has kind 3 @300 and kind 10000 @200. The newest of each kind must win, and
// the second relay must be asked for the mutes the first one lacks.
func TestRelayFetchStaleFirstRelayDoesNotHideNewerLists(t *testing.T) {
	sk := nostr.GeneratePrivateKey()
	author, _ := nostr.GetPublicKey(sk)
	stale := listRelay(t, signedList(t, sk, 3, 100, pk(1)))
	fresh := listRelay(t,
		signedList(t, sk, 3, 300, pk(2)),
		signedList(t, sk, 10000, 200, pk(3)))
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	f := &RelayFetcher{Pool: nostr.NewSimplePool(ctx), Relays: []string{stale, fresh}, Timeout: 3 * time.Second}

	// Refresh: stored at 200, so since 201. The kind 3 @300 changed; the
	// mutes @200 did not, so they are not read again (the stored copy stays:
	// Store.PutList goes kind by kind, see the next test).
	l, found, err := fetchOne(f, ctx, author, 201)
	if err != nil || !found || l.FollowsAt != 300 || l.MutesAt != 0 || len(l.Follows) != 1 || l.Follows[0] != pk(2) {
		t.Fatalf("refresh: err %v found %v %+v", err, found, l)
	}

	// Full read, nothing stored: follows from the stale relay (the next is
	// asked only for what is missing), mutes from the next.
	l, found, err = fetchOne(f, ctx, author, 0)
	if err != nil || !found || len(l.Mutes) != 1 || l.Mutes[0] != pk(3) || l.FollowsAt != 100 || l.MutesAt != 200 {
		t.Fatalf("full read: err %v found %v %+v", err, found, l)
	}

	// Nothing newer than 301: not found.
	if _, found, err = fetchOne(f, ctx, author, 301); err != nil || found {
		t.Fatalf("since 301: err %v found %v", err, found)
	}
}

// fetchOne asks for one person, as the crawler did before batching.
func fetchOne(f *RelayFetcher, ctx context.Context, author string, since int64) (List, bool, error) {
	got, err := f.Fetch(ctx, []Ask{{Pubkey: author, Since: since}}, 0)
	l, found := got[author]
	return l, found, err
}

// storedList reads rater's lists back from the store.
func storedList(t *testing.T, s *Store, rater string) (follows, mutes []string) {
	t.Helper()
	g, err := s.Graph()
	if err != nil {
		t.Fatal(err)
	}
	r := g.index[rater]
	for _, id := range g.follows[r] {
		follows = append(follows, g.keys[id])
	}
	for _, id := range g.mutes[r] {
		mutes = append(mutes, g.keys[id])
	}
	return follows, mutes
}

// Tron's second #2372 case: stale relay kind 3 @100; fresh relay kind 3 @300
// and kind 10000 @400; stored list @300. Only the mutes changed, so the
// refresh must keep the stored @300 follows, not the stale @100 ones.
func TestRefreshKeepsNewerStoredFollowsWhenOnlyMutesChanged(t *testing.T) {
	sk := nostr.GeneratePrivateKey()
	author, _ := nostr.GetPublicKey(sk)
	stale := listRelay(t, signedList(t, sk, 3, 100, pk(1)))
	fresh := listRelay(t,
		signedList(t, sk, 3, 300, pk(2)),
		signedList(t, sk, 10000, 400, pk(3)))
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	f := &RelayFetcher{Pool: nostr.NewSimplePool(ctx), Relays: []string{stale, fresh}, Timeout: 3 * time.Second}

	dir := t.TempDir()
	s, err := OpenStore(dir+"/wot_deep", 0)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	s.Put(author, 300, []string{pk(2)}, nil)
	c := &Crawler{Store: s, Dir: dir, Owner: author, Fetch: f, Params: DefaultParams(), Bar: 101,
		Wait: func(context.Context) bool { return true }}
	if _, err := c.RunPass(ctx, true); err != nil {
		t.Fatal(err)
	}
	follows, mutes := storedList(t, s, author)
	if len(follows) != 1 || follows[0] != pk(2) || len(mutes) != 1 || mutes[0] != pk(3) {
		t.Fatalf("stored follows %v mutes %v", follows, mutes)
	}
	if at, _ := s.CreatedAt(author); at != 400 {
		t.Fatalf("stored at %d", at)
	}
}

// A relay that never answers costs one timeout, then is skipped; the next
// list goes straight to the relays that work.
func TestRelayFetchBenchesAHangingRelay(t *testing.T) {
	hang := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(3 * time.Second) // never upgrades within the timeout
	}))
	defer hang.Close()
	sk := nostr.GeneratePrivateKey()
	author, _ := nostr.GetPublicKey(sk)
	good := listRelay(t, signedList(t, sk, 3, 1000, pk(1)))
	f := &RelayFetcher{Pool: nostr.NewSimplePool(context.Background()),
		Relays: []string{good, "ws" + strings.TrimPrefix(hang.URL, "http")}, Timeout: 300 * time.Millisecond}

	before := f.Batch(false)
	start := time.Now()
	if _, found, _ := fetchOne(f, context.Background(), author, 0); !found {
		t.Fatal("the working relay's list must be found")
	}
	if f.Batch(false) < before {
		t.Fatalf("a relay that sent nothing must not shrink the batch: %d, was %d", f.Batch(false), before)
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("a hanging relay must cost at most its timeout, took %s", d)
	}
	start = time.Now()
	fetchOne(f, context.Background(), author, 0)
	if d := time.Since(start); d > 250*time.Millisecond {
		t.Fatalf("the benched relay must be skipped, took %s", d)
	}
}

// Tron's #2394 must-fix: with every relay benched (a blip timed them all out),
// Fetch must not say "no list" in no time. It asks them all again, and when
// none answers it returns ErrNoRelay; once a relay is back, the list is found.
func TestRelayFetchAllBenchedIsAnErrorNotNoList(t *testing.T) {
	sk := nostr.GeneratePrivateKey()
	author, _ := nostr.GetPublicKey(sk)
	good := listRelay(t, signedList(t, sk, 3, 1000, pk(1)))
	f := &RelayFetcher{Pool: nostr.NewSimplePool(context.Background()),
		Relays: []string{good}, Timeout: 2 * time.Second}
	f.bench(good, time.Now()) // benched, but answering fine
	if _, found, err := fetchOne(f, context.Background(), author, 0); err != nil || !found {
		t.Fatalf("all benched: must ask anyway and find the list, got found=%v err=%v", found, err)
	}

	hang := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(2 * time.Second)
	}))
	defer hang.Close()
	dead := "ws" + strings.TrimPrefix(hang.URL, "http")
	f = &RelayFetcher{Pool: nostr.NewSimplePool(context.Background()),
		Relays: []string{dead, "ws://127.0.0.1:1"}, Timeout: 300 * time.Millisecond}
	for i := 0; i < 2; i++ { // first: both time out or fail; second: both benched
		_, found, err := fetchOne(f, context.Background(), author, 0)
		if found || !errors.Is(err, ErrNoRelay) {
			t.Fatalf("round %d: no relay answered, want ErrNoRelay, got found=%v err=%v", i, found, err)
		}
	}
}

// Tron's #2394 should-fix: a relay that refuses the ask (CLOSED
// rate-limited) has not answered; with no other relay, Fetch is ErrNoRelay.
// A relay that sends EOSE with nothing is a real "no list".
func TestRelayFetchRefusalIsNotAnAnswer(t *testing.T) {
	sk := nostr.GeneratePrivateKey()
	author, _ := nostr.GetPublicKey(sk)
	rl := khatru.NewRelay()
	rl.RejectFilter = append(rl.RejectFilter, func(context.Context, nostr.Filter) (bool, string) {
		return true, "rate-limited: slow down"
	})
	srv := httptest.NewServer(rl)
	defer srv.Close()
	refusing := "ws" + strings.TrimPrefix(srv.URL, "http")
	f := &RelayFetcher{Pool: nostr.NewSimplePool(context.Background()),
		Relays: []string{refusing}, Timeout: 2 * time.Second}
	start := time.Now()
	if _, found, err := fetchOne(f, context.Background(), author, 0); found || !errors.Is(err, ErrNoRelay) {
		t.Fatalf("refused ask: want ErrNoRelay, got found=%v err=%v", found, err)
	}
	if d := time.Since(start); d > time.Second {
		t.Fatalf("a CLOSED must end the ask at once, took %s", d)
	}

	empty := listRelay(t)
	f.Relays = []string{refusing, empty}
	if _, found, err := fetchOne(f, context.Background(), author, 0); found || err != nil {
		t.Fatalf("EOSE with nothing is no list: got found=%v err=%v", found, err)
	}
}
