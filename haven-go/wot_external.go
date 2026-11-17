package main

import (
	"context"
	"maps"
	"slices"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The web of trust for a vault on an outside relay (Citrine, or any relay the
// user picked in place of ours). The embedded relay never starts in that
// mode, so RefreshWotC has no cycle to run in and the WOT tab's rebuild had
// nothing to call. This builds the same web, into the same wot_cache.json the
// apps read, without the relay: the owners' own follow lists are read from the
// outside relay (where the app publishes them in that mode), not from our
// outbox database, which in that mode is empty or out of date.

// externalFollowListTimeout bounds the read of the owners' lists from the
// outside relay; ownerFollowLists gives the outbox database the same 5 s.
const externalFollowListTimeout = 5 * time.Second

// followListsFrom reads each owner's newest follow list from relayURL.
func followListsFrom(ctx context.Context, p *nostr.SimplePool, relayURL string, owners []string) []*nostr.Event {
	if relayURL == "" || len(owners) == 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, externalFollowListTimeout)
	defer cancel()
	newest := make(map[string]*nostr.Event, len(owners))
	for ie := range p.FetchMany(ctx, []string{relayURL}, nostr.Filter{
		Authors: owners,
		Kinds:   []int{nostr.KindFollowList},
	}) {
		ev := ie.Event
		if ev == nil || ev.Kind != nostr.KindFollowList || !slices.Contains(owners, ev.PubKey) {
			continue
		}
		if old, ok := newest[ev.PubKey]; !ok || ev.CreatedAt > old.CreatedAt {
			newest[ev.PubKey] = ev
		}
	}
	return slices.Collect(maps.Values(newest))
}
