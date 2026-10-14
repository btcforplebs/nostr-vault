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

	for _, r := range plan(filter) {
		lower := since
		if top.full() && int64(top.oldest().CreatedAt) > lower {
			lower = int64(top.oldest().CreatedAt)
		}
		lo := append(slices.Clone(r.prefix), lower)
		hi := append(slices.Clone(r.prefix), until)
		var bound js.Value
		var err error
		if len(r.prefix) == 0 {
			bound, err = jsCall(keyRangeCls, "bound", lower, until)
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
		err = cursorWalk(req, func(cursor js.Value) bool {
			id := cursor.Get("primaryKey").String()
			if top.full() {
				ca := int64(cursor.Get("value").Get("ca").Int())
				o := top.oldest()
				// Records come newest first (ties by id descending), so once
				// one can't beat the oldest kept event, none after it can.
				if ca < int64(o.CreatedAt) || (ca == int64(o.CreatedAt) && id < o.ID) {
					return false
				}
			}
			if _, ok := seen[id]; ok {
				return true
			}
			evt, err := decode(cursor.Get("value"))
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
	}

	return top.sorted(), nil
}

// plan turns a filter into one index range per combination of its values.
// Whatever a range doesn't pin down is checked by filter.Matches.
func plan(filter nostr.Filter) []keyRange {
	authors := dedup(filter.Authors)
	kinds := dedup(filter.Kinds)

	switch {
	case len(authors) > 0 && len(kinds) > 0:
		out := make([]keyRange, 0, len(authors)*len(kinds))
		for _, a := range authors {
			for _, k := range kinds {
				out = append(out, keyRange{idxAuthorKind, []any{a, k}})
			}
		}
		return out
	case len(authors) > 0:
		out := make([]keyRange, 0, len(authors))
		for _, a := range authors {
			out = append(out, keyRange{idxAuthor, []any{a}})
		}
		return out
	}

	if name, values, ok := narrowestTag(filter.Tags); ok {
		out := make([]keyRange, 0, len(values))
		for _, v := range values {
			out = append(out, keyRange{idxTag, []any{name, v}})
		}
		return out
	}

	if len(kinds) > 0 {
		out := make([]keyRange, 0, len(kinds))
		for _, k := range kinds {
			out = append(out, keyRange{idxKind, []any{k}})
		}
		return out
	}

	return []keyRange{{idxCreatedAt, nil}}
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
