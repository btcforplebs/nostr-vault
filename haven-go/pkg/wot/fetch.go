package wot

import (
	"context"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/runsafe"
)

// listQuorum and listGrace end a list fetch early: once listQuorum seed
// relays have sent EOSE, the rest get listGrace more and the fetch ends.
// Waiting for every relay made each batch as slow as the slowest one: on
// 2026-11-08 one relay took 7.6 s where the other six took under 1 s, and
// dropping it left the same 5,059-person graph (NV_HEALTH_G_WOT.md), because
// every seed serves the same lists.
const (
	listQuorum = 3
	listGrace  = 1500 * time.Millisecond
)

// maxParallelBatches is how many list batches are in flight at once. Batches
// went one after another, so a build took (follows / 250) times the slowest
// relay; four at a time covers 1,000 follows in one round.
const maxParallelBatches = 4

// listFetch is one batch's answer: the newest list per author, how many
// events arrived (duplicates across relays included, for the progress
// count), and whether enough relays finished for the answer to be complete.
type listFetch struct {
	lists    map[string]*nostr.Event
	received int64
	// complete is true when listQuorum relays (or every relay, if fewer were
	// asked) sent EOSE before ctx ended. A since-fetch that isn't complete
	// may have missed a change, so the stored lists keep their old stamp.
	complete bool
}

// fetchLatestLists asks every relay for filter at once and returns the newest
// event per author. It ends when listQuorum relays have sent EOSE plus
// listGrace, when every relay is done (EOSE, CLOSED or unreachable), or when
// ctx ends; what arrived before then is kept either way.
func fetchLatestLists(ctx context.Context, pool *nostr.SimplePool, relays []string, filter nostr.Filter) listFetch {
	out := listFetch{lists: make(map[string]*nostr.Event)}
	relays = uniqueRelays(relays)
	if len(relays) == 0 {
		return out
	}
	quorum := min(listQuorum, len(relays))

	fctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var mu sync.Mutex
	eosed, finished := 0, 0
	allDone := make(chan struct{})
	quorumReached := make(chan struct{})
	finish := func(eose bool) {
		mu.Lock()
		defer mu.Unlock()
		finished++
		if eose {
			eosed++
			if eosed == quorum {
				close(quorumReached)
			}
		}
		if finished == len(relays) {
			close(allDone)
		}
	}
	keep := func(ev *nostr.Event) {
		mu.Lock()
		defer mu.Unlock()
		out.received++
		if old, ok := out.lists[ev.PubKey]; !ok || ev.CreatedAt > old.CreatedAt {
			out.lists[ev.PubKey] = ev
		}
	}

	var wg sync.WaitGroup
	for _, url := range relays {
		wg.Add(1)
		go func() {
			defer wg.Done()
			eose := false
			defer func() { finish(eose) }()
			runsafe.Run("wot.fetchLatestLists", func() {
				relay, err := pool.EnsureRelay(url)
				if err != nil {
					return
				}
				sub, err := relay.Subscribe(fctx, nostr.Filters{filter})
				if err != nil {
					return
				}
				defer sub.Unsub()
				for {
					select {
					case <-fctx.Done():
						return
					case <-sub.Context.Done():
						return
					case <-sub.ClosedReason:
						return
					case <-sub.EndOfStoredEvents:
						eose = true
						return
					case ev, ok := <-sub.Events:
						if !ok {
							return
						}
						// The filter is the relay's promise, not ours to trust.
						if ev != nil && filter.Matches(ev) {
							keep(ev)
						}
					}
				}
			})
		}()
	}

	select {
	case <-allDone:
	case <-ctx.Done():
	case <-quorumReached:
		select {
		case <-allDone:
		case <-ctx.Done():
		case <-time.After(listGrace):
		}
	}
	cancel()
	wg.Wait()

	mu.Lock()
	out.complete = eosed >= quorum
	mu.Unlock()
	return out
}

func uniqueRelays(relays []string) []string {
	seen := make(map[string]bool, len(relays))
	out := make([]string, 0, len(relays))
	for _, r := range relays {
		n := nostr.NormalizeURL(r)
		if n == "" || seen[n] {
			continue
		}
		seen[n] = true
		out = append(out, r)
	}
	return out
}
