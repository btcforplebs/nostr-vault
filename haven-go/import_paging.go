package main

import (
	"context"
	"slices"
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

// importPageMax: the most one page may take, however it trickles (Tron, PR
// 1654: a relay replaying one note every 100 ms held a window open for good).
var importPageMax = 2 * time.Minute

// importPage asks one relay one filter: what it sent, and whether it ended the
// answer with EOSE (false: it went quiet, closed or failed). Replaced in tests.
var importPage = askRelayIdle

// askRelayIdle collects a REQ's answer until EOSE, CLOSED, the context ends,
// the page is full (f.Limit notes it asked for), importPageMax passes, or no
// new note it asked for arrives for importIdleTimeout. Repeats and notes
// outside the filter neither count nor keep the page open.
func askRelayIdle(ctx context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
	relay, err := pool.EnsureRelay(url)
	if err != nil {
		return nil, false
	}
	wait := pageIdle(ctx)
	ctx, cancel := context.WithTimeout(ctx, importPageMax)
	defer cancel()
	sub, err := relay.Subscribe(ctx, nostr.Filters{f})
	if err != nil {
		return nil, false
	}
	defer sub.Unsub()
	idle := time.NewTimer(wait)
	defer idle.Stop()
	var out []*nostr.Event
	got := map[string]bool{}
	for {
		select {
		case ev, ok := <-sub.Events:
			if !ok {
				return out, false
			}
			if ev == nil || got[ev.ID] || !f.Matches(ev) {
				continue
			}
			got[ev.ID] = true
			out = append(out, ev)
			if f.Limit > 0 && len(out) >= f.Limit {
				return out, true // a full page: the next one asks from its oldest
			}
			if !idle.Stop() {
				<-idle.C
			}
			idle.Reset(wait)
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

// pageIdleKey carries per-relay idle waits into fetchPaged (withPageIdle).
type pageIdleKey struct{}

// pageIdleOneKey carries one relay's idle wait into importPage.
type pageIdleOneKey struct{}

// withPageIdle: fetchPaged asks the relays in idle with their own idle wait
// instead of importIdleTimeout. The window walk uses it for a relay that has
// sent notes but never ends an answer with EOSE: each of its pages ends by
// going quiet, and the full wait on every one would spend the walk's time.
func withPageIdle(ctx context.Context, idle map[string]time.Duration) context.Context {
	if len(idle) == 0 {
		return ctx
	}
	return context.WithValue(ctx, pageIdleKey{}, idle)
}

// pageIdle: how long importPage waits for a quiet relay on ctx.
func pageIdle(ctx context.Context) time.Duration {
	if d, ok := ctx.Value(pageIdleOneKey{}).(time.Duration); ok && d > 0 {
		return d
	}
	return importIdleTimeout
}

// windowResult: what reading one window did. Short lists the relays that
// stopped with notes still coming (went quiet mid-page, or hit importMaxPages):
// the window may be missing some of theirs.
type windowResult struct {
	Notes int
	Short []string
	// Silent: relays whose first page brought nothing and no EOSE (went quiet,
	// closed or failed before answering). A whole-history lane re-reads them
	// window by window: some relays time out on a wide scan but answer 10 days.
	Silent []string
	// Empty: relays whose first page ended with EOSE and no note. On a
	// whole-history lane that is unconfirmed, not "nothing": some relays
	// answer a wide scan empty but hand over 10 days (12 mini, 2026-11-05),
	// so the lane walks them window by window (import_owner.go).
	Empty []string
	// Quiet: relays that ended some page of this window by going quiet (no
	// EOSE) instead of answering it, whether or not they sent notes first.
	// Each such page cost the whole idle wait; the window walk counts them
	// with Silent (import_owner.go importOwnerWindows).
	Quiet []string
	// Sent: per relay, the notes it sent that passed the check (new to this
	// read or not). A relay that went quiet but sent notes is alive.
	Sent map[string]int
	// Oldest: per relay, the oldest created_at among them. A whole-history
	// lane pages newest first, so this is how far down it got.
	Oldest map[string]nostr.Timestamp
}

// fetchWindowPaged reads filter (Since..Until) from every relay, each one paged
// back from Until until a page brings nothing it hadn't sent before. Each note is
// handed to keep once, whichever relay sent it first; keep runs on one
// goroutine at a time. A note the filter doesn't match is dropped (a relay
// may send anything).
func fetchWindowPaged(ctx context.Context, relays []string, filter nostr.Filter, keep func(*nostr.Event)) windowResult {
	return fetchPaged(ctx, relays, filter, importMaxPages, keep)
}

// fetchPaged is fetchWindowPaged with its own page backstop: Moving in's
// whole-history lanes (import_owner.go) need more than one window's 200.
func fetchPaged(ctx context.Context, relays []string, filter nostr.Filter, maxPages int, keep func(*nostr.Event)) windowResult {
	var (
		mu   sync.Mutex
		seen = map[string]bool{}
		res  = windowResult{Sent: map[string]int{}, Oldest: map[string]nostr.Timestamp{}}
		wg   sync.WaitGroup
	)
	idles, _ := ctx.Value(pageIdleKey{}).(map[string]time.Duration)
	for _, url := range relays {
		wg.Add(1)
		go func(url string) {
			defer wg.Done()
			ctx := ctx
			if d, ok := idles[url]; ok {
				ctx = context.WithValue(ctx, pageIdleOneKey{}, d)
			}
			f := filter
			f.Limit = importPageLimit
			// mine: what this relay has sent, which decides its paging. A note
			// another relay sent first still counts as new here, or a relay
			// whose recent notes a faster one already sent would stop before
			// its older ones (Tron, PR 1654). `seen` only decides hand-over.
			mine := map[string]bool{}
			// stepped: the last page brought nothing new and the next one asks
			// from a second earlier, past notes it can't page through (more in
			// one second than a page holds, or a relay that keeps sending the
			// same half page). One such step per stall.
			stepped := false
			for page := 0; ; page++ {
				if ctx.Err() != nil {
					return
				}
				if page == maxPages {
					mu.Lock()
					res.Short = append(res.Short, url)
					mu.Unlock()
					return
				}
				evs, eose := importPage(ctx, url, f)
				if !eose && ctx.Err() == nil {
					mu.Lock()
					if !slices.Contains(res.Quiet, url) {
						res.Quiet = append(res.Quiet, url)
					}
					mu.Unlock()
				}
				// Only a real note counts (Tron, PR 1663): its id is the hash
				// of its content and its signature holds. Checked before it
				// can count as new, or a relay sending made-up notes under
				// the owner's key keeps a lane paging (and its maps growing)
				// to the backstop. Outside the lock: it's the costly part.
				evs = slices.DeleteFunc(slices.Clone(evs), func(ev *nostr.Event) bool {
					if ev == nil || !filter.Matches(ev) || !ev.CheckID() {
						return true
					}
					ok, _ := ev.CheckSignature()
					return !ok
				})
				fresh, matched := 0, 0
				var oldest nostr.Timestamp
				mu.Lock()
				for _, ev := range evs {
					matched++
					res.Sent[url]++
					if oldest == 0 || ev.CreatedAt < oldest {
						oldest = ev.CreatedAt
					}
					if o, ok := res.Oldest[url]; !ok || ev.CreatedAt < o {
						res.Oldest[url] = ev.CreatedAt
					}
					if mine[ev.ID] {
						continue
					}
					mine[ev.ID] = true
					fresh++
					if seen[ev.ID] {
						continue
					}
					seen[ev.ID] = true
					keep(ev)
					res.Notes++
				}
				if matched == 0 && eose && page == 0 {
					res.Empty = append(res.Empty, url)
				}
				if matched == 0 && !eose {
					if page > 0 {
						// Answered before, now nothing and no EOSE: it may still hold more.
						res.Short = append(res.Short, url)
					} else {
						res.Silent = append(res.Silent, url)
					}
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
