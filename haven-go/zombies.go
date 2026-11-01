package main

import (
	"context"
	"slices"
	"strings"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// zombieReport is the one read route for the zombie check (pkg/wot/zombies.go):
// owner's last report, starting a check in c when it is missing, a day old,
// or force is set. ok is false when owner is not an account on this relay.
func zombieReport(c *relayCycle, owner string, force bool) (wot.ZombieState, bool) {
	owner = strings.ToLower(strings.TrimSpace(owner))
	if _, mine := config.WhitelistedPubKeys[owner]; !mine {
		return wot.ZombieState{}, false
	}
	check := wot.ZombieCheck{
		Now:    time.Now,
		Local:  localLastSeen,
		Fetch:  wot.PoolFetch(c.pool),
		Relays: append(slices.Clone(config.ImportSeedRelays), wot.ZombieRelays...),
	}
	if model, ok := wot.GetInstance().(interface{ FollowListDates() map[string]int64 }); ok {
		check.Floors = model.FollowListDates()
	}
	run := func() (wot.ZombieReport, bool) {
		follows, ok := ownerFollows(owner)
		if !ok || c.ctx.Err() != nil {
			return wot.ZombieReport{}, false
		}
		report := check.Run(c.ctx, owner, follows)
		return report, c.ctx.Err() == nil
	}
	return wot.Zombies(owner, force, time.Now(), c.spawn, run), true
}

// ownerFollows is the people in owner's newest stored follow list.
func ownerFollows(owner string) ([]string, bool) {
	for _, ev := range ownerFollowLists() {
		if ev.PubKey != owner {
			continue
		}
		var out []string
		for tag := range ev.Tags.FindAll("p") {
			out = append(out, tag[1])
		}
		return out, true
	}
	return nil, false
}

// localLastSeen is the newest event this relay stores from each author, of
// any kind: the feed (follows' notes) and the inbox (their replies, likes
// and zaps to the owner).
func localLastSeen(ctx context.Context, authors []string) map[string]wot.Seen {
	out := make(map[string]wot.Seen, len(authors))
	for _, db := range []DBBackend{feedDB, inboxDB} {
		if db == nil {
			continue
		}
		store := eventstore.RelayWrapper{Store: db}
		for _, pk := range authors {
			if ctx.Err() != nil {
				return out
			}
			evs, err := store.QuerySync(ctx, nostr.Filter{Authors: []string{pk}, Limit: 1})
			if err != nil || len(evs) == 0 {
				continue
			}
			if at := int64(evs[0].CreatedAt); at > out[pk].At {
				out[pk] = wot.Seen{At: at, Kind: evs[0].Kind}
			}
		}
	}
	return out
}
