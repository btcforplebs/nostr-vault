package main

import (
	"context"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// postRefs is what a note points at: event ids, and the coordinates
// (kind:pubkey:d) of addressable events such as long-form articles.
type postRefs struct {
	ids   []string
	addrs []nostr.EntityPointer
}

func (r postRefs) count() int { return len(r.ids) + len(r.addrs) }

// collectPostRefs gathers the references held by the tags `want` accepts.
// A tag's value is read as an event id or an address, whichever it is: a
// NIP-18 `q` tag may hold either.
func collectPostRefs(ev *nostr.Event, want func(nostr.Tag) bool) postRefs {
	var refs postRefs
	for _, tag := range ev.Tags {
		if len(tag) < 2 || !want(tag) {
			continue
		}
		if nostr.IsValid32ByteHex(tag[1]) {
			refs.ids = append(refs.ids, tag[1])
		} else if ptr, err := nostr.EntityPointerFromTag(tag); err == nil {
			refs.addrs = append(refs.addrs, ptr)
		}
	}
	return refs
}

// pointsAtPostBy reports whether any of refs names a post in the outbox
// written by one of authors. The outbox is checked rather than trusting the
// pubkey inside a tag: anyone can write an address or hint naming the owner.
func pointsAtPostBy(ctx context.Context, refs postRefs, authors map[string]struct{}) bool {
	if outboxDB == nil || refs.count() == 0 || len(authors) == 0 {
		return false
	}
	// A reply or quote carries one or two references; dozens is not one.
	if refs.count() > 10 {
		return false
	}
	qctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if len(refs.ids) > 0 {
		// The author is checked on each result, not in the filter: a lookup
		// by IDs ignores the filter's Authors, which let a reply to anyone's
		// post in the outbox through.
		ch, err := outboxDB.QueryEvents(qctx, nostr.Filter{IDs: refs.ids})
		if err == nil {
			found := false
			for parent := range ch {
				if _, ok := authors[parent.PubKey]; ok {
					found = true
				}
			}
			if found {
				return true
			}
		}
	}
	for _, addr := range refs.addrs {
		if _, ok := authors[addr.PublicKey]; !ok {
			continue
		}
		f := addr.AsFilter()
		f.Limit = 1
		ch, err := outboxDB.QueryEvents(qctx, f)
		if err != nil {
			continue
		}
		found := false
		for range ch {
			found = true
		}
		if found {
			return true
		}
	}
	return false
}

// engagesOwnerPost reports whether ev is a text note or comment answering or
// quoting a post a whitelisted account wrote: a reply (e/E, any marker, so
// a reply deeper in the owner's thread qualifies too), a quote (q), or a
// reply or comment on one of the owner's articles (a/A).
func engagesOwnerPost(ctx context.Context, ev *nostr.Event) bool {
	if ev.Kind != nostr.KindTextNote && ev.Kind != nostr.KindComment {
		return false
	}
	refs := collectPostRefs(ev, func(tag nostr.Tag) bool {
		switch tag[0] {
		case "e", "E", "q", "a", "A":
			return true
		}
		return false
	})
	return pointsAtPostBy(ctx, refs, config.WhitelistedPubKeys)
}

// isReplyNote reports whether a text note answers another: it has an `e` tag
// that is not a NIP-10 "mention" marker, which is a quote, never a parent.
func isReplyNote(ev *nostr.Event) bool {
	for _, tag := range ev.Tags {
		if len(tag) >= 2 && tag[0] == "e" && (len(tag) < 4 || tag[3] != "mention") {
			return true
		}
	}
	return false
}

// quotesPostBy reports whether ev quotes a post the recipient wrote, through
// a NIP-18 `q` tag or the older `e` tag marked "mention".
func quotesPostBy(ctx context.Context, ev *nostr.Event, recipient string) bool {
	if recipient == "" {
		return false
	}
	refs := collectPostRefs(ev, func(tag nostr.Tag) bool {
		return tag[0] == "q" || (tag[0] == "e" && len(tag) >= 4 && tag[3] == "mention")
	})
	return pointsAtPostBy(ctx, refs, map[string]struct{}{recipient: {}})
}
