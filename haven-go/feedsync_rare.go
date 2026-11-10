package main

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The rare kinds (articles, polls, pictures, highlights, generic reposts)
// keep a watermark per relay. With one watermark for the round, a relay
// that did not answer (down, or a follow's relay that is often dead) let it
// move all the same, so what that relay alone held from the gap was never
// asked for again. Now each relay's mark moves only when that relay read to
// the end, and one that did not is asked from its own mark next round, back
// to the window's edge at most. The rare kinds are a few dozen events a
// round, so asking a dead relay for its whole window each round is cheap.
//
// The common kinds keep their round-wide watermark: there, re-reading a dead
// relay's whole window each round was the #1843 regression.

const (
	feedRareMarkOwn    = "feed_rare@"     // the owner's relays
	feedRareMarkOutbox = "feed_rare_out@" // the follows' own relays, asked for their follows only
	feedRareMarkOld    = "feed_rare"      // the old round-wide mark
	feedRarePullWait   = 90 * time.Second
)

// feedRareRound: one round's rare-kind marks. A nil round asks from the
// start of time and keeps nothing (tests that only read).
type feedRareRound struct {
	state *syncState
	floor nostr.Timestamp // the window's edge
	start nostr.Timestamp // the round's start, where a read relay's mark goes
}

func (r *feedRareRound) key(prefix, url string) string {
	return prefix + nostr.NormalizeURL(url)
}

// since: where relay url's rare read starts, a minute before its mark.
func (r *feedRareRound) since(prefix, url string) nostr.Timestamp {
	if r == nil {
		return 0
	}
	at := nostr.Timestamp(r.state.mark(r.key(prefix, url), int64(r.floor), int64(r.floor))) - 60
	return max(at, r.floor)
}

// read moves relay url's mark when res says it read to the end: it
// answered, did not stop partway and was not cut off.
func (r *feedRareRound) read(prefix, url string, res windowResult) bool {
	for _, list := range [][]string{res.Silent, res.Short, res.Cut} {
		for _, u := range list {
			if u == url {
				return false
			}
		}
	}
	if r != nil {
		r.state.setMark(r.key(prefix, url), int64(r.start))
	}
	return true
}

// tidy drops the old round-wide mark and every relay mark at or below the
// window's edge, which says no more than no mark: the saved state stays the
// size of the relays still in use.
func (r *feedRareRound) tidy() {
	if r == nil || r.state == nil {
		return
	}
	s := r.state
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.data.Marks, feedRareMarkOld)
	for k, v := range s.data.Marks {
		if (strings.HasPrefix(k, feedRareMarkOwn) || strings.HasPrefix(k, feedRareMarkOutbox)) && v <= int64(r.floor) {
			delete(s.data.Marks, k)
		}
	}
}

// pullFeedRare reads the rare kinds of authors from each relay since its own
// mark, all relays at once, for at most feedRarePullWait. publish runs on
// one goroutine at a time. It returns how many events came in.
func pullFeedRare(ctx context.Context, relays []string, authors []string, rare *feedRareRound, publish func(*nostr.Event)) int {
	rctx, cancel := context.WithTimeout(ctx, feedRarePullWait)
	defer cancel()
	var (
		mu  sync.Mutex
		n   int
		wg  sync.WaitGroup
		one = map[string]bool{}
	)
	keep := func(ev *nostr.Event) {
		mu.Lock()
		defer mu.Unlock()
		if one[ev.ID] {
			return
		}
		one[ev.ID] = true
		n++
		publish(ev)
	}
	asked := map[string]bool{}
	for _, url := range relays {
		key := nostr.NormalizeURL(url)
		if asked[key] || relayBanned(url) {
			continue
		}
		asked[key] = true
		wg.Add(1)
		go func(url string) {
			defer wg.Done()
			res := fetchPaged(rctx, []string{url}, feedRareFilter(authors, rare.since(feedRareMarkOwn, url)), importMaxPages, keep)
			rare.read(feedRareMarkOwn, url, res)
		}(url)
	}
	wg.Wait()
	return n
}
