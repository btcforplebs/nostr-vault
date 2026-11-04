package main

import (
	"context"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Moving in reads each 10-day window page by page (Logen 2026-11-04, from the
// NDK check RESEARCH/NV_NDK_IDEAS_CHECK.md). It used to send one REQ per window
// with one overall deadline: a relay's answer cap (often 500) cut a busy
// window short without a word, and a window that ran past the deadline was
// dropped whole. Now every relay is asked again with `until` at the oldest
// note it sent, until a page brings nothing new; and a request only gives up
// when the relay goes quiet for importIdleTimeout, not after a fixed time.
// The web app's importOwn (web-vault/src/net/sync.js) pages the same way.

const (
	// importPageLimit: asked for per page. A relay that caps lower just sends
	// fewer; the paging goes on from its oldest either way.
	importPageLimit = 500
	// importIdleTimeoutDefault: a request that hears nothing (no note, no
	// EOSE) for this long ends with what it got. Each note restarts it.
	importIdleTimeoutDefault = 20 * time.Second
	// importMaxPages: per relay per window, a backstop against a relay that
	// keeps sending "new" notes forever. 200 × 500 is far past any real window.
	importMaxPages = 200
)

// importIdleTimeout: importIdleTimeoutDefault; shorter in tests.
var importIdleTimeout = importIdleTimeoutDefault

// importPage asks one relay one filter: what it sent, and whether it ended the
// answer with EOSE (false: it went quiet, closed or failed). Replaced in tests.
var importPage = askRelayIdle

// askRelayIdle collects a REQ's answer until EOSE, CLOSED, the context ends,
// or nothing arrives for importIdleTimeout.
func askRelayIdle(ctx context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
	relay, err := pool.EnsureRelay(url)
	if err != nil {
		return nil, false
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	sub, err := relay.Subscribe(ctx, nostr.Filters{f})
	if err != nil {
		return nil, false
	}
	defer sub.Unsub()
	idle := time.NewTimer(importIdleTimeout)
	defer idle.Stop()
	var out []*nostr.Event
	for {
		select {
		case ev, ok := <-sub.Events:
			if !ok {
				return out, false
			}
			out = append(out, ev)
			if !idle.Stop() {
				<-idle.C
			}
			idle.Reset(importIdleTimeout)
		case <-sub.EndOfStoredEvents:
			return out, true
		case <-sub.ClosedReason:
			return out, false
		case <-idle.C:
			return out, false
		case <-ctx.Done():
			return out, false
		}
	}
}

// windowResult: what reading one window did. Short lists the relays that
// stopped with notes still coming (went quiet mid-page, or hit importMaxPages):
// the window may be missing some of theirs.
type windowResult struct {
	Notes int
	Short []string
}

// fetchWindowPaged reads filter (Since..Until) from every relay, each one paged
// back from Until until a page brings no note not seen before. Each note is
// handed to keep once, whichever relay sent it first; keep runs on one
// goroutine at a time. A note the filter doesn't match is dropped (a relay
// may send anything).
func fetchWindowPaged(ctx context.Context, relays []string, filter nostr.Filter, keep func(*nostr.Event)) windowResult {
	var (
		mu   sync.Mutex
		seen = map[string]bool{}
		res  windowResult
		wg   sync.WaitGroup
	)
	for _, url := range relays {
		wg.Add(1)
		go func(url string) {
			defer wg.Done()
			f := filter
			f.Limit = importPageLimit
			// stepped: the last page brought nothing new and the next one asks
			// from a second earlier, past notes it can't page through (more in
			// one second than a page holds, or a relay that keeps sending the
			// same half page). One such step per stall.
			stepped := false
			for page := 0; ; page++ {
				if ctx.Err() != nil {
					return
				}
				if page == importMaxPages {
					mu.Lock()
					res.Short = append(res.Short, url)
					mu.Unlock()
					return
				}
				evs, eose := importPage(ctx, url, f)
				fresh, matched := 0, 0
				var oldest nostr.Timestamp
				mu.Lock()
				for _, ev := range evs {
					if ev == nil || !filter.Matches(ev) {
						continue
					}
					matched++
					if oldest == 0 || ev.CreatedAt < oldest {
						oldest = ev.CreatedAt
					}
					if seen[ev.ID] {
						continue
					}
					seen[ev.ID] = true
					fresh++
					keep(ev)
					res.Notes++
				}
				if matched == 0 && !eose && page > 0 {
					// Answered before, now nothing and no EOSE: it may still hold more.
					res.Short = append(res.Short, url)
				}
				mu.Unlock()
				if matched == 0 {
					return // an empty page: this relay has nothing older in the window
				}
				until := oldest // inclusive: notes sharing that second come back and are skipped as seen
				if fresh == 0 {
					if stepped {
						return
					}
					stepped = true
					until = oldest - 1
				} else {
					stepped = false
				}
				if f.Since != nil && until < *f.Since {
					return
				}
				f.Until = &until
			}
		}(url)
	}
	wg.Wait()
	return res
}
