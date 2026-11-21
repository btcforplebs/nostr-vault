package trustrank

import (
	"context"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// RelayFetcher reads lists from relays one at a time: the next relay is asked
// only for a kind (follows or mutes) that no relay so far had.
type RelayFetcher struct {
	Pool    *nostr.SimplePool
	Relays  []string
	Timeout time.Duration // per relay (working: 8 s)
}

// Fetch returns pubkey's newest kind 3 (follows) and kind 10000 (public
// mutes), signature-checked and authored by pubkey. With since, it first asks
// only for lists newer than that; if one changed it reads both in full, and
// keeps the newer of each kind from the two reads, so a stale relay that
// answers the full read first cannot hide the change.
func (f *RelayFetcher) Fetch(ctx context.Context, pubkey string, since int64) (List, bool, error) {
	var fresh [2]*nostr.Event
	if since > 0 {
		var err error
		fresh, err = f.once(ctx, pubkey, since)
		if err != nil || (fresh[0] == nil && fresh[1] == nil) {
			return List{}, false, err
		}
	}
	got, err := f.once(ctx, pubkey, 0)
	if err != nil {
		return List{}, false, err
	}
	for i := range got {
		if newer(fresh[i], got[i]) {
			got[i] = fresh[i]
		}
	}
	b3, b10000 := got[0], got[1]
	if b3 == nil && b10000 == nil {
		return List{}, false, nil
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

var listKinds = [2]int{3, 10000}

func newer(a, b *nostr.Event) bool { return a != nil && (b == nil || a.CreatedAt > b.CreatedAt) }

// once asks one relay at a time, and the next only for the kinds still
// missing. best[0] is kind 3, best[1] kind 10000.
func (f *RelayFetcher) once(ctx context.Context, pubkey string, since int64) (best [2]*nostr.Event, err error) {
	for _, url := range f.Relays {
		if ctx.Err() != nil {
			return best, ctx.Err()
		}
		var kinds []int
		for i, k := range listKinds {
			if best[i] == nil {
				kinds = append(kinds, k)
			}
		}
		if len(kinds) == 0 {
			break
		}
		filter := nostr.Filter{Authors: []string{pubkey}, Kinds: kinds}
		if since > 0 {
			ts := nostr.Timestamp(since)
			filter.Since = &ts
		}
		rctx, cancel := context.WithTimeout(ctx, f.timeout())
		for re := range f.Pool.FetchMany(rctx, []string{url}, filter) {
			ev := re.Event
			if ev == nil || ev.PubKey != pubkey {
				continue
			}
			i := -1
			for j, k := range listKinds {
				if ev.Kind == k && best[j] == nil || ev.Kind == k && ev.CreatedAt > best[j].CreatedAt {
					i = j
				}
			}
			if i < 0 || (since > 0 && int64(ev.CreatedAt) < since) {
				continue
			}
			if ok, err := ev.CheckSignature(); !ok || err != nil {
				continue
			}
			best[i] = ev
		}
		cancel()
	}
	return best, nil
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
