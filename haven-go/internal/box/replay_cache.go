package box

import (
	"sync"
	"time"
)

// replayCache remembers accepted NIP-98 event ids so a captured header works
// once. Ids are kept in the order they were seen, which is also the order
// they expire in, so pruning only looks at the expired head: no full scan
// per call (Tron #2375 measured 578 µs a call at 100k entries).
type replayCache struct {
	mu    sync.Mutex
	seen  map[string]time.Time
	order []seenID // order[head:] are live, oldest first
	head  int
	limit int // 0: no limit
}

type seenID struct {
	id string
	at time.Time
}

func newReplayCache(limit int) *replayCache {
	return &replayCache{seen: map[string]time.Time{}, limit: limit}
}

// replayResult of use. replayFull: the cache is at its limit, so the id is
// refused. It is never let through unrecorded and never recorded by evicting
// a live entry, so a replay can't slip in while the cache is full.
type replayResult int

const (
	replayFirst replayResult = iota
	replayUsed
	replayFull
)

// use records id at now. Entries older than twice the auth window are
// dropped first: an event that old fails the time check anyway.
func (c *replayCache) use(id string, now time.Time) replayResult {
	c.mu.Lock()
	defer c.mu.Unlock()
	for c.head < len(c.order) && now.Sub(c.order[c.head].at) > 2*authWindow {
		delete(c.seen, c.order[c.head].id)
		c.order[c.head] = seenID{}
		c.head++
	}
	// Compact once the dead head is most of the slice: amortised O(1).
	if c.head > 64 && c.head*2 > len(c.order) {
		c.order = append([]seenID(nil), c.order[c.head:]...)
		c.head = 0
	}
	if _, dup := c.seen[id]; dup {
		return replayUsed
	}
	if c.limit > 0 && len(c.seen) >= c.limit {
		return replayFull
	}
	c.seen[id] = now
	c.order = append(c.order, seenID{id, now})
	return replayFirst
}

func (c *replayCache) has(id string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	_, ok := c.seen[id]
	return ok
}

func (c *replayCache) len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.seen)
}
