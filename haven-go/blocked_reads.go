package main

// The relay's blacklist (the people the app's accounts have blocked) used to
// decide only what the relay accepts and imports. Anything a person posted
// before they were blocked stayed stored and was still served, so every screen
// had to hide them on its own. These hooks hide them on the way out, for every
// route that serves the stores (enableSearch registers them).
//
// A block hides, it never deletes: stored events are left alone, so unblocking
// (UpdateBlacklist) serves them again, and backups and exports, which read the
// stores directly, still contain everything. Negentropy sync is left whole: it
// reconciles stores between your own devices, and a peer told an event is
// missing would only send it again.
//
// Gift wraps and zap receipts pass: their authors are a throwaway key and the
// wallet server, never the person. The app checks those once opened.

import (
	"context"
	"maps"
	"slices"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

// A read is scoped to the accounts it names: the vault's own accounts in the
// filter's #p (an inbox read) or authors (an outbox read). With none named,
// every account. Someone is hidden from a read only when every account in
// its scope has blocked them, so what only account A blocked is not hidden
// from B's read; with one account this is that account's list. A read that
// names several accounts, or none, is narrowed further by each app's own
// per-account filter.

// readScope is the vault's own accounts filter names, or all of them.
func readScope(filter nostr.Filter) []string {
	own := whitelist()
	var scope []string
	add := func(keys []string) {
		for _, pk := range keys {
			if _, ok := own[pk]; ok && !slices.Contains(scope, pk) {
				scope = append(scope, pk)
			}
		}
	}
	add(filter.Tags["p"])
	add(filter.Authors)
	if len(scope) > 0 {
		return scope
	}
	return slices.Collect(maps.Keys(own))
}

// servesAuthor reports whether events by pubkey may be served to a read with
// this scope. Your own accounts are always served, even if one appears on a
// block list.
func servesAuthor(scope []string, pubkey string) bool {
	if _, own := whitelist()[pubkey]; own {
		return true
	}
	return !isBlacklisted(pubkey) && !blockedByAll(scope, pubkey)
}

// hiddenAuthors is the people hidden from a read with this scope, narrowed
// to filterAuthors when the filter names any.
func hiddenAuthors(scope, filterAuthors []string) []string {
	var out []string
	consider := func(pk string) {
		if !servesAuthor(scope, pk) && !slices.Contains(out, pk) {
			out = append(out, pk)
		}
	}
	if len(filterAuthors) > 0 {
		for _, pk := range filterAuthors {
			consider(pk)
		}
		return out
	}
	for _, pk := range blacklistedPubkeys() {
		consider(pk)
	}
	// Everyone the scope's accounts all blocked is on the first one's list.
	if len(scope) > 0 {
		for pk := range accountBlocks()[scope[0]] {
			consider(pk)
		}
	}
	return out
}

// hideBlacklistedQuery wraps a QueryEvents hook so events by blocked people
// are not served.
func hideBlacklistedQuery(query func(context.Context, nostr.Filter) (chan *nostr.Event, error)) func(context.Context, nostr.Filter) (chan *nostr.Event, error) {
	return func(ctx context.Context, filter nostr.Filter) (chan *nostr.Event, error) {
		ch, err := query(ctx, filter)
		if err != nil || ch == nil || eventstore.IsNegentropySession(ctx) {
			return ch, err
		}
		scope := readScope(filter)
		if len(hiddenAuthors(scope, filter.Authors)) == 0 {
			return ch, err
		}
		out := make(chan *nostr.Event)
		go func() {
			defer close(out)
			for ev := range ch {
				if !servesAuthor(scope, ev.PubKey) {
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

// hideBlacklistedCount wraps a CountEvents hook so COUNT leaves out blocked
// people too: the total minus the same filter narrowed to them.
func hideBlacklistedCount(count func(context.Context, nostr.Filter) (int64, error)) func(context.Context, nostr.Filter) (int64, error) {
	return func(ctx context.Context, filter nostr.Filter) (int64, error) {
		n, err := count(ctx, filter)
		if err != nil || eventstore.IsNegentropySession(ctx) {
			return n, err
		}
		hidden := hiddenAuthors(readScope(filter), filter.Authors)
		if len(hidden) == 0 {
			return n, nil
		}
		narrowed := filter.Clone()
		narrowed.Authors = hidden
		m, err := count(ctx, narrowed)
		if err != nil {
			return n, nil
		}
		return max(n-m, 0), nil
	}
}
