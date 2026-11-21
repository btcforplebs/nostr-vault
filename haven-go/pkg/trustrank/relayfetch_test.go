package trustrank

import (
	"context"
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

	// Refresh: stored at 200, so since 201. The kind 3 @300 changed.
	l, found, err := f.Fetch(ctx, author, 201)
	if err != nil || !found || l.CreatedAt != 300 || len(l.Follows) != 1 || l.Follows[0] != pk(2) {
		t.Fatalf("refresh: err %v found %v %+v", err, found, l)
	}
	if len(l.Mutes) != 1 || l.Mutes[0] != pk(3) {
		t.Fatalf("refresh lost the mutes: %+v", l)
	}

	// Full read, nothing stored: follows from the stale relay (the next is
	// asked only for what is missing), mutes from the next.
	l, found, err = f.Fetch(ctx, author, 0)
	if err != nil || !found || len(l.Mutes) != 1 || l.Mutes[0] != pk(3) || l.CreatedAt != 200 {
		t.Fatalf("full read: err %v found %v %+v", err, found, l)
	}

	// Nothing newer than 301: not found.
	if _, found, err = f.Fetch(ctx, author, 301); err != nil || found {
		t.Fatalf("since 301: err %v found %v", err, found)
	}
}
