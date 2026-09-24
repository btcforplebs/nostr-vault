package main

// NIP-50 full-text search over haven's own stores.
//
// The eventstore backends (LMDB and Badger, v0.17.5) answer any filter that
// carries a `search` field with an empty result, and khatru has no search of
// its own. This file puts a search in front of each route's store:
//
//   - searchableQuery wraps a store's QueryEvents. A filter without `search`
//     goes straight to the store, unchanged. A filter with `search` walks the
//     store newest-first in until-paged batches (the same filter minus
//     `search`, so kinds/authors/tags/since/until are applied by the store's
//     indexes), matches each event's text in Go, and streams the matches until
//     the filter's limit, the end of the store, or a time budget is reached.
//
//   - detachSearchListener stops a search subscription from receiving live
//     events. khatru keeps every REQ filter open as a listener after EOSE and
//     matches new events with nostr.Filter.Matches, which ignores `search` —
//     so without this, a search subscription is sent every new event its
//     kinds/authors allow, matching or not.
//
//   - searchNeedsAnchor rejects a search filter with nothing else in it; see
//     detachSearchListener for why such a filter cannot be detached.
//
// A scan was chosen over eventstore's bluge index: bluge ORs terms, caps at
// 150 results, ranks by score, indexes kind 0 JSON raw, needs a second store
// kept in step with deletes/replaces plus a backfill of existing stores, and
// adds ~1.9 MB to libhaven. A full scan of 100k events takes ~0.1-0.25 s.
// The commit introducing this file has the measurements.

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"maps"
	"math"
	"slices"
	"strings"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

const (
	// searchPageSize is how many events each store read pulls. It must not
	// exceed either backend's MaxLimit (Badger 1000, LMDB 1500): a larger
	// limit is not rejected, it silently falls back to MaxLimit/4.
	searchPageSize = 1000
	// searchDefaultLimit applies when the filter has no limit.
	searchDefaultLimit = 100
	// searchMaxLimit caps what one search filter can ask for.
	searchMaxLimit = 500
)

// searchTimeBudget bounds how long one search filter may scan. When it runs
// out the results found so far stand and the subscription gets its EOSE.
// A variable so tests can shrink it.
var searchTimeBudget = 8 * time.Second

// searchExtensionKeys are NIP-50 `key:value` extensions. None is supported;
// NIP-50 says to ignore unsupported ones, so they are not treated as terms.
var searchExtensionKeys = map[string]bool{
	"include": true, "domain": true, "language": true, "sentiment": true, "nsfw": true,
}

// searchSkipKinds hold ciphertext in their content; a term "matching" a run of
// base64 is noise, not a result.
var searchSkipKinds = map[int]bool{
	nostr.KindEncryptedDirectMessage: true, // 4
	13:                               true, // seal
	nostr.KindGiftWrap:               true, // 1059
	1060:                             true,
}

// parseSearchTerms lowercases the query and splits it on whitespace, dropping
// NIP-50 extensions. An empty result means the filter can match nothing.
func parseSearchTerms(q string) []string {
	var terms []string
	for _, tok := range strings.Fields(strings.ToLower(q)) {
		if k, _, ok := strings.Cut(tok, ":"); ok && searchExtensionKeys[k] {
			continue
		}
		terms = append(terms, tok)
	}
	return terms
}

// searchText is the text of an event that a search matches against, already
// lowercased. Empty means the event is never a match.
func searchText(ev *nostr.Event) string {
	if searchSkipKinds[ev.Kind] {
		return ""
	}
	var parts []string
	if ev.Kind == nostr.KindProfileMetadata {
		// Kind 0 content is JSON; match the human fields, not the keys or
		// the picture/banner URLs.
		var md map[string]any
		if err := json.Unmarshal([]byte(ev.Content), &md); err != nil {
			return ""
		}
		for _, k := range []string{"name", "display_name", "displayName", "about", "nip05"} {
			if s, ok := md[k].(string); ok && s != "" {
				parts = append(parts, s)
			}
		}
	} else {
		parts = append(parts, ev.Content)
		// Long-form and similar kinds keep their headline in tags.
		for _, tag := range ev.Tags {
			if len(tag) >= 2 && (tag[0] == "title" || tag[0] == "summary" || tag[0] == "subject") {
				parts = append(parts, tag[1])
			}
		}
	}
	return strings.ToLower(strings.Join(parts, "\n"))
}

// eventMatchesSearch reports whether every term occurs in the event's text.
func eventMatchesSearch(ev *nostr.Event, terms []string) bool {
	if len(terms) == 0 {
		return false
	}
	text := searchText(ev)
	if text == "" {
		return false
	}
	for _, t := range terms {
		if !strings.Contains(text, t) {
			return false
		}
	}
	return true
}

// searchableQuery returns a QueryEvents hook for db that answers NIP-50
// filters with real matches and passes every other filter through untouched.
func searchableQuery(db DBBackend) func(context.Context, nostr.Filter) (chan *nostr.Event, error) {
	return func(ctx context.Context, filter nostr.Filter) (chan *nostr.Event, error) {
		if filter.Search == "" || eventstore.IsNegentropySession(ctx) {
			// A negentropy session with a search filter reaches the store,
			// which answers it with nothing — never with the unfiltered set.
			return db.QueryEvents(ctx, filter)
		}
		limit := filter.Limit
		if limit <= 0 {
			limit = searchDefaultLimit
		}
		if limit > searchMaxLimit {
			limit = searchMaxLimit
		}
		ch := make(chan *nostr.Event)
		go func() {
			defer close(ch)
			scanned, found, err := scanSearch(ctx, db, filter, limit, func(ev *nostr.Event) bool {
				select {
				case ch <- ev:
					return true
				case <-ctx.Done():
					return false
				}
			})
			if err != nil {
				slog.Info("search scan ended early", "search", filter.Search, "scanned", scanned, "found", found, "err", err)
			}
		}()
		return ch, nil
	}
}

// searchableCount keeps COUNT from answering a search filter with the
// unfiltered total (the stores' CountEvents ignore `search`). It does not
// count matches: the routes carry no COUNT read policy, and a match count
// would let an unauthenticated client probe the text of stored events.
func searchableCount(db DBBackend) func(context.Context, nostr.Filter) (int64, error) {
	return func(ctx context.Context, filter nostr.Filter) (int64, error) {
		if filter.Search != "" {
			return 0, errors.New("unsupported: search is not available in COUNT")
		}
		return db.CountEvents(ctx, filter)
	}
}

var errSearchBudget = errors.New("search time budget exhausted")

// scanSearch walks db newest-first with the filter minus `search`, calling
// emit for each event matching the search terms, until limit matches, the
// end of the store, the time budget, or emit returning false. It returns how
// many events it read and how many matched.
func scanSearch(ctx context.Context, db DBBackend, filter nostr.Filter, limit int, emit func(*nostr.Event) bool) (scanned, found int, err error) {
	terms := parseSearchTerms(filter.Search)
	if len(terms) == 0 {
		return 0, 0, nil
	}

	ctx, cancel := context.WithTimeout(ctx, searchTimeBudget)
	defer cancel()

	page := filter.Clone()
	page.Search = ""
	page.Limit = searchPageSize
	page.LimitZero = false

	// IDs of the events already read at the current `until` second. `until`
	// is inclusive, so the next page starts with them again.
	seenAtUntil := map[string]bool{}

	for {
		if err := ctx.Err(); err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				return scanned, found, errSearchBudget
			}
			return scanned, found, err
		}
		evch, err := db.QueryEvents(ctx, page)
		if err != nil {
			return scanned, found, err
		}
		var batch []*nostr.Event
		for ev := range evch {
			batch = append(batch, ev)
		}
		if len(batch) == 0 {
			return scanned, found, ctx.Err()
		}
		slices.SortStableFunc(batch, func(a, b *nostr.Event) int {
			switch {
			case a.CreatedAt > b.CreatedAt:
				return -1
			case a.CreatedAt < b.CreatedAt:
				return 1
			}
			return strings.Compare(a.ID, b.ID)
		})

		fresh := 0
		for _, ev := range batch {
			if seenAtUntil[ev.ID] {
				continue
			}
			fresh++
			scanned++
			if eventMatchesSearch(ev, terms) {
				found++
				if !emit(ev) {
					return scanned, found, ctx.Err()
				}
				if found >= limit {
					return scanned, found, nil
				}
			}
		}

		// A short page is the end of what the filter selects (this also
		// covers a store answering fewer because of a theoretical limit).
		if len(batch) < searchPageSize {
			return scanned, found, nil
		}

		oldest := batch[len(batch)-1].CreatedAt
		if page.Until != nil && oldest == *page.Until && fresh == 0 {
			// A whole page sits on one second and none of it is new: more
			// than searchPageSize events share this timestamp. Step past it
			// rather than loop; the rest of that one second is not searched.
			if oldest == 0 {
				return scanned, found, nil
			}
			next := oldest - 1
			page.Until = &next
			clear(seenAtUntil)
			continue
		}
		if page.Until == nil || oldest != *page.Until {
			clear(seenAtUntil)
		}
		for i := len(batch) - 1; i >= 0 && batch[i].CreatedAt == oldest; i-- {
			seenAtUntil[batch[i].ID] = true
		}
		next := oldest
		page.Until = &next
	}
}

// searchPoisonTag is a tag name no event carries; see detachSearchListener.
const searchPoisonTag = "\x00haven-search"

// detachSearchListener is an OverwriteFilter hook that keeps a search
// subscription from receiving live events after EOSE.
//
// khatru v0.19.1 hands each REQ filter, by value, both to the stored-events
// query (through this hook) and to its live listener. The copies share their
// slices, maps and pointers. So this hook gives the query side fresh copies
// of one reference field and then poisons the original, which the listener
// still holds, with a value no event can match. The query itself is
// unaffected. A filter with no reference field to poison is refused by
// searchNeedsAnchor. A khatru upgrade that changes the sharing is caught by
// TestSearchLiveEventsDoNotLeak.
func detachSearchListener(_ context.Context, f *nostr.Filter) {
	if f.Search == "" {
		return
	}
	switch {
	case len(f.Kinds) > 0:
		old := f.Kinds
		f.Kinds = slices.Clone(old)
		for i := range old {
			old[i] = -1
		}
	case len(f.Authors) > 0:
		old := f.Authors
		f.Authors = slices.Clone(old)
		for i := range old {
			old[i] = ""
		}
	case len(f.IDs) > 0:
		old := f.IDs
		f.IDs = slices.Clone(old)
		for i := range old {
			old[i] = ""
		}
	case len(f.Tags) > 0:
		old := f.Tags
		f.Tags = maps.Clone(old)
		old[searchPoisonTag] = []string{""}
	case f.Since != nil:
		old := f.Since
		v := *old
		f.Since = &v
		*old = nostr.Timestamp(math.MaxInt64)
	case f.Until != nil:
		old := f.Until
		v := *old
		f.Until = &v
		*old = -1
	}
}

// searchNeedsAnchor is a RejectFilter hook refusing a search filter that has
// nothing but `search` (and limit): detachSearchListener has no field to
// poison in it, so its live listener would receive every new event.
func searchNeedsAnchor(_ context.Context, f nostr.Filter) (bool, string) {
	if f.Search == "" {
		return false, ""
	}
	if len(f.Kinds) > 0 || len(f.Authors) > 0 || len(f.IDs) > 0 || len(f.Tags) > 0 || f.Since != nil || f.Until != nil {
		return false, ""
	}
	return true, "unsupported: a search filter must also name kinds, authors, ids, tags, since or until"
}

// enableSearch wires NIP-50 search into a route. It replaces the store's
// QueryEvents/CountEvents registration, so call it instead of appending
// db.QueryEvents and db.CountEvents, and after the route's read policies are
// in RejectFilter: those policies run on a search filter exactly as on any
// other, before the query, so /private and /chat stay auth-gated.
func enableSearch(rl *khatru.Relay, db DBBackend) {
	rl.OverwriteFilter = append(rl.OverwriteFilter, detachSearchListener)
	rl.RejectFilter = append(rl.RejectFilter, searchNeedsAnchor)
	rl.QueryEvents = append(rl.QueryEvents, searchableQuery(db))
	rl.CountEvents = append(rl.CountEvents, searchableCount(db))
	if !slices.Contains(rl.Info.SupportedNIPs, any(50)) {
		rl.Info.SupportedNIPs = append(rl.Info.SupportedNIPs, 50)
	}
}
