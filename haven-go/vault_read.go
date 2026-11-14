package main

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The Vault tab reads its rows straight from the in-process stores instead
// of over the local relay socket (Logen 2026-11-14): no port, no TLS, no log
// line to wait for, so a return or an account switch reads in tens of ms
// even while iOS has the listening port closed. Live updates stay on the
// socket. The read goes through the same read rules as the socket's /
// (outbox) and /inbox (Tara's guards, nv-parity 2026-11-14):
//   - only outbox and inbox; never private, chat or lists;
//   - blocked people hidden (hideBlacklistedQuery), brought-over accounts
//     hidden (hideBroughtQuery / hideBroughtInboxQuery); no caller identity
//     is taken, so nothing is read as a private reader;
//   - not ready (no live cycle, import cycle, a store closing) answers
//     errVaultReadNotReady, and the app reads over the socket as today.

var errVaultReadNotReady = errors.New("vault read not ready")

const (
	// vaultReadMaxLimit caps each filter: the app asks 400 notes / 200 other.
	vaultReadMaxLimit = 500
	// vaultReadMaxFilters: the app sends 4.
	vaultReadMaxFilters = 8
	vaultReadTimeout    = 5 * time.Second
)

type vaultReadRequest struct {
	Filters []nostr.Filter `json:"filters"`
}

type vaultReadAnswer struct {
	Events []*nostr.Event `json:"events"`
	Error  string         `json:"error,omitempty"`
}

type vaultQuery func(context.Context, nostr.Filter) (chan *nostr.Event, error)

// vaultReadQueries: the outbox and inbox reads with the socket's read rules,
// or not ready.
func vaultReadQueries() (outbox, inbox vaultQuery, closing func() bool, err error) {
	c := relayLC.current.Load()
	if c == nil || c.server == nil { // server == nil: import cycle
		return nil, nil, nil, errVaultReadNotReady
	}
	dbMu.Lock()
	out, in := outboxDB, inboxDB
	dbMu.Unlock()
	if out == nil || in == nil {
		return nil, nil, nil, errVaultReadNotReady
	}
	outbox, inbox, closing = vaultQueriesFor(out, in)
	if closing() {
		return nil, nil, nil, errVaultReadNotReady
	}
	return outbox, inbox, closing, nil
}

// vaultQueriesFor wraps the two stores in the socket's read rules for /
// (wireOutboxReads) and /inbox (init.go): search-aware query, blocked
// hidden, brought-over hidden.
func vaultQueriesFor(out, in DBBackend) (outbox, inbox vaultQuery, closing func() bool) {
	closing = func() bool { return storeClosing(out) || storeClosing(in) }
	outbox = hideBroughtQuery(hideBlacklistedQuery(searchableQuery(out)))
	inbox = hideBroughtInboxQuery(hideBlacklistedQuery(searchableQuery(in)))
	return outbox, inbox, closing
}

func storeClosing(db DBBackend) bool {
	if g, ok := db.(*gatedDB); ok {
		return g.isClosing()
	}
	return false
}

// readVault runs each filter on both stores and returns the events, one per
// id, newest first.
func readVault(ctx context.Context, req vaultReadRequest, outbox, inbox vaultQuery, closing func() bool) ([]*nostr.Event, error) {
	if len(req.Filters) == 0 || len(req.Filters) > vaultReadMaxFilters {
		return nil, errors.New("vault read: 1 to 8 filters")
	}
	seen := map[string]struct{}{}
	var events []*nostr.Event
	for _, f := range req.Filters {
		if f.Search != "" {
			return nil, errors.New("vault read: no search")
		}
		if f.Limit <= 0 || f.Limit > vaultReadMaxLimit {
			f.Limit = vaultReadMaxLimit
		}
		for _, q := range []vaultQuery{outbox, inbox} {
			ch, err := q(ctx, f)
			if err != nil {
				return nil, err
			}
			for ev := range ch {
				if _, dup := seen[ev.ID]; dup {
					continue
				}
				seen[ev.ID] = struct{}{}
				events = append(events, ev)
			}
		}
	}
	// A read cut off by a stop returns part of the rows with no error.
	if ctx.Err() != nil || closing() {
		return nil, errVaultReadNotReady
	}
	sort.SliceStable(events, func(i, j int) bool { return events[i].CreatedAt > events[j].CreatedAt })
	return events, nil
}

// queryVault is QueryVaultC without the C: request JSON in, answer JSON out.
func queryVault(requestJSON string) []byte {
	answer := func(a vaultReadAnswer) []byte {
		b, _ := json.Marshal(a)
		return b
	}
	var req vaultReadRequest
	if err := json.Unmarshal([]byte(requestJSON), &req); err != nil {
		return answer(vaultReadAnswer{Error: "vault read: " + err.Error()})
	}
	outbox, inbox, closing, err := vaultReadQueries()
	if err != nil {
		return answer(vaultReadAnswer{Error: err.Error()})
	}
	c := relayLC.current.Load()
	if c == nil {
		return answer(vaultReadAnswer{Error: errVaultReadNotReady.Error()})
	}
	ctx, cancel := context.WithTimeout(c.ctx, vaultReadTimeout)
	defer cancel()
	events, err := readVault(ctx, req, outbox, inbox, closing)
	if err != nil {
		return answer(vaultReadAnswer{Error: err.Error()})
	}
	if events == nil {
		events = []*nostr.Event{}
	}
	b, err := json.Marshal(vaultReadAnswer{Events: events})
	if err != nil {
		return answer(vaultReadAnswer{Error: err.Error()})
	}
	return b
}
