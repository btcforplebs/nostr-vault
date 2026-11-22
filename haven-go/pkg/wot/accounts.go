package wot

import (
	"context"
	"slices"
)

// AccountReach is one account's own Follow Distance: the level its web is
// built at (1 only you, 2 your follows, 3 their follows too) and the Min
// Followers bar of level 3.
type AccountReach struct {
	Depth        int
	MinFollowers int
}

// accountWeb is one account's web, built from that account's follow list
// alone. Its people are the follows plus everyone in vouches; the account's
// own other accounts are let in by HasFor, not stored here.
type accountWeb struct {
	reach AccountReach
	// follows is the account's own follows, sorted.
	follows []string
	// vouches is the second layer (level 3 only): how many of the account's
	// follows follow each person who cleared its bar.
	vouches map[string]int
	builtAt int64
}

func (a *accountWeb) has(pubkey string) bool {
	if _, ok := slices.BinarySearch(a.follows, pubkey); ok {
		return true
	}
	_, ok := a.vouches[pubkey]
	return ok
}

// accountWebs is every account's web, keyed by the account's pubkey. A
// rebuild swaps the whole map in at once.
type accountWebs map[string]*accountWeb

// reachOf is owner's Follow Distance: its own entry when the host gave one,
// else the vault's single value (WOT_DEPTH, WOT_MINIMUM_FOLLOWERS). Level 0
// (a public relay) is only ever the vault's value, so an account's level is
// kept to 1-3.
func (wt *SimpleInMemory) reachOf(owner string) AccountReach {
	reach := AccountReach{Depth: wt.WotDepth, MinFollowers: wt.MinFollowers}
	if wt.ReachFor != nil {
		if own, ok := wt.ReachFor(owner); ok {
			reach = own
		}
	}
	reach.Depth = min(max(reach.Depth, 1), 3)
	reach.MinFollowers = max(reach.MinFollowers, 0)
	return reach
}

// HasFor reports whether pubkey may reach the account owner: it is in that
// account's own web, built from that account's follows at that account's
// level. Another account's follows do not count.
//
// The owner's other accounts on this device always get through, at every
// level, whether or not owner follows them (Logen, 2026-11-22).
//
// Until owner's web has been built (the first start after an update, or an
// account added since the last rebuild) the answer is the pooled web's, the
// one Has gives.
func (wt *SimpleInMemory) HasFor(ctx context.Context, owner, pubkey string) bool {
	if wt.WotDepth == 0 {
		return true
	}
	webs := wt.webs.Load()
	if webs == nil {
		return wt.Has(ctx, pubkey)
	}
	web := (*webs)[owner]
	if web == nil {
		return wt.Has(ctx, pubkey)
	}
	if _, own := wt.WhitelistedPubKeys[pubkey]; own {
		return true
	}
	return web.has(pubkey)
}

type perAccount interface {
	HasFor(ctx context.Context, owner, pubkey string) bool
}

// HasFor is Has asked for one account: may pubkey reach owner. A model with
// no per-account webs (the browser's static one) answers with Has. False
// while no model is installed, like Has.
func HasFor(ctx context.Context, owner, pubkey string) bool {
	m := GetInstance()
	if m == nil {
		return false
	}
	if pa, ok := m.(perAccount); ok {
		return pa.HasFor(ctx, owner, pubkey)
	}
	return m.Has(ctx, pubkey)
}
