package trustrank

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// RelayFetcher reads many people's lists per REQ from relays one at a time:
// the first relay is asked for everyone in the batch, and each next relay
// only for the people (and kinds) still missing. Each relay's bytes are
// budgeted (relaybudget.go).
type RelayFetcher struct {
	Pool    *nostr.SimplePool
	Relays  []string
	Timeout time.Duration // per relay (working: 8 s)
	// Budget is the bytes one relay may send per minute (0: DefaultBudget).
	Budget int64

	mu      sync.Mutex
	benched map[string]time.Time // relay -> asked again after this
	next    map[string]time.Time // relay -> asked again no sooner (budget)
	sent    map[string]int64     // relay -> bytes received
	perList [2]float64           // bytes per asked person: [full, refresh]
}

// MaxBatch is the most people asked for in one REQ. 100 people x 2 kinds is
// 200 events, under strfry's 500 cap.
const MaxBatch = 100

// muteRelays: a mute list (kind 10000) is asked for on this many answering
// relays at most. Most people have none, so asking every relay for it costs
// a REQ per relay per batch and rarely finds one.
const muteRelays = 2

// benchFor: a relay that did not finish in time is skipped this long. One
// that hangs (nos.lol on 2026-11-22 took 15 s, the pool's dial cap, so most
// likely a connect that never finished) would otherwise cost every batch
// its full wait.
const benchFor = 10 * time.Minute

func (f *RelayFetcher) usable(url string, now time.Time) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return now.After(f.benched[url])
}

// allBenched: no relay may be asked. Then every relay is asked anyway, so a
// network blip that benched them all costs one round of timeouts, not 10 min.
func (f *RelayFetcher) allBenched(now time.Time) bool {
	for _, url := range f.Relays {
		if f.usable(url, now) {
			return false
		}
	}
	return true
}

// ErrNoRelay: no relay connected and answered in time, so "no list" is not
// known. The crawler pauses on it instead of passing the people by.
var ErrNoRelay = errors.New("trustrank: no relay answered")

func (f *RelayFetcher) bench(url string, now time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.benched == nil {
		f.benched = map[string]time.Time{}
	}
	f.benched[url] = now.Add(benchFor)
}

var listKinds = [2]int{3, 10000}

func newer(a, b *nostr.Event) bool { return a != nil && (b == nil || a.CreatedAt > b.CreatedAt) }

// Fetch returns the newest kind 3 (follows) and kind 10000 (public mutes) of
// each asked person, signature-checked and authored by them; a person no
// relay had a list for is left out. An Ask with Since gets only lists at or
// after it (a kind with nothing new keeps its stored copy: Store.PutList
// goes kind by kind). floor (refresh only, else 0) raises every REQ's since
// to at least it; the per-person Since is still applied to each event.
func (f *RelayFetcher) Fetch(ctx context.Context, asks []Ask, floor int64) (map[string]List, error) {
	since := make(map[string]int64, len(asks))
	for _, a := range asks {
		since[a.Pubkey] = a.Since
	}
	best := make(map[string]*[2]*nostr.Event, len(asks))
	ignoreBench := f.allBenched(time.Now())
	answered, muteAsks := false, 0
	var bytes int64 // from the relay asked for everyone, to size the next batch
	sized := false
	for _, url := range f.Relays {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		filters, asksMutes := batchFilters(asks, best, floor, muteAsks < muteRelays)
		if len(filters) == 0 {
			break
		}
		if !ignoreBench && !f.usable(url, time.Now()) {
			continue
		}
		if err := f.waitBudget(ctx, url); err != nil {
			return nil, err
		}
		start := time.Now()
		got, eosed := f.askOne(ctx, url, filters, since, best)
		f.spend(url, start, got)
		if eosed {
			if !answered {
				bytes, sized = got, true
			}
			answered = true
			if asksMutes {
				muteAsks++
			}
		}
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if !answered {
		return nil, ErrNoRelay
	}
	if sized {
		f.learn(floor > 0, bytes, len(asks))
	}
	out := make(map[string]List, len(best))
	for pk, b := range best {
		var l List
		if b[0] != nil {
			l.FollowsAt, l.Follows = int64(b[0].CreatedAt), pTags(b[0])
		}
		if b[1] != nil {
			l.MutesAt, l.Mutes = int64(b[1].CreatedAt), pTags(b[1])
		}
		if b[0] != nil || b[1] != nil {
			out[pk] = l
		}
	}
	return out, nil
}

// batchFilters builds one relay's REQ: the people still missing a kind,
// grouped by which kinds they miss and whether they carry a since. Kind
// 10000 is left out once mutes is false. asksMutes: a filter asks for it.
func batchFilters(asks []Ask, best map[string]*[2]*nostr.Event, floor int64, mutes bool) (out nostr.Filters, asksMutes bool) {
	type key struct {
		need   [2]bool
		sinced bool
	}
	groups := map[key]*nostr.Filter{}
	var order []key
	for _, a := range asks {
		b := best[a.Pubkey]
		need := [2]bool{b == nil || b[0] == nil, mutes && (b == nil || b[1] == nil)}
		if !need[0] && !need[1] {
			continue
		}
		since := a.Since // 0: nothing stored, so a full read even in a refresh
		if since > 0 {
			since = max(since, floor)
		}
		k := key{need, since > 0}
		g := groups[k]
		if g == nil {
			g = &nostr.Filter{}
			for i, kind := range listKinds {
				if need[i] {
					g.Kinds = append(g.Kinds, kind)
				}
			}
			groups[k] = g
			order = append(order, k)
		}
		g.Authors = append(g.Authors, a.Pubkey)
		if k.sinced && (g.Since == nil || nostr.Timestamp(since) < *g.Since) {
			ts := nostr.Timestamp(since)
			g.Since = &ts
		}
		asksMutes = asksMutes || need[1]
	}
	for _, k := range order {
		out = append(out, *groups[k])
	}
	return out, asksMutes
}

// askOne sends filters to url and keeps each asked person's newest list per
// kind in best. bytes is about what the relay sent; eosed is whether it
// answered (only an EOSE is an answer: a CLOSED, rate-limited or
// auth-required, or a dropped socket ends the ask unanswered).
func (f *RelayFetcher) askOne(ctx context.Context, url string, filters nostr.Filters, since map[string]int64, best map[string]*[2]*nostr.Event) (bytes int64, eosed bool) {
	rctx, cancel := context.WithTimeout(ctx, f.timeout())
	defer cancel() // ends the sub; its pending sends give up on its context
	sub, ok := f.ask(rctx, url, filters)
	if !ok {
		// Could not connect or send the REQ in time (or at all): this relay
		// said nothing, which is not the same as "no list".
		if ctx.Err() == nil && rctx.Err() != nil {
			f.bench(url, time.Now())
		}
		return 0, false
	}
	for {
		select {
		case ev, open := <-sub.Events:
			if !open {
				return bytes, false // the sub ended without an EOSE
			}
			if ev == nil {
				continue
			}
			bytes += eventBytes(ev)
			s, asked := since[ev.PubKey]
			if !asked || (s > 0 && int64(ev.CreatedAt) < s) {
				continue
			}
			i := -1
			for j, k := range listKinds {
				if ev.Kind == k {
					i = j
				}
			}
			b := best[ev.PubKey]
			if i < 0 || (b != nil && !newer(ev, b[i])) {
				continue
			}
			if ok, err := ev.CheckSignature(); !ok || err != nil {
				continue
			}
			if b == nil {
				b = &[2]*nostr.Event{}
				best[ev.PubKey] = b
			}
			b[i] = ev
		case <-sub.EndOfStoredEvents:
			// Sent only after every stored event was handed over.
			return bytes, true
		case <-sub.ClosedReason:
			return bytes, false
		case <-rctx.Done():
			// Out of time: skip this relay for a while.
			if ctx.Err() == nil {
				f.bench(url, time.Now())
			}
			return bytes, false
		}
	}
}

// ask connects to url and sends the REQ, giving up when ctx ends. Neither
// the pool's dial (up to 15 s) nor the REQ write (it waits behind pings on a
// dead socket) watches ctx, so both run aside; a sub made after ctx ended
// ends by itself, since it lives on ctx.
func (f *RelayFetcher) ask(ctx context.Context, url string, filters nostr.Filters) (*nostr.Subscription, bool) {
	done := make(chan *nostr.Subscription, 1)
	go func() {
		var sub *nostr.Subscription
		if r, err := f.Pool.EnsureRelay(url); err == nil {
			if s, err := r.Subscribe(ctx, filters); err == nil {
				sub = s
			}
		}
		done <- sub
	}()
	select {
	case sub := <-done:
		return sub, sub != nil
	case <-ctx.Done():
		return nil, false
	}
}

func (f *RelayFetcher) timeout() time.Duration {
	if f.Timeout > 0 {
		return f.Timeout
	}
	return 8 * time.Second
}

func pTags(ev *nostr.Event) []string {
	var out []string
	for _, t := range ev.Tags {
		if len(t) >= 2 && t[0] == "p" && len(t[1]) == 64 {
			out = append(out, t[1])
		}
	}
	return out
}
