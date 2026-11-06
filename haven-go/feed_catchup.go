package main

// Catch Up feed (local DVM): the newest post of each person you follow,
// newest first. One note per person, so a quiet friend's one post this week
// sits next to a busy account's latest instead of under its fifty.
//
// The follow list comes from the app (the active account's, which the relay
// does not know when several accounts share it). Notes come from the local
// stores first: feedsync keeps the follows' recent notes in feedDB. Only the
// people with nothing local are asked of the seed relays, in one bounded
// pass, like Popular's note bodies (resolveNoteBodies).

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

const (
	// How far back a person's latest post may be and still show.
	catchUpWindow = 14 * 24 * time.Hour
	// Posts read per person locally: enough to step over a few replies to
	// find their latest post of their own.
	catchUpPerAuthor = 8
	// Most people one Catch Up lists.
	catchUpMaxNotes = 500
	// Authors per network request; seed relays answer oversized author
	// filters with little (see wot listBatchSize).
	catchUpFetchBatch = 250
)

// catchUpKinds are the posts Catch Up shows: notes and articles.
var catchUpKinds = []int{1, 30023}

// pickLatestPerAuthor keeps, for each wanted author, their newest post that
// is not a reply, within the window and not dated in the future. Sorted
// newest first, ties broken on id so the order is total.
func pickLatestPerAuthor(events []*nostr.Event, wanted map[string]struct{}, now time.Time) []PopularNote {
	since := now.Add(-catchUpWindow).Unix()
	ahead := now.Add(popularMaxClockSkew).Unix()
	best := make(map[string]*nostr.Event, len(wanted))
	for _, ev := range events {
		if ev == nil {
			continue
		}
		if _, ok := wanted[ev.PubKey]; !ok {
			continue
		}
		at := int64(ev.CreatedAt)
		if at < since || at > ahead || (ev.Kind == 1 && isReplyNote(ev)) {
			continue
		}
		if cur := best[ev.PubKey]; cur == nil || at > int64(cur.CreatedAt) || (at == int64(cur.CreatedAt) && ev.ID < cur.ID) {
			best[ev.PubKey] = ev
		}
	}
	out := make([]PopularNote, 0, len(best))
	for _, ev := range best {
		out = append(out, toPopularNote(ev, float64(ev.CreatedAt)))
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].CreatedAt != out[j].CreatedAt {
			return out[i].CreatedAt > out[j].CreatedAt
		}
		return out[i].ID < out[j].ID
	})
	if len(out) > catchUpMaxNotes {
		out = out[:catchUpMaxNotes]
	}
	return out
}

// toPopularNote is the shape every local DVM feed returns.
func toPopularNote(ev *nostr.Event, score float64) PopularNote {
	tags := make([][]string, len(ev.Tags))
	for i, tag := range ev.Tags {
		tags[i] = []string(tag)
	}
	return PopularNote{
		ID: ev.ID, PubKey: ev.PubKey, Content: ev.Content, CreatedAt: int64(ev.CreatedAt),
		Tags: tags, Kind: ev.Kind, Score: score,
	}
}

// normalizeFollows lowercases, drops anything that is not a hex pubkey and
// de-duplicates, keeping order.
func normalizeFollows(follows []string) []string {
	seen := make(map[string]struct{}, len(follows))
	out := make([]string, 0, len(follows))
	for _, pk := range follows {
		pk = strings.ToLower(strings.TrimSpace(pk))
		if len(pk) != 64 || !isHex(pk) {
			continue
		}
		if _, dup := seen[pk]; dup {
			continue
		}
		seen[pk] = struct{}{}
		out = append(out, pk)
	}
	return out
}

func isHex(s string) bool {
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// fetchCatchUpFromNetwork asks the seed relays for the posts of the people
// nothing local had. A variable so a test can see whether it was reached.
var fetchCatchUpFromNetwork = func(ctx context.Context, authors []string, since nostr.Timestamp) []*nostr.Event {
	if pool == nil || len(authors) == 0 {
		return nil
	}
	relays := config.ImportSeedRelays
	if len(relays) == 0 {
		return nil
	}
	fetchCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	var out []*nostr.Event
	seen := make(map[string]struct{})
	for start := 0; start < len(authors); start += catchUpFetchBatch {
		end := min(start+catchUpFetchBatch, len(authors))
		filter := nostr.Filter{Kinds: catchUpKinds, Authors: authors[start:end], Since: &since, Limit: 500}
		for ev := range pool.FetchMany(fetchCtx, relays, filter) {
			if _, dup := seen[ev.ID]; dup || ev.Event == nil {
				continue
			}
			// Relays are not trusted to have checked the id or signature.
			if !verifiedRelayEvent(ev.Event) {
				continue
			}
			seen[ev.ID] = struct{}{}
			out = append(out, ev.Event)
		}
		if fetchCtx.Err() != nil {
			break
		}
	}
	return out
}

// queryLocalPerAuthor reads each author's newest posts from the local stores.
func queryLocalPerAuthor(ctx context.Context, authors []string, since nostr.Timestamp) []*nostr.Event {
	var out []*nostr.Event
	for _, db := range []DBBackend{feedDB, outboxDB} {
		if db == nil {
			continue
		}
		wdb := eventstore.RelayWrapper{Store: db}
		for _, pk := range authors {
			if ctx.Err() != nil {
				return out
			}
			evs, err := wdb.QuerySync(ctx, nostr.Filter{Kinds: catchUpKinds, Authors: []string{pk}, Since: &since, Limit: catchUpPerAuthor})
			if err != nil {
				continue
			}
			out = append(out, evs...)
		}
	}
	return out
}

// computeCatchUpNotes answers the Catch Up feed for these follows.
func computeCatchUpNotes(ctx context.Context, follows []string) ([]PopularNote, error) {
	now := time.Now()
	authors := normalizeFollows(follows)
	if len(authors) == 0 {
		return []PopularNote{}, nil
	}
	wanted := make(map[string]struct{}, len(authors))
	for _, pk := range authors {
		wanted[pk] = struct{}{}
	}
	since := nostr.Timestamp(now.Add(-catchUpWindow).Unix())

	events := queryLocalPerAuthor(ctx, authors, since)
	have := make(map[string]struct{}, len(events))
	for _, n := range pickLatestPerAuthor(events, wanted, now) {
		have[n.PubKey] = struct{}{}
	}
	missing := make([]string, 0, len(authors)-len(have))
	for _, pk := range authors {
		if _, ok := have[pk]; !ok {
			missing = append(missing, pk)
		}
	}
	events = append(events, fetchCatchUpFromNetwork(ctx, missing, since)...)
	return pickLatestPerAuthor(events, wanted, now), nil
}
