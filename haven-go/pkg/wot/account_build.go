package wot

import (
	"context"
	"log/slog"
	"maps"
	"slices"
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// buildAccountWeb builds one account's web from its own follows (sorted,
// each once) and, at level 3, its follows' lists. It counts the way the
// pooled build does, but only this account's follows vouch: someone is in at
// level 3 when at least MinFollowers of them follow that person, and an
// account following fewer people than its bar gets newAccountWeb's widening.
//
// A follow the account has blocked (muted, nil for none) vouches for nobody:
// it stays one of the follows, and its list is not counted.
//
// links is the level-3 "which of my follows follow them" for the links file,
// as sorted indexes into the web's follows; nil below level 3.
func buildAccountWeb(reach AccountReach, owners map[string]struct{}, follows []string, lists map[string]followList, builtAt int64, muted func(pubkey string) bool) (web *accountWeb, links map[string][]int) {
	web = &accountWeb{reach: reach, builtAt: builtAt}
	if reach.Depth < 2 {
		return web, nil
	}
	web.follows = follows
	if reach.Depth < 3 {
		return web, nil
	}
	counts := make(map[string]int, len(follows))
	for _, pk := range follows {
		counts[pk]++
	}

	links = make(map[string][]int)
	for from, pk := range web.follows {
		if muted != nil && muted(pk) {
			web.muted = append(web.muted, pk)
			continue
		}
		l, ok := lists[pk]
		if !ok {
			continue
		}
		for _, contact := range l.contacts {
			// One list's tags are counted together, so a repeated tag is
			// always the last index added.
			if lk := links[contact]; contact != pk && (len(lk) == 0 || lk[len(lk)-1] != from) {
				links[contact] = append(lk, from)
			}
			counts[contact]++
		}
	}

	in := func(pk string) bool {
		if _, own := owners[pk]; own {
			return true
		}
		_, follow := slices.BinarySearch(web.follows, pk)
		return follow
	}
	web.vouches = make(map[string]int)
	for pk, n := range counts {
		if n >= reach.MinFollowers && !in(pk) {
			web.vouches[pk] = n
		}
	}
	// Only a new account's small web is copied out; a full one never is.
	if len(web.follows) < reach.MinFollowers {
		have := make(map[string]bool, len(owners)+len(web.follows)+len(web.vouches))
		for pk := range owners {
			have[pk] = true
		}
		for _, pk := range web.follows {
			have[pk] = true
		}
		for pk := range web.vouches {
			have[pk] = true
		}
		for _, pk := range newAccountWeb(counts, have, len(web.follows), reach.MinFollowers) {
			web.vouches[pk] = counts[pk]
		}
	}
	for pk, from := range links {
		if _, own := owners[pk]; own || !web.has(pk) {
			delete(links, pk)
			continue
		}
		slices.Sort(from)
	}
	return web, links
}

// buildAccounts builds every account's own web and saves each to its own
// files. build calls it wherever it saves the pooled web, with what that
// pass fetched: ownerLists is nil when it fetched no lists at all (vault
// level 1), lists is nil when it did not fetch the follows' lists (vault
// level 1 or 2). An account whose own level is higher than the vault's needs
// lists the pooled pass did not get, so they are fetched here, the same way.
//
// A fetch that comes back empty, or a relay that is stopping, keeps the webs
// we have, like build does.
func (wt *SimpleInMemory) buildAccounts(ctx context.Context, started int64, ownerLists map[string]*nostr.Event, ownersWhole bool, lists map[string]followList) {
	reaches := make(map[string]AccountReach, len(wt.WhitelistedPubKeys))
	deepest := 1
	for owner := range wt.WhitelistedPubKeys {
		reaches[owner] = wt.reachOf(owner)
		deepest = max(deepest, reaches[owner].Depth)
	}
	// The webs being replaced: a real one is not thrown away for an empty fetch.
	had := make(map[string]bool)
	if previous := wt.webs.Load(); previous != nil {
		for _, web := range *previous {
			for _, pk := range web.follows {
				had[pk] = true
			}
		}
	}
	timeout := time.Duration(wt.WotFetchTimeout) * time.Second

	if ownerLists == nil && deepest >= 2 {
		timeoutCtx, cancel := context.WithTimeout(ctx, timeout)
		var received atomic.Int64
		ownerLists, ownersWhole = wt.fetchOwnerLists(timeoutCtx, &received)
		cancel()
		if ctx.Err() != nil || (received.Load() == 0 && len(had) > 0) {
			slog.Warn("🚫 account webs: no follow lists came back; keeping the saved webs")
			return
		}
	}

	if lists == nil {
		// The follows of every level-3 account: one fetch for them all. The
		// stored lists are keyed by the follow, so accounts share them.
		wanted := make(map[string]bool)
		for owner, reach := range reaches {
			if ev := ownerLists[owner]; ev != nil && reach.Depth >= 3 {
				for contact := range ev.Tags.FindAll("p") {
					if len(contact) > 1 {
						wanted[contact[1]] = true
					}
				}
			}
		}
		if len(wanted) == 0 {
			wt.saveLists(nil, 0, 0)
		} else {
			follows := slices.Sorted(maps.Keys(wanted))
			followIndex := make(map[string]int, len(follows))
			for i, pk := range follows {
				followIndex[pk] = i
			}
			var received atomic.Int64
			got, fetched, incremental, freshComplete, changesComplete, since, fullAt := wt.fetchFollowLists(
				ctx, timeout, follows, followIndex, had, ownersWhole, &received, func(string, followList) {})
			if ctx.Err() != nil || (!incremental && fetched == 0 && len(had) > 0) {
				slog.Warn("🚫 account webs: none of the follows' lists came back; keeping the saved webs")
				return
			}
			// The same stamps build gives its own pass.
			switch {
			case incremental && changesComplete:
				since = started
			case !incremental && freshComplete:
				since, fullAt = started, started
			case !incremental:
				since = 0
			}
			wt.saveLists(got, since, fullAt)
			lists = got
		}
	}

	wt.accountsMu.Lock()
	webs := make(accountWebs, len(reaches))
	for owner, reach := range reaches {
		web, links := buildAccountWeb(reach, wt.WhitelistedPubKeys, followsOf(ownerLists[owner]), lists, started, wt.mutedBy(owner))
		webs[owner] = web
		wt.saveAccountWeb(owner, web, links)
	}
	wt.webs.Store(&webs)
	wt.accountsMu.Unlock()
	wt.removeOtherAccountFiles(func(owner string) bool { return webs[owner] != nil })
	slog.Info("🕸️ built a web per account", "accounts", len(webs))
}

// followsOf is the people a follow list names, sorted, each once; nil for no
// list.
func followsOf(list *nostr.Event) []string {
	if list == nil {
		return nil
	}
	seen := make(map[string]struct{})
	for contact := range list.Tags.FindAll("p") {
		if len(contact) > 1 {
			seen[contact[1]] = struct{}{}
		}
	}
	return slices.Sorted(maps.Keys(seen))
}

// mutedBy is owner's side of BlockedBy for buildAccountWeb; nil when the
// host gave no blocks.
func (wt *SimpleInMemory) mutedBy(owner string) func(pubkey string) bool {
	if wt.BlockedBy == nil {
		return nil
	}
	return func(pubkey string) bool { return wt.BlockedBy(owner, pubkey) }
}

// RetallyAccounts counts again, from the stored lists and with no network,
// the web of every level-3 account whose blocked follows are not the ones
// its web was tallied with: blocking a follow takes away the people only
// that follow vouched for, and unblocking brings them back. The host calls
// it when an account's blocks change.
func (wt *SimpleInMemory) RetallyAccounts() {
	if wt.BlockedBy == nil {
		return
	}
	wt.accountsMu.Lock()
	defer wt.accountsMu.Unlock()
	current := wt.webs.Load()
	if current == nil {
		return
	}
	var lists map[string]followList
	next := maps.Clone(*current)
	changed := false
	for owner, web := range *current {
		if web.reach.Depth < 3 {
			continue
		}
		var muted []string
		for _, pk := range web.follows {
			if wt.BlockedBy(owner, pk) {
				muted = append(muted, pk)
			}
		}
		if slices.Equal(muted, web.muted) {
			continue
		}
		if lists == nil {
			stored, _, _, ok := wt.loadLists()
			if !ok {
				// Nothing to count from; the next rebuild tallies with the blocks.
				return
			}
			lists = stored
		}
		retallied, links := buildAccountWeb(web.reach, wt.WhitelistedPubKeys, web.follows, lists, web.builtAt, wt.mutedBy(owner))
		next[owner] = retallied
		wt.saveAccountWeb(owner, retallied, links)
		changed = true
	}
	if changed {
		wt.webs.Store(&next)
		slog.Info("🕸️ counted the account webs again after a block change")
	}
}
