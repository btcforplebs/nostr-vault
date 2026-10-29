package main

import (
	"context"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"

	"github.com/barrydeen/haven/internal/followers"
)

func TestFollowerSweepFilterSince(t *testing.T) {
	if f := followerSweepFilter([]string{"a"}, 0); f.Since != nil {
		t.Fatal("first sweep must ask for every list")
	}
	last := time.Now().Add(-6 * time.Hour).Unix()
	f := followerSweepFilter([]string{"a"}, last)
	if f.Since == nil || int64(*f.Since) != last-int64(followerSweepOverlap/time.Second) {
		t.Fatalf("sweep since %v, want last sweep less the overlap", f.Since)
	}
}

// A sweep after an earlier one asks the seed relays only for lists newer
// than that sweep, and still records an unfollow published since then.
func TestFollowerSweepAsksOnlyForNewLists(t *testing.T) {
	prevConfig, prevPool, prevFs := config, pool, fs
	t.Cleanup(func() { config, pool, fs = prevConfig, prevPool, prevFs })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pool = nostr.NewSimplePool(ctx)
	fs = afero.NewMemMapFs()

	owner := nostr.GeneratePrivateKey()
	ownerPK, _ := nostr.GetPublicKey(owner)
	fan := nostr.GeneratePrivateKey()
	config.WhitelistedPubKeys = map[string]struct{}{ownerPK: {}}

	// The fan dropped the owner an hour ago.
	unfollow := nostr.Event{Kind: nostr.KindFollowList, CreatedAt: nostr.Timestamp(time.Now().Add(-time.Hour).Unix()),
		Tags: nostr.Tags{{"p", nostr.GeneratePrivateKey()[:64]}}}
	unfollow.Sign(fan)

	var mu sync.Mutex
	var seen []nostr.Filter
	rl := khatru.NewRelay()
	rl.QueryEvents = append(rl.QueryEvents, func(_ context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		mu.Lock()
		seen = append(seen, f)
		mu.Unlock()
		ch := make(chan *nostr.Event, 1)
		if f.Matches(&unfollow) {
			ch <- &unfollow
		}
		close(ch)
		return ch, nil
	})
	srv := httptest.NewServer(rl)
	defer srv.Close()
	config.ImportSeedRelays = []string{"ws" + strings.TrimPrefix(srv.URL, "http")}

	l, err := followers.Open(fs, "followers.json", []string{ownerPK})
	if err != nil {
		t.Fatal(err)
	}
	followerLedger.Store(l)
	t.Cleanup(func() { followerLedger.Store(nil) })
	follow := nostr.Event{Kind: nostr.KindFollowList, CreatedAt: nostr.Timestamp(time.Now().Add(-48 * time.Hour).Unix()),
		Tags: nostr.Tags{{"p", ownerPK}}}
	follow.Sign(fan)
	observeFollowList(&follow)
	l.MarkSwept()
	lastSweep := l.LastSweep()

	if !sweepFollowers(ctx, l, []string{ownerPK}) {
		t.Fatal("sweep did not finish")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(seen) == 0 {
		t.Fatal("relay got no sweep query")
	}
	for _, f := range seen {
		if f.Since == nil || int64(*f.Since) != lastSweep-int64(followerSweepOverlap/time.Second) {
			t.Fatalf("sweep asked since %v, want the last sweep less the overlap", f.Since)
		}
	}
	snap := l.Snapshot(ownerPK, func(string) bool { return true })
	if snap.Counts.Unfollowed != 1 {
		t.Fatalf("unfollow since the last sweep not recorded: %+v", snap.Counts)
	}
}
