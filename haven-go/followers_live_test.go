//go:build integration

package main

// Live gate for the follower ledger: real seed relays, the real backfill and
// sweep, a real live #p subscription. Unit tests in internal/followers prove
// the state machine; this proves the relay paths feed it.
//
//	FOLLOWERS_OWNER=<hex> go test ./ -tags integration -run TestLiveFollowerLedger -v -timeout 10m

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"

	"github.com/barrydeen/haven/internal/followers"
)

func TestLiveFollowerLedger(t *testing.T) {
	owner := os.Getenv("FOLLOWERS_OWNER")
	if owner == "" {
		t.Skip("set FOLLOWERS_OWNER to a hex pubkey")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()

	fs = afero.NewOsFs()
	pool = nostr.NewSimplePool(ctx, nostr.WithPenaltyBox())
	config.WhitelistedPubKeys = map[string]struct{}{owner: {}}
	config.ImportSeedRelays = []string{
		"wss://relay.primal.net",
		"wss://nos.lol",
		"wss://nostr.mom",
		"wss://relay.damus.io",
	}
	path := filepath.Join(t.TempDir(), "followers.json")
	l, err := followers.Open(fs, path, []string{owner})
	if err != nil {
		t.Fatal(err)
	}
	followerLedger.Store(l)
	defer followerLedger.Store(nil)

	start := time.Now()
	if !backfillFollowers(ctx, []string{owner}) {
		t.Error("backfill did not reach quorum")
	}
	snap := l.Snapshot(owner, func(string) bool { return false })
	t.Logf("backfill: %d followers in %s, counts %+v", len(snap.Followers), time.Since(start).Round(time.Second), snap.Counts)
	if len(snap.Followers) == 0 {
		t.Fatal("backfill found no followers")
	}
	for _, e := range snap.Followers {
		if !e.Existing {
			t.Errorf("backfilled follower %s not marked existing", e.Pubkey)
		}
	}

	start = time.Now()
	if !sweepFollowers(ctx, l, []string{owner}) {
		t.Error("sweep cut short")
	}
	snap = l.Snapshot(owner, func(string) bool { return false })
	t.Logf("sweep: %s, counts %+v", time.Since(start).Round(time.Second), snap.Counts)

	// Live: anything arriving now is a list published after the seed.
	live, stop := context.WithTimeout(ctx, 90*time.Second)
	defer stop()
	since := nostr.Now()
	filter := nostr.Filter{Kinds: []int{nostr.KindFollowList}, Tags: nostr.TagMap{"p": {owner}}, Since: &since}
	n := 0
	for ev := range pool.SubscribeMany(live, config.ImportSeedRelays, filter) {
		n++
		observeFollowList(ev.Event)
	}
	snap = l.Snapshot(owner, func(string) bool { return false })
	t.Logf("live 90s: %d lists, counts %+v", n, snap.Counts)

	if err := l.Flush(); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(path); err != nil || fi.Size() == 0 {
		t.Fatalf("ledger file not written: %v", err)
	}
}
