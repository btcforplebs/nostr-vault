package main

import (
	"context"
	"sync"

	"github.com/fiatjaf/khatru"
)

// Open websocket connections across all five relays, for the host app's
// connection count (dashboard, widget). khatru runs OnDisconnect from both of
// a connection's goroutines, so connections are tracked by identity rather
// than counted up and down, which would go negative. Called once per relay
// cycle with that cycle's fresh relays.
var (
	openConnsMu sync.Mutex
	openConns   = map[*khatru.WebSocket]struct{}{}
)

func trackConnections(relays ...*khatru.Relay) {
	openConnsMu.Lock()
	openConns = map[*khatru.WebSocket]struct{}{}
	openConnsMu.Unlock()
	for _, r := range relays {
		r.OnConnect = append(r.OnConnect, func(ctx context.Context) {
			if ws := khatru.GetConnection(ctx); ws != nil {
				openConnsMu.Lock()
				openConns[ws] = struct{}{}
				openConnsMu.Unlock()
			}
		})
		r.OnDisconnect = append(r.OnDisconnect, func(ctx context.Context) {
			if ws := khatru.GetConnection(ctx); ws != nil {
				openConnsMu.Lock()
				delete(openConns, ws)
				openConnsMu.Unlock()
			}
		})
	}
}

func activeConnectionCount() int {
	openConnsMu.Lock()
	defer openConnsMu.Unlock()
	return len(openConns)
}
