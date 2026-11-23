package trustrank

import (
	"context"
	"maps"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// DefaultBudget is the bytes one relay may send the crawler per minute:
// damus's published per-IP read budget (1 MB/min), used as the yardstick for
// every relay, since the crawl shares the home IP with the owner's phones.
const DefaultBudget = 1 << 20

func (f *RelayFetcher) budget() int64 {
	if f.Budget > 0 {
		return f.Budget
	}
	return DefaultBudget
}

// waitBudget blocks until url may be asked again under its byte budget.
func (f *RelayFetcher) waitBudget(ctx context.Context, url string) error {
	f.mu.Lock()
	at := f.next[url]
	f.mu.Unlock()
	d := time.Until(at)
	if d <= 0 {
		return nil
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// spend charges bytes, received from url by an ask that started at start,
// against its budget: the next ask waits until those bytes fit the rate.
func (f *RelayFetcher) spend(url string, start time.Time, bytes int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.next == nil {
		f.next = map[string]time.Time{}
	}
	if f.sent == nil {
		f.sent = map[string]int64{}
	}
	f.sent[url] += bytes
	base := f.next[url]
	if base.Before(start) {
		base = start
	}
	f.next[url] = base.Add(time.Duration(bytes * int64(time.Minute) / f.budget()))
}

// Sent is about how many bytes each relay has sent since the fetcher was
// made (logged after each pass).
func (f *RelayFetcher) Sent() map[string]int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return maps.Clone(f.sent)
}

// Guesses before the first batch: a full read's kind 3 averages ~20 KB per
// asked person (2026-11-22 run: ~110 MB for 5,527 people); a refresh mostly
// gets nothing back.
var firstPerList = [2]float64{20 << 10, 1 << 10}

// Batch is how many people the next REQ should ask for: as many as one
// minute's budget is expected to carry, 1 to MaxBatch. Sizing it this way
// keeps a single reply from bursting past the per-minute budget.
func (f *RelayFetcher) Batch(refresh bool) int {
	f.mu.Lock()
	per := f.perList[mode(refresh)]
	f.mu.Unlock()
	if per <= 0 {
		per = firstPerList[mode(refresh)]
	}
	return max(1, min(MaxBatch, int(float64(f.budget())/per)))
}

// learn folds one batch's bytes per asked person into the estimate.
func (f *RelayFetcher) learn(refresh bool, bytes int64, asked int) {
	if asked == 0 {
		return
	}
	per := max(float64(bytes)/float64(asked), 64) // an empty reply still costs a REQ
	f.mu.Lock()
	defer f.mu.Unlock()
	m := mode(refresh)
	if f.perList[m] == 0 {
		f.perList[m] = per
		return
	}
	f.perList[m] = 0.7*f.perList[m] + 0.3*per
}

// shrink halves the next Batch: a relay that timed out may have been asked
// for more than the link carries in time. A later answer's learn grows it
// back toward what replies really cost.
func (f *RelayFetcher) shrink(refresh bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	m := mode(refresh)
	if f.perList[m] <= 0 {
		f.perList[m] = firstPerList[m]
	}
	f.perList[m] = min(2*f.perList[m], float64(f.budget()))
}

func mode(refresh bool) int {
	if refresh {
		return 1
	}
	return 0
}

// eventBytes is about the size of ev on the wire, without encoding it.
func eventBytes(ev *nostr.Event) int64 {
	n := int64(len(ev.Content)) + 64 + 64 + 128 + 60 // id, pubkey, sig, field names and numbers
	for _, t := range ev.Tags {
		n += 2
		for _, s := range t {
			n += int64(len(s)) + 3
		}
	}
	return n
}
