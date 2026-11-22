package main

import (
	"context"
	"slices"

	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// The inbox is one store for every account, and an event that tags two of
// them is stored once. The gate (account_gate.go) keeps it when at least one
// tagged account lets its author in, so without this an inbox read for
// account B also returned what was kept only because account A follows the
// author.
//
// A read that names accounts in #p leaves out an event when none of the
// named accounts it tags lets its author in and another account it tags
// does: it is in the store for that other account. An event no tagged
// account lets in any more (its author was unfollowed since) is served as
// before; so is everything on a vault with one account, a read that names no
// account, and gift wraps, whose author is a throwaway key.
//
// COUNT is not narrowed: it would mean reading every event counted. A count
// for one account can include the few events this leaves out of its reads.

// inboxReadHides reports whether ev is left out of an inbox read for scope,
// the vault's accounts the read's #p names.
func inboxReadHides(ctx context.Context, scope []string, ev *nostr.Event) bool {
	if ev.Kind == nostr.KindGiftWrap || isOwnKey(ev.PubKey) || givenZapSender(ev) != "" {
		return false
	}
	var named, others []string
	for _, account := range taggedAccounts(ev) {
		if slices.Contains(scope, account) {
			named = append(named, account)
		} else {
			others = append(others, account)
		}
	}
	if len(others) == 0 {
		return false
	}
	author := inboxTrustKey(ev)
	if len(admittingAccounts(ctx, named, author, ev)) > 0 {
		return false
	}
	return len(admittingAccounts(ctx, others, author, ev)) > 0
}

// inboxReadScope is the vault's accounts filter's #p names, and nil when the
// read is not narrowed: no account named, or a vault with one account.
func inboxReadScope(filter nostr.Filter) []string {
	own := whitelist()
	if len(own) < 2 {
		return nil
	}
	var scope []string
	for _, pk := range filter.Tags["p"] {
		if _, ok := own[pk]; ok && !slices.Contains(scope, pk) {
			scope = append(scope, pk)
		}
	}
	if len(scope) == len(own) {
		return nil // every account: nothing is another account's
	}
	return scope
}

// scopeInboxQuery wraps an inbox QueryEvents hook with inboxReadHides.
func scopeInboxQuery(query func(context.Context, nostr.Filter) (chan *nostr.Event, error)) func(context.Context, nostr.Filter) (chan *nostr.Event, error) {
	return func(ctx context.Context, filter nostr.Filter) (chan *nostr.Event, error) {
		ch, err := query(ctx, filter)
		// A negentropy session reads id + created_at stubs with no tags, and
		// reconciles stores between your own devices: left whole.
		if err != nil || ch == nil || eventstore.IsNegentropySession(ctx) {
			return ch, err
		}
		scope := inboxReadScope(filter)
		if len(scope) == 0 {
			return ch, err
		}
		out := make(chan *nostr.Event)
		go func() {
			defer close(out)
			for ev := range ch {
				if inboxReadHides(ctx, scope, ev) {
					continue
				}
				select {
				case out <- ev:
				case <-ctx.Done():
					// Let the store finish and close its channel.
					for range ch {
					}
					return
				}
			}
		}()
		return out, nil
	}
}

// wireInboxReads gives the inbox relay its reads: queries (plain and NIP-50
// search) and counts with blocked people hidden (search.go), each read
// narrowed to its accounts, and brought-over accounts hidden.
func wireInboxReads(rl *khatru.Relay, db DBBackend) {
	enableSearch(rl, db)
	for i, q := range rl.QueryEvents {
		rl.QueryEvents[i] = scopeInboxQuery(q)
	}
	hideBroughtOnInbox(rl)
}
