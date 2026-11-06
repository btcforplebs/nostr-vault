package main

// Brought-over accounts (copy-brought.json: from a backup zip, a copy or a
// catch-up, not this vault's own then) are stored and read only: nothing they
// wrote is uploaded (outboxNegStore.QueryEvents) or served on the public
// outbox (Logen, 2026-11-06). These hooks hide them from every outbox read
// except the vault's own: a reader authenticated as one of its accounts, or
// the browser build's owner stream. Negentropy is gated too: a stranger must
// not reconcile them out either.

import (
	"context"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// ownReader: the connection is the vault's own (NIP-42 as one of its
// accounts, or the browser build's owner stream). Loopback is not enough: a
// tunnel or the mesh arrives from 127.0.0.1 too.
func ownReader(ctx context.Context) bool {
	if ownerStream(ctx) {
		return true
	}
	authed := khatru.GetAuthed(ctx)
	if authed == "" {
		return false
	}
	_, ok := whitelist()[authed]
	return ok
}

// hiddenBrought: the brought-over accounts this read must not see (nil when
// the reader is the vault's own), narrowed to the filter's authors if any.
func hiddenBrought(ctx context.Context, filterAuthors []string) map[string]struct{} {
	brought := broughtAccounts()
	if len(brought) == 0 || ownReader(ctx) {
		return nil
	}
	if len(filterAuthors) == 0 {
		return brought
	}
	out := map[string]struct{}{}
	for _, pk := range filterAuthors {
		if _, b := brought[pk]; b {
			out[pk] = struct{}{}
		}
	}
	return out
}

func hideBroughtQuery(query func(context.Context, nostr.Filter) (chan *nostr.Event, error)) func(context.Context, nostr.Filter) (chan *nostr.Event, error) {
	return func(ctx context.Context, filter nostr.Filter) (chan *nostr.Event, error) {
		ch, err := query(ctx, filter)
		// A lookup by IDs ignores Authors, so it is always filtered when any
		// account is hidden; only a filter naming no hidden author skips it.
		hidden := hiddenBrought(ctx, nil)
		if err != nil || ch == nil || len(hidden) == 0 {
			return ch, err
		}
		out := make(chan *nostr.Event)
		go func() {
			defer close(out)
			for ev := range ch {
				if _, h := hidden[ev.PubKey]; h {
					continue
				}
				select {
				case out <- ev:
				case <-ctx.Done():
					for range ch {
					}
					return
				}
			}
		}()
		return out, nil
	}
}

// hideBroughtCount: the total minus the same filter narrowed to the hidden
// accounts.
func hideBroughtCount(count func(context.Context, nostr.Filter) (int64, error)) func(context.Context, nostr.Filter) (int64, error) {
	return func(ctx context.Context, filter nostr.Filter) (int64, error) {
		n, err := count(ctx, filter)
		if err != nil {
			return n, err
		}
		hidden := hiddenBrought(ctx, filter.Authors)
		if len(hidden) == 0 {
			return n, nil
		}
		narrowed := filter.Clone()
		narrowed.Authors = nil
		for pk := range hidden {
			narrowed.Authors = append(narrowed.Authors, pk)
		}
		m, err := count(ctx, narrowed)
		if err != nil {
			// Unsure how many are hidden: say nothing rather than leak.
			return 0, nil
		}
		return max(n-m, 0), nil
	}
}

// hideBroughtOnOutbox wraps every query and count hook of the outbox relay.
// Call it after enableSearch.
func hideBroughtOnOutbox(rl *khatru.Relay) {
	for i, q := range rl.QueryEvents {
		rl.QueryEvents[i] = hideBroughtQuery(q)
	}
	for i, c := range rl.CountEvents {
		rl.CountEvents[i] = hideBroughtCount(c)
	}
}
