package trustrank

import (
	"context"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// RelayFetcher reads lists from relays one at a time: the first relay that
// has the follow list answers, the next is asked only on a miss.
type RelayFetcher struct {
	Pool    *nostr.SimplePool
	Relays  []string
	Timeout time.Duration // per relay (working: 8 s)
}

// Fetch returns pubkey's newest kind 3 (follows) and kind 10000 (public
// mutes), signature-checked and authored by pubkey. With since, it first asks
// only for lists newer than that, and reads both in full only if one changed.
func (f *RelayFetcher) Fetch(ctx context.Context, pubkey string, since int64) (List, bool, error) {
	if since > 0 {
		b3, b10000, err := f.once(ctx, pubkey, since)
		if err != nil || (b3 == nil && b10000 == nil) {
			return List{}, false, err
		}
	}
	b3, b10000, err := f.once(ctx, pubkey, 0)
	if err != nil || (b3 == nil && b10000 == nil) {
		return List{}, false, err
	}
	var l List
	if b3 != nil {
		l.CreatedAt, l.Follows = int64(b3.CreatedAt), pTags(b3)
	}
	if b10000 != nil {
		l.Mutes = pTags(b10000)
		if t := int64(b10000.CreatedAt); t > l.CreatedAt {
			l.CreatedAt = t
		}
	}
	return l, true, nil
}

func (f *RelayFetcher) once(ctx context.Context, pubkey string, since int64) (best3, best10000 *nostr.Event, err error) {
	filter := nostr.Filter{Authors: []string{pubkey}, Kinds: []int{3, 10000}}
	if since > 0 {
		ts := nostr.Timestamp(since)
		filter.Since = &ts
	}
	for _, url := range f.Relays {
		if ctx.Err() != nil {
			return nil, nil, ctx.Err()
		}
		rctx, cancel := context.WithTimeout(ctx, f.timeout())
		for re := range f.Pool.FetchMany(rctx, []string{url}, filter) {
			ev := re.Event
			if ev == nil || ev.PubKey != pubkey {
				continue
			}
			if ok, err := ev.CheckSignature(); !ok || err != nil {
				continue
			}
			switch {
			case ev.Kind == 3 && (best3 == nil || ev.CreatedAt > best3.CreatedAt):
				best3 = ev
			case ev.Kind == 10000 && (best10000 == nil || ev.CreatedAt > best10000.CreatedAt):
				best10000 = ev
			}
		}
		cancel()
		if best3 != nil || best10000 != nil {
			break // first relay with an answer wins; the next is asked only on a miss
		}
	}
	return best3, best10000, nil
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
