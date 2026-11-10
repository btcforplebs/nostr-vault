package wot

import (
	"context"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/runsafe"
)

// listQuorum and listGrace end a list fetch early: once listQuorum seed
// relays have sent EOSE, the rest get listGrace more, or as long again as the
// quorum took if that is longer (a slow link slows every relay, and a fixed
// grace there cut off relays still sending), and the fetch ends.
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
	// asked) sent EOSE before ctx ended.
	complete bool
	// cut lists the relays still connecting or sending when the fetch ended:
	// a list only they hold is missing from lists. A fetch with any cut
	// relay is not the whole answer, even when complete.
	cut []string
}

// whole is true when the quorum answered and no relay was cut: the answer
// holds everything the relays asked will give. Only a whole since-fetch may
// move the stored lists' since stamp; a quorum alone may have cut the one
// relay holding a change, and the next pass would never ask for it again.
func (f listFetch) whole() bool { return f.complete && len(f.cut) == 0 }

// fetchLatestLists asks every relay for filter at once and returns the newest
// event per author. It ends when listQuorum relays have sent EOSE plus
// listGrace, when every relay is done (EOSE, CLOSED or unreachable), or when
// ctx ends; what arrived before then is kept either way.
func fetchLatestLists(ctx context.Context, pool *nostr.SimplePool, relays []string, filter nostr.Filter) listFetch {
	return fetchLists(ctx, pool, relays, filter, false)
}

// fetchListsFromEvery is fetchLatestLists without the quorum cut: it waits
// for every relay (EOSE, CLOSED or unreachable) or ctx. The owners' own lists
// are fetched this way, since every other list hangs off them, and so are the
// follow-up asks of relays a quorum cut.
func fetchListsFromEvery(ctx context.Context, pool *nostr.SimplePool, relays []string, filter nostr.Filter) listFetch {
	return fetchLists(ctx, pool, relays, filter, true)
}

// fetchLists is both: waitAll turns the quorum cut off.
func fetchLists(ctx context.Context, pool *nostr.SimplePool, relays []string, filter nostr.Filter, waitAll bool) listFetch {
	out := listFetch{lists: make(map[string]*nostr.Event)}
	relays = uniqueRelays(relays)
	if len(relays) == 0 {
		return out
	}
	quorum := min(listQuorum, len(relays))

	start := time.Now()
	fctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var mu sync.Mutex
	eosed, finished := 0, 0
	done := make([]bool, len(relays))
	// ended is set when the fetch returns; a relay still connecting (that
	// can take EnsureRelay's own 15 s) or sending must not touch out after.
	ended := false
	allDone := make(chan struct{})
	quorumReached := make(chan struct{})
	finish := func(i int, eose bool) {
		mu.Lock()
		defer mu.Unlock()
		if ended {
			return // already counted as cut
		}
		done[i] = true
		finished++
		if eose {
			eosed++
			if eosed == quorum && !waitAll {
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
		if ended {
			return
		}
		out.received++
		if old, ok := out.lists[ev.PubKey]; !ok || ev.CreatedAt > old.CreatedAt {
			out.lists[ev.PubKey] = ev
		}
	}

	for i, url := range relays {
		go func() {
			eose := false
			defer func() { finish(i, eose) }()
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
		case <-time.After(max(listGrace, time.Since(start))):
		}
	}
	// Not waiting for the relay goroutines: one stuck connecting would hold
	// the fetch for up to 15 s. They end on their own once fctx is done.
	cancel()
	mu.Lock()
	defer mu.Unlock()
	ended = true
	out.complete = eosed >= quorum
	for i, url := range relays {
		if !done[i] {
			out.cut = append(out.cut, url)
		}
	}
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
