//go:build js && wasm

package idbstore

import (
	"container/heap"
	"math"
	"slices"
	"syscall/js"

	"github.com/nbd-wtf/go-nostr"
)

// keyRange is one index range walked newest-first: [prefix..., since] to
// [prefix..., until].
type keyRange struct {
	index  string
	prefix []any
	// until, when set, is a tighter upper bound than the filter's.
	until *int64
	// fallback is set on a range that stands in for many combinations (see
	// plan): the per-combination ranges to walk instead once the scan budget
	// runs out.
	fallback []keyRange
}

// query returns at most limit events matching filter, newest first, ordered
// exactly like nostr.CompareEventPtrReverse.
func (b *IDBBackend) query(store js.Value, filter nostr.Filter, limit int) ([]*nostr.Event, error) {
	if limit <= 0 {
		return nil, nil
	}

	if len(filter.IDs) > 0 {
		var out []*nostr.Event
		seen := make(map[string]struct{}, len(filter.IDs))
		for _, id := range filter.IDs {
			if _, ok := seen[id]; ok {
				continue
			}
			seen[id] = struct{}{}
			req, err := jsCall(store, "get", id)
			if err != nil {
				return nil, err
			}
			rec, err := await(req)
			if err != nil {
				return nil, err
			}
			if rec.IsUndefined() {
				continue
			}
			evt, err := decode(rec)
			if err != nil {
				return nil, err
			}
			if filter.Matches(evt) {
				out = append(out, evt)
			}
		}
		slices.SortFunc(out, nostr.CompareEventPtrReverse)
		if len(out) > limit {
			out = out[:limit]
		}
		return out, nil
	}

	since := int64(0)
	if filter.Since != nil {
		since = int64(*filter.Since)
	}
	until := int64(math.MaxUint32)
	if filter.Until != nil {
		until = int64(*filter.Until)
	}
	if since > until {
		return nil, nil
	}

	keyRangeCls := js.Global().Get("IDBKeyRange")
	top := &newest{limit: limit}
	seen := make(map[string]struct{})
	authors := setOf(filter.Authors)
	kinds := setOf(filter.Kinds)

	// A range with a fallback walks records of authors or kinds the filter
	// doesn't want. When those it wants are sparse, the walk could cover the
	// whole index, so it gets a record budget; past it, the rest of the range
	// is walked as per-combination ranges, below the last record visited.
	budget := scanBudget + 2*min(limit, 1000)

	work := plan(filter)
	for i := 0; i < len(work); i++ {
		r := work[i]
		if r.fallback != nil && budget <= 0 {
			work = append(work, r.fallback...)
			continue
		}
		lower := since
		if top.full() && int64(top.oldest().CreatedAt) > lower {
			lower = int64(top.oldest().CreatedAt)
		}
		upper := until
		if r.until != nil && *r.until < upper {
			upper = *r.until
		}
		if lower > upper {
			continue
		}
		lo := append(slices.Clone(r.prefix), lower)
		hi := append(slices.Clone(r.prefix), upper)
		var bound js.Value
		var err error
		if len(r.prefix) == 0 {
			bound, err = jsCall(keyRangeCls, "bound", lower, upper)
		} else {
			bound, err = jsCall(keyRangeCls, "bound", lo, hi)
		}
		if err != nil {
			return nil, err
		}
		req, err := jsCall(store.Call("index", r.index), "openCursor", bound, "prev")
		if err != nil {
			return nil, err
		}

		var walkErr error
		stoppedAt := int64(-1)
		err = cursorWalk(req, func(cursor js.Value) bool {
			id := cursor.Get("primaryKey").String()
			rec := cursor.Get("value")
			if top.full() {
				ca := int64(rec.Get("ca").Int())
				o := top.oldest()
				// Records come newest first (ties by id descending), so once
				// one can't beat the oldest kept event, none after it can.
				if ca < int64(o.CreatedAt) || (ca == int64(o.CreatedAt) && id < o.ID) {
					return false
				}
			}
			cursorVisits++
			if r.fallback != nil {
				if budget <= 0 {
					stoppedAt = int64(rec.Get("ca").Int())
					return false
				}
				budget--
			}
			if _, ok := seen[id]; ok {
				return true
			}
			// A range that doesn't pin the author or kind (see plan) walks
			// records of other authors or kinds; skip them before decoding.
			if authors != nil {
				if _, ok := authors[rec.Get("pk").String()]; !ok {
					return true
				}
			}
			if kinds != nil {
				if _, ok := kinds[rec.Get("k").Int()]; !ok {
					return true
				}
			}
			evt, err := decode(rec)
			if err != nil {
				walkErr = err
				return false
			}
			if !filter.Matches(evt) {
				return true
			}
			seen[id] = struct{}{}
			top.add(evt)
			return true
		})
		if err != nil {
			return nil, err
		}
		if walkErr != nil {
			return nil, walkErr
		}
		if stoppedAt >= 0 {
			// Inclusive: records at stoppedAt not yet visited are still due,
			// and seen skips the ones already kept.
			for _, fb := range r.fallback {
				fb.until = &stoppedAt
				work = append(work, fb)
			}
		}
	}

	return top.sorted(), nil
}

// maxRanges caps how many index ranges one filter opens. Every range is its
// own cursor, opened from Go one after another, so a follows feed (1,000
// authors x 8 kinds = 8,000 ranges) spent seconds just opening cursors.
const maxRanges = 64

// cursorVisits counts records visited by query, for tests.
var cursorVisits int

// scanBudget is the base number of records a range with a fallback may visit
// (plus 2 per requested event, up to 1,000): about 40 us each in Chrome.
const scanBudget = 500

// plan turns a filter into one index range per combination of its values.
// Whatever a range doesn't pin down is checked by filter.Matches.
//
// When the combinations pass maxRanges, plan walks only the smaller side's
// index (or created_at, when both sides are too big) and leaves the other side
// to the author and kind checks in query. The walks still run newest first and
// stop at limit, so a feed read visits roughly limit records. If the wanted
// authors are sparse in that index, the walk hits its record budget and query
// finishes with the per-combination ranges (each range's fallback).
func plan(filter nostr.Filter) []keyRange {
	authors := dedup(filter.Authors)
	kinds := dedup(filter.Kinds)

	if len(authors) > 0 && len(kinds) > 0 {
		switch {
		case len(authors)*len(kinds) <= maxRanges:
			return authorKindRanges(authors, kinds)
		case len(kinds) <= len(authors) && len(kinds) <= maxRanges:
			out := kindRanges(kinds)
			for i, k := range kinds {
				out[i].fallback = authorKindRanges(authors, []int{k})
			}
			return out
		case len(authors) <= maxRanges:
			out := authorRanges(authors)
			for i, a := range authors {
				out[i].fallback = authorKindRanges([]string{a}, kinds)
			}
			return out
		}
		return []keyRange{{index: idxCreatedAt, fallback: authorKindRanges(authors, kinds)}}
	}

	if len(authors) > maxRanges {
		return []keyRange{{index: idxCreatedAt, fallback: authorRanges(authors)}}
	}
	if len(authors) > 0 {
		return authorRanges(authors)
	}

	if name, values, ok := narrowestTag(filter.Tags); ok {
		out := make([]keyRange, 0, len(values))
		for _, v := range values {
			out = append(out, keyRange{index: idxTag, prefix: []any{name, v}})
		}
		return out
	}

	if len(kinds) > 0 {
		return kindRanges(kinds)
	}

	return []keyRange{{index: idxCreatedAt}}
}

func authorKindRanges(authors []string, kinds []int) []keyRange {
	out := make([]keyRange, 0, len(authors)*len(kinds))
	for _, a := range authors {
		for _, k := range kinds {
			out = append(out, keyRange{index: idxAuthorKind, prefix: []any{a, k}})
		}
	}
	return out
}

func authorRanges(authors []string) []keyRange {
	out := make([]keyRange, 0, len(authors))
	for _, a := range authors {
		out = append(out, keyRange{index: idxAuthor, prefix: []any{a}})
	}
	return out
}

func kindRanges(kinds []int) []keyRange {
	out := make([]keyRange, 0, len(kinds))
	for _, k := range kinds {
		out = append(out, keyRange{index: idxKind, prefix: []any{k}})
	}
	return out
}

// narrowestTag picks the tag with the fewest values to drive the index.
// A tag with an empty value list matches nothing, so it is the narrowest.
func narrowestTag(tags nostr.TagMap) (string, []string, bool) {
	var name string
	var values []string
	found := false
	for k, v := range tags {
		if v == nil {
			continue
		}
		if !found || len(v) < len(values) || (len(v) == len(values) && k < name) {
			name, values, found = k, v, true
		}
	}
	return name, dedup(values), found
}

// setOf returns the values as a set, or nil when there are none (no constraint).
func setOf[T comparable](in []T) map[T]struct{} {
	if len(in) == 0 {
		return nil
	}
	out := make(map[T]struct{}, len(in))
	for _, v := range in {
		out[v] = struct{}{}
	}
	return out
}

func dedup[T comparable](in []T) []T {
	seen := make(map[T]struct{}, len(in))
	out := make([]T, 0, len(in))
	for _, v := range in {
		if _, ok := seen[v]; ok {
			continue
		}
		seen[v] = struct{}{}
		out = append(out, v)
	}
	return out
}

func decode(rec js.Value) (*nostr.Event, error) {
	evt := &nostr.Event{}
	if err := evt.UnmarshalJSON([]byte(rec.Get("j").String())); err != nil {
		return nil, err
	}
	return evt, nil
}

// newest keeps the `limit` newest events seen so far; the root is the oldest.
type newest struct {
	limit  int
	events []*nostr.Event
}

func (h *newest) Len() int           { return len(h.events) }
func (h *newest) Less(i, j int) bool { return nostr.CompareEventPtr(h.events[i], h.events[j]) < 0 }
func (h *newest) Swap(i, j int)      { h.events[i], h.events[j] = h.events[j], h.events[i] }
func (h *newest) Push(x any)         { h.events = append(h.events, x.(*nostr.Event)) }
func (h *newest) Pop() any {
	last := h.events[len(h.events)-1]
	h.events = h.events[:len(h.events)-1]
	return last
}

func (h *newest) full() bool           { return len(h.events) >= h.limit }
func (h *newest) oldest() *nostr.Event { return h.events[0] }

func (h *newest) add(evt *nostr.Event) {
	if !h.full() {
		heap.Push(h, evt)
		return
	}
	if nostr.CompareEventPtr(evt, h.oldest()) > 0 {
		h.events[0] = evt
		heap.Fix(h, 0)
	}
}

func (h *newest) sorted() []*nostr.Event {
	out := slices.Clone(h.events)
	slices.SortFunc(out, nostr.CompareEventPtrReverse)
	return out
}
