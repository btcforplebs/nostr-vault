package main

import (
	"context"
	"encoding/json"
	"log/slog"

	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/policies"
	"github.com/nbd-wtf/go-nostr"
)

// The mesh door's outbox reads (sync rework M1,
// RESEARCH/NV_SYNC_REWORK_BUILD_PLAN_2026_11_12.md §1): a stranger on the
// mesh may REQ the outbox the way anyone may over https, with the same
// filter rules and the same accounts hidden. On top, only over the mesh:
const (
	// meshMaxLimit: events one filter may return. A filter with no limit,
	// or a larger one, gets this (the store's own cap is 250, for https too).
	meshMaxLimit = 200
	// meshMaxAnswerBytes: what one filter's answer may weigh (the events'
	// JSON). The answer stops there; the client gets EOSE and can page with
	// until/since.
	meshMaxAnswerBytes = 1 << 20
	// meshMaxSubscriptions: open subscription filters (khatru listeners, one
	// per filter, "limit":0 and a REQ on an id already open included) on one
	// mesh connection. Mesh peers carry no identity of their own (they arrive
	// from loopback, meshPeerKey), so this is per connection; the strangers'
	// lane caps the connections (16 slots, 1 MiB/s for all,
	// fips-v2-android strangers.rs).
	meshMaxSubscriptions = 16
	// meshMaxFilters: filters in one REQ, so one REQ's answer is at most
	// meshMaxFilters × meshMaxAnswerBytes.
	meshMaxFilters = 8
)

// wireOutboxReads adds the outbox's read rules to rl: empty and complex
// filters refused unless the limits allow them, queries and counts with
// NIP-50 search (search.go), brought-over accounts hidden from everyone but
// the vault's own (brought_reads.go). Over the mesh: the caps above. COUNT
// stays closed over the mesh.
func wireOutboxReads(rl *khatru.Relay, db DBBackend, limits OutboxRelayLimits) {
	if !limits.AllowEmptyFilters {
		rl.RejectFilter = append(rl.RejectFilter, policies.NoEmptyFilters)
	}
	if !limits.AllowComplexFilters {
		rl.RejectFilter = append(rl.RejectFilter, policies.NoComplexFilters)
	}
	enableSearch(rl, db)
	hideBroughtOnOutbox(rl)
	wireMeshReadCaps(rl)
}

// wireMeshReadCaps adds the mesh-only read rules to rl (the outbox and,
// sync rework M2, /inbox). Call it after every query is
// wired: the byte cap wraps rl.QueryEvents as they are.
//   - no negentropy over the mesh;
//   - limit clamped to meshMaxLimit;
//   - per REQ (khatru fork ReqCaps): meshMaxFilters filters, at most
//     meshMaxSubscriptions open listeners on the connection;
//   - one filter's answer at most meshMaxAnswerBytes;
//   - COUNT closed.
func wireMeshReadCaps(rl *khatru.Relay) {
	// First: a NEG-OPEN runs these hooks with no subscription in its context.
	rl.RejectFilter = append([]func(context.Context, nostr.Filter) (bool, string){meshNoNegentropy}, rl.RejectFilter...)
	rl.OverwriteFilter = append(rl.OverwriteFilter, meshCapLimit)
	// One check per REQ, in the khatru fork (ReqCaps): filters per REQ and
	// open listeners per connection, reserved under its lock.
	rl.ReqCaps = meshReqCaps
	rl.RejectCountFilter = append(rl.RejectCountFilter, meshNoQueries)
	// Last, so it weighs what is really sent (after the hidden accounts).
	for i, q := range rl.QueryEvents {
		rl.QueryEvents[i] = meshCapAnswerBytes(q)
	}
}

// meshCapLimit clamps a mesh filter's limit to meshMaxLimit.
func meshCapLimit(ctx context.Context, f *nostr.Filter) {
	if !isMeshConn(ctx) || f.LimitZero {
		return
	}
	if f.Limit <= 0 || f.Limit > meshMaxLimit {
		f.Limit = meshMaxLimit
	}
}

// meshNoNegentropy: no negentropy over the mesh (NEG-OPEN): the door
// answers REQs, which the caps bound; a negentropy session reads the whole
// filter into a vector.
func meshNoNegentropy(ctx context.Context, _ nostr.Filter) (bool, string) {
	if isMeshConn(ctx) && eventstore.IsNegentropySession(ctx) {
		return true, "restricted: no negentropy over the mesh"
	}
	return false, ""
}

// meshReqCaps: the per-REQ caps for a mesh connection, none for any other.
func meshReqCaps(ctx context.Context) (maxFilters, maxListeners int) {
	if !isMeshConn(ctx) {
		return 0, 0
	}
	return meshMaxFilters, meshMaxSubscriptions
}

// meshCapAnswerBytes stops a mesh filter's answer once it weighs
// meshMaxAnswerBytes. Everything else passes as it is.
func meshCapAnswerBytes(query func(context.Context, nostr.Filter) (chan *nostr.Event, error)) func(context.Context, nostr.Filter) (chan *nostr.Event, error) {
	return func(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		ch, err := query(ctx, f)
		if err != nil || ch == nil || !isMeshConn(ctx) {
			return ch, err
		}
		out := make(chan *nostr.Event)
		go func() {
			defer close(out)
			sent := 0
			stopped := false
			for ev := range ch { // drained to the end, so the store's query can finish
				if stopped {
					continue
				}
				b, _ := json.Marshal(ev)
				// The first event always goes (the relay's message limit
				// bounds it), so one big note can't make every page empty.
				if sent > 0 && sent+len(b) > meshMaxAnswerBytes {
					stopped = true
					slog.Debug("mesh answer capped", "bytes", sent)
					continue
				}
				sent += len(b)
				select {
				case out <- ev:
				case <-ctx.Done():
					stopped = true
				}
			}
		}()
		return out, nil
	}
}
