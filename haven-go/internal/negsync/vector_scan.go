package negsync

import (
	"context"
	"log/slog"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// A negentropy vector needs only each event's id and created_at, but the
// stores answer a vector query the way they answer a REQ: Badger's
// QueryEvents decodes every matching event (content, tags, sig) into one
// slice before sending the first (eventstore badger/query.go), up to
// MaxLimitNegentropy (100k on the Mac). Several builds overlapping at launch
// (inbox+chat, owner, feed, Mac backfill, and every NEG-OPEN a device sends
// this relay) held hundreds of MB to over a GB of whole events at once,
// enough to pin the Go heap at its limit (RESEARCH/NV_MAC_RELAY_HEAP_2026_11_12.md).
//
// ForVector marks a context as "this query only feeds a vector". A store that
// sees the mark may answer page by page with id+created_at stubs (ScanIDs)
// instead of whole events, and takes the scan gate first so only one such
// scan holds decoded events at a time.

type forVectorKey struct{}

// ForVector marks ctx: the query it carries only needs id and created_at.
// BuildVector sets it; the relay's served NEG-OPEN sets it through khatru's
// NegentropyContext hook.
func ForVector(ctx context.Context) context.Context {
	return context.WithValue(ctx, forVectorKey{}, true)
}

// Unmark clears the ForVector mark: a hook inside a NEG-OPEN that reads a
// store itself and checks fields beyond id and created_at (kind, author,
// tags) needs whole events, not stubs (Tron, PR 1956: /lists filters on
// kind and author). The negentropy session flag itself is kept.
func Unmark(ctx context.Context) context.Context {
	if !IsForVector(ctx) {
		return ctx
	}
	return context.WithValue(ctx, forVectorKey{}, false)
}

// IsForVector reports whether ctx was marked by ForVector.
func IsForVector(ctx context.Context) bool {
	v, _ := ctx.Value(forVectorKey{}).(bool)
	return v
}

// scanGate lets one vector scan run at a time, process-wide: client builds
// and served NEG-OPENs alike.
var scanGate = make(chan struct{}, 1)

// ScanGateWait is the longest a scan waits for the gate. Past it the scan
// runs anyway (and says so): a slow consumer holding the gate must never
// stall sync for good, and two scans overlapping is the old behaviour, not a
// failure. A var so tests can shorten it.
var ScanGateWait = 30 * time.Second

// AcquireScan takes the scan gate. release must be called exactly once when
// the scan is done; it is a no-op when the wait ran out and the scan went
// ahead ungated. err is ctx's error if ctx ended while waiting.
func AcquireScan(ctx context.Context) (release func(), err error) {
	select {
	case scanGate <- struct{}{}:
		return releaseGate, nil
	default:
	}
	t := time.NewTimer(ScanGateWait)
	defer t.Stop()
	select {
	case scanGate <- struct{}{}:
		return releaseGate, nil
	case <-ctx.Done():
		return func() {}, ctx.Err()
	case <-t.C:
		slog.Warn("negentropy vector scan waited too long for the scan gate, running alongside another", "wait", ScanGateWait)
		return func() {}, nil
	}
}

func releaseGate() { <-scanGate }

// QueryFunc is a store's QueryEvents.
type QueryFunc func(context.Context, nostr.Filter) (chan *nostr.Event, error)

// ScanIDs sends emit the newest limit events matching f, as stubs holding
// only ID and CreatedAt, querying q page events at a time from the newest
// down (Until steps back to each page's oldest second; events already sent
// from that second are skipped). Only one page of decoded events is alive at
// a time. emit returning false stops the scan. Stub order follows the pages:
// newest first, not sorted within a second.
//
// q must honour Limit and Until and return the newest Limit matches, as the
// eventstores do. If one second holds more than a page of events, that
// second is read whole (Limit = limit) so the scan always moves on.
func ScanIDs(ctx context.Context, q QueryFunc, f nostr.Filter, limit, page int, emit func(*nostr.Event) bool) error {
	if limit <= 0 || page <= 0 {
		return nil
	}
	var until *nostr.Timestamp
	if f.Until != nil {
		u := *f.Until
		until = &u
	}
	// seen holds the ids already sent from second boundary, the Until of the
	// next page, so the overlap is not sent twice.
	var seen map[string]struct{}
	var boundary nostr.Timestamp
	sent := 0

	for sent < limit {
		if err := ctx.Err(); err != nil {
			return err
		}
		pf := f
		pf.Limit = page
		pf.LimitZero = false
		pf.Until = until
		ch, err := q(ctx, pf)
		if err != nil {
			return err
		}
		n, fresh := 0, 0
		var oldest nostr.Timestamp
		var atOldest []string
		stopped := false
		for ev := range ch {
			n++
			if stopped {
				continue // drain so the store's goroutine finishes
			}
			switch {
			case n == 1 || ev.CreatedAt < oldest:
				oldest = ev.CreatedAt
				atOldest = append(atOldest[:0], ev.ID)
			case ev.CreatedAt == oldest:
				atOldest = append(atOldest, ev.ID)
			}
			if seen != nil && ev.CreatedAt == boundary {
				if _, dup := seen[ev.ID]; dup {
					continue
				}
			}
			if sent >= limit {
				continue
			}
			if !emit(&nostr.Event{ID: ev.ID, CreatedAt: ev.CreatedAt}) {
				stopped = true
				continue
			}
			sent++
			fresh++
		}
		if stopped {
			return ctx.Err()
		}
		if n < page {
			return nil // the store ran out
		}
		if fresh == 0 {
			// A whole page from one second, every id already sent: more
			// events share that second than a page holds. Read it whole.
			sec := oldest
			sf := f
			sf.Since, sf.Until = &sec, &sec
			sf.Limit = limit
			sf.LimitZero = false
			ch, err := q(ctx, sf)
			if err != nil {
				return err
			}
			for ev := range ch {
				if stopped || sent >= limit {
					continue
				}
				if _, dup := seen[ev.ID]; dup {
					continue
				}
				if !emit(&nostr.Event{ID: ev.ID, CreatedAt: ev.CreatedAt}) {
					stopped = true
					continue
				}
				sent++
			}
			if stopped {
				return ctx.Err()
			}
			if sec == 0 {
				return nil
			}
			next := sec - 1
			until, seen = &next, nil
			continue
		}
		if seen == nil || oldest != boundary {
			seen = make(map[string]struct{}, len(atOldest))
		}
		for _, id := range atOldest {
			seen[id] = struct{}{}
		}
		boundary = oldest
		next := oldest
		until = &next
	}
	return nil
}
