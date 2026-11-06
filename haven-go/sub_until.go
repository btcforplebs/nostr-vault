package main

import (
	"context"

	"github.com/nbd-wtf/go-nostr"
)

// eventsUntilDone hands each event on ch to fn until ch closes or ctx ends,
// whichever comes first.
//
// A pool subscription's channel only closes once every relay goroutine under
// it has let go, and one stuck dialling, or writing to a socket the OS froze
// while the app was away, holds it open for minutes after the cycle is
// cancelled. Ranging over it kept the cycle's own goroutine alive with it
// (12 mini 2026-11-05: subscribeInboxAndChat outlived its stop, so every
// Import notes was refused as still_draining and the vault was left paused).
// The pool's goroutines drop their sends once ctx ends, so nothing leaks.
func eventsUntilDone(ctx context.Context, ch <-chan nostr.RelayEvent, fn func(nostr.RelayEvent)) {
	for {
		select {
		case <-ctx.Done():
			return
		case ev, ok := <-ch:
			if !ok {
				return
			}
			if ctx.Err() != nil {
				return
			}
			fn(ev)
		}
	}
}
