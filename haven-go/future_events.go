package main

import (
	"errors"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// maxFutureSkew is how far ahead of this device's clock an event may be
// dated. A note or reaction dated later (a sender with a wrong clock) would
// sit at the top of every newest-first list, and an app that asks for
// "newer than the newest I hold" would ask for the future and hear nothing
// more: the Vault froze that way (Logen 11-02).
const maxFutureSkew = 10 * time.Minute

// errFutureEvent is what a store returns for an event dated too far ahead.
var errFutureEvent = errors.New("blocked: created_at is more than 10 minutes in the future")

// isFutureEvent reports whether evt is dated more than maxFutureSkew ahead of now.
func isFutureEvent(evt *nostr.Event, now nostr.Timestamp) bool {
	return evt.CreatedAt > now+nostr.Timestamp(maxFutureSkew/time.Second)
}
