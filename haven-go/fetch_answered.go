package main

import (
	"context"
	"sync"
	"sync/atomic"

	"github.com/nbd-wtf/go-nostr"
)

// fetchAnswered is FetchMany that also reports how many relays ended the
// query with EOSE. FetchMany closes the same way when a relay answered and
// when it could not be reached, so a watermark moved after it may skip a gap
// no relay was ever asked about. fn is called from one goroutine at a time,
// once per event ID.
func fetchAnswered(ctx context.Context, urls []string, filter nostr.Filter, fn func(nostr.RelayEvent)) int {
	var answered atomic.Int32
	var mu sync.Mutex
	seen := make(map[string]struct{})
	var wg sync.WaitGroup
	for _, url := range urls {
		wg.Add(1)
		go func(url string) {
			defer wg.Done()
			relay, err := pool.EnsureRelay(url)
			if err != nil {
				return
			}
			sub, err := relay.Subscribe(ctx, nostr.Filters{filter})
			if err != nil {
				return
			}
			defer sub.Unsub()
			for {
				select {
				case <-ctx.Done():
					return
				case <-sub.EndOfStoredEvents:
					answered.Add(1)
					return
				case <-sub.ClosedReason:
					return
				case ev, ok := <-sub.Events:
					if !ok {
						return
					}
					mu.Lock()
					if _, dup := seen[ev.ID]; !dup {
						seen[ev.ID] = struct{}{}
						fn(nostr.RelayEvent{Event: ev, Relay: relay})
					}
					mu.Unlock()
				}
			}
		}(nostr.NormalizeURL(url))
	}
	wg.Wait()
	return int(answered.Load())
}
