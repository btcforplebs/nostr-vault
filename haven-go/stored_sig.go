package main

import (
	"context"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// storedEventByID is go-nostr's local-store read for skipping a second
// signature check on an event this device already holds (go-nostr
// sigcache.go storedCopy, which still compares the whole event).
//
// Only stores whose every write verified the signature first are searched:
// the feed cache and the outbox, inbox and chat stores, written by khatru's
// EVENT handler (id and sig checked), by the pool's read loop (sig checked)
// and by the backup import (importable). The blob index (blossomDB) holds
// the relay's own unsigned kind 24242 records and is never searched; nor
// are the files, private or list-history stores, which upstream relays do
// not send back.
func storedEventByID(id string) *nostr.Event {
	if len(id) != 64 {
		return nil
	}
	var ctx context.Context
	filter := nostr.Filter{IDs: []string{id}, Limit: 1}
	for _, db := range []DBBackend{feedDB, inboxDB, outboxDB, chatDB} {
		if db == nil {
			continue
		}
		// Most events are new: the store's id set read at launch answers
		// those in memory, with no read transaction or timer
		// (stored_sig_probe.go). Only a possible copy is read for real.
		if g, ok := db.(*gatedDB); ok && !g.mayHoldID(id) {
			continue
		}
		if ctx == nil {
			var cancel context.CancelFunc
			ctx, cancel = context.WithTimeout(context.Background(), storedLookupTimeout)
			defer cancel()
		}
		ch, err := db.QueryEvents(ctx, filter)
		if err != nil {
			continue
		}
		var found *nostr.Event
		for ev := range ch {
			if found == nil && ev != nil && ev.ID == id {
				found = ev
			}
		}
		if found != nil {
			return found
		}
	}
	return nil
}

// A lookup that slow is no saving over the check it would skip; a miss
// just means the event is verified as before.
const storedLookupTimeout = 250 * time.Millisecond

func init() {
	nostr.SetStoredEventLookup(storedEventByID)
}
