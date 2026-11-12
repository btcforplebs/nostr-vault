//go:build !wasm

package main

import (
	"context"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/internal/negsync"
)

// vectorScanPage is how many decoded events one page of a vector scan holds.
// Badger decodes a whole query's result before sending any of it, so this,
// not MaxLimitNegentropy (100k on the Mac), bounds what a vector build keeps
// alive. Larger pages mean fewer index walks: a feed filter is one iterator
// per author and kind, rebuilt per page.
var vectorScanPage = 10_000

// QueryEvents answers a query marked negsync.ForVector (a negentropy vector
// build, ours or a device's NEG-OPEN) page by page with id+created_at stubs,
// behind the process-wide scan gate. Every other query is Badger's own.
func (s *badgerStore) QueryEvents(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
	if !negsync.IsForVector(ctx) {
		return s.BadgerBackend.QueryEvents(ctx, f)
	}
	ctx = eventstore.SetNegentropy(ctx)
	if f.Search != "" || f.LimitZero {
		// Badger answers these with nothing; keep that, and its shape.
		return s.BadgerBackend.QueryEvents(ctx, f)
	}
	limit := vectorLimit(f, s.MaxLimitNegentropy)

	out := make(chan *nostr.Event)
	go func() {
		defer close(out)
		if limit == 0 {
			return
		}
		release, err := negsync.AcquireScan(ctx)
		defer release()
		if err != nil {
			return
		}
		emit := func(ev *nostr.Event) bool {
			select {
			case out <- ev:
				return true
			case <-ctx.Done():
				return false
			}
		}
		_ = negsync.ScanIDs(ctx, s.BadgerBackend.QueryEvents, f, limit, vectorScanPage, emit)
	}()
	return out, nil
}

// vectorLimit is how many events Badger would have returned for f in a
// negentropy session (eventstore badger QueryEvents): MaxLimitNegentropy,
// lowered by a smaller Limit, replaced by a filter's theoretical limit.
func vectorLimit(f nostr.Filter, maxNeg int) int {
	limit := maxNeg
	if f.Limit > 0 && f.Limit <= maxNeg {
		limit = f.Limit
	}
	if tl := nostr.GetTheoreticalLimit(f); tl >= 0 {
		limit = tl
	}
	return limit
}
