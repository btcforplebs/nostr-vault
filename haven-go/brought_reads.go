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

// inboxHides: an inbox event is hidden from a reader that is not the vault's
// own when it tags a brought-over account and none of the vault's other own
// keys. One tagging the owner too stays visible (it is the owner's mail).
func inboxHides(ev *nostr.Event, brought map[string]struct{}) bool {
	own := whitelist()
	tagsBrought := false
	for tag := range ev.Tags.FindAll("p") {
		if len(tag) < 2 {
			continue
		}
		if _, b := brought[tag[1]]; b {
			tagsBrought = true
			continue
		}
		if _, o := own[tag[1]]; o {
			return false
		}
	}
	return tagsBrought
}

func hideBroughtInboxQuery(query func(context.Context, nostr.Filter) (chan *nostr.Event, error)) func(context.Context, nostr.Filter) (chan *nostr.Event, error) {
	return func(ctx context.Context, filter nostr.Filter) (chan *nostr.Event, error) {
		ch, err := query(ctx, filter)
		hidden := hiddenBrought(ctx, nil)
		if err != nil || ch == nil || len(hidden) == 0 {
			return ch, err
		}
		out := make(chan *nostr.Event)
		go func() {
			defer close(out)
			for ev := range ch {
				if inboxHides(ev, hidden) {
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

// hideBroughtInboxCount: the total minus the same filter narrowed to events
// tagging the hidden accounts. An event tagging an own key too is subtracted
// as well, so the count can come out low, never high.
func hideBroughtInboxCount(count func(context.Context, nostr.Filter) (int64, error)) func(context.Context, nostr.Filter) (int64, error) {
	return func(ctx context.Context, filter nostr.Filter) (int64, error) {
		n, err := count(ctx, filter)
		if err != nil {
			return n, err
		}
		hidden := hiddenBrought(ctx, nil)
		if len(hidden) == 0 {
			return n, nil
		}
		var ps []string
		if want, ok := filter.Tags["p"]; ok {
			for _, p := range want {
				if _, h := hidden[p]; h {
					ps = append(ps, p)
				}
			}
			if len(ps) == 0 {
				return n, nil
			}
		} else {
			for p := range hidden {
				ps = append(ps, p)
			}
		}
		narrowed := filter.Clone()
		tags := nostr.TagMap{}
		for k, v := range filter.Tags {
			tags[k] = v
		}
		tags["p"] = ps
		narrowed.Tags = tags
		m, err := count(ctx, narrowed)
		if err != nil {
			return 0, nil
		}
		return max(n-m, 0), nil
	}
}

// hideBroughtOnInbox wraps every query and count hook of the inbox relay
// (Tron #1808: a zip's events tagging its other accounts are stored but must
// not be served from the owner's /inbox). Call it after enableSearch.
func hideBroughtOnInbox(rl *khatru.Relay) {
	for i, q := range rl.QueryEvents {
		rl.QueryEvents[i] = hideBroughtInboxQuery(q)
	}
	for i, c := range rl.CountEvents {
		rl.CountEvents[i] = hideBroughtInboxCount(c)
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
