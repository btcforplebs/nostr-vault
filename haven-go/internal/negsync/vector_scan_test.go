package negsync

import (
	"context"
	"fmt"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// memQuery is a store that answers like the eventstores: the newest Limit
// events matching Since/Until, newest first.
type memQuery struct {
	evs     []*nostr.Event
	queries atomic.Int32
}

func (m *memQuery) query(_ context.Context, f nostr.Filter) (chan *nostr.Event, error) {
	m.queries.Add(1)
	var hit []*nostr.Event
	for _, ev := range m.evs {
		if f.Since != nil && ev.CreatedAt < *f.Since {
			continue
		}
		if f.Until != nil && ev.CreatedAt > *f.Until {
			continue
		}
		hit = append(hit, ev)
	}
	slices.SortStableFunc(hit, func(a, b *nostr.Event) int { return int(b.CreatedAt) - int(a.CreatedAt) })
	if f.Limit > 0 && len(hit) > f.Limit {
		hit = hit[:f.Limit]
	}
	ch := make(chan *nostr.Event, len(hit))
	for _, ev := range hit {
		ch <- ev
	}
	close(ch)
	return ch, nil
}

// events makes n events; perSecond share each second, counting down from 1e6.
func events(n, perSecond int) []*nostr.Event {
	out := make([]*nostr.Event, n)
	for i := range out {
		out[i] = &nostr.Event{
			ID:        fmt.Sprintf("%064x", i),
			CreatedAt: nostr.Timestamp(1_000_000 - i/perSecond),
			Content:   "body",
			Tags:      nostr.Tags{{"p", "x"}},
		}
	}
	return out
}

func scanAll(t *testing.T, m *memQuery, f nostr.Filter, limit, page int) []*nostr.Event {
	t.Helper()
	var got []*nostr.Event
	err := ScanIDs(context.Background(), m.query, f, limit, page, func(ev *nostr.Event) bool {
		got = append(got, ev)
		return true
	})
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func idSet(t *testing.T, evs []*nostr.Event) map[string]nostr.Timestamp {
	t.Helper()
	m := make(map[string]nostr.Timestamp, len(evs))
	for _, ev := range evs {
		if _, dup := m[ev.ID]; dup {
			t.Fatalf("id %s sent twice", ev.ID)
		}
		m[ev.ID] = ev.CreatedAt
	}
	return m
}

func TestScanIDsMatchesOneBigQuery(t *testing.T) {
	for _, tc := range []struct {
		name                 string
		n, perSec, limit, pg int
	}{
		{"pages split seconds", 1000, 3, 10_000, 100},
		{"one event per second", 1000, 1, 10_000, 7},
		{"cap below the store", 1000, 4, 250, 64},
		{"page larger than all", 50, 2, 10_000, 1000},
		{"second bigger than a page", 1000, 300, 10_000, 100},
		{"cap inside a big second", 1000, 300, 450, 100},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := &memQuery{evs: events(tc.n, tc.perSec)}
			got := idSet(t, scanAll(t, m, nostr.Filter{}, tc.limit, tc.pg))
			want := min(tc.limit, tc.n)
			if len(got) != want {
				t.Fatalf("got %d ids, want %d", len(got), want)
			}
			// Every id sent is a real event with its own time, and the set
			// is the newest: nothing sent is older than something left out,
			// except inside the one second the cap cut.
			var oldestSent nostr.Timestamp = 1 << 62
			for id, ts := range got {
				var i int
				fmt.Sscanf(id, "%x", &i)
				if m.evs[i].CreatedAt != ts {
					t.Fatalf("id %s carries %d, event has %d", id, ts, m.evs[i].CreatedAt)
				}
				oldestSent = min(oldestSent, ts)
			}
			for _, ev := range m.evs {
				if _, ok := got[ev.ID]; !ok && ev.CreatedAt > oldestSent {
					t.Fatalf("left out %s at %d, newer than sent %d", ev.ID, ev.CreatedAt, oldestSent)
				}
			}
		})
	}
}

func TestScanIDsSendsStubsOnly(t *testing.T) {
	m := &memQuery{evs: events(10, 1)}
	for _, ev := range scanAll(t, m, nostr.Filter{}, 100, 3) {
		if ev.Content != "" || ev.Tags != nil || ev.PubKey != "" || ev.Sig != "" {
			t.Fatalf("stub carries more than id+created_at: %+v", ev)
		}
	}
}

func TestScanIDsKeepsTheFiltersWindow(t *testing.T) {
	m := &memQuery{evs: events(1000, 2)}
	since, until := nostr.Timestamp(999_800), nostr.Timestamp(999_900)
	got := idSet(t, scanAll(t, m, nostr.Filter{Since: &since, Until: &until}, 10_000, 30))
	if len(got) != 202 { // 101 seconds × 2
		t.Fatalf("got %d, want 202", len(got))
	}
	for _, ts := range got {
		if ts < since || ts > until {
			t.Fatalf("sent %d outside [%d, %d]", ts, since, until)
		}
	}
}

func TestScanIDsStopsWhenEmitSaysSo(t *testing.T) {
	m := &memQuery{evs: events(1000, 1)}
	n := 0
	ScanIDs(context.Background(), m.query, nostr.Filter{}, 10_000, 100, func(*nostr.Event) bool {
		n++
		return n < 5
	})
	if n != 5 || m.queries.Load() != 1 {
		t.Fatalf("emit called %d times over %d queries, want 5 over 1", n, m.queries.Load())
	}
}

func TestBuildVectorMarksItsQuery(t *testing.T) {
	var marked atomic.Bool
	store := markProbe{seen: &marked}
	if _, err := BuildVector(context.Background(), store, nostr.Filter{}); err != nil {
		t.Fatal(err)
	}
	if !marked.Load() {
		t.Fatal("BuildVector's QuerySync context is not marked ForVector")
	}
}

type markProbe struct {
	nostr.RelayStore
	seen *atomic.Bool
}

func (p markProbe) QuerySync(ctx context.Context, _ nostr.Filter) ([]*nostr.Event, error) {
	p.seen.Store(IsForVector(ctx))
	return nil, nil
}

// The gate lets one scan run at a time.
func TestAcquireScanOneAtATime(t *testing.T) {
	var active, most atomic.Int32
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			release, err := AcquireScan(context.Background())
			if err != nil {
				t.Error(err)
				return
			}
			n := active.Add(1)
			for {
				m := most.Load()
				if n <= m || most.CompareAndSwap(m, n) {
					break
				}
			}
			time.Sleep(5 * time.Millisecond)
			active.Add(-1)
			release()
		}()
	}
	wg.Wait()
	if most.Load() != 1 {
		t.Fatalf("%d scans ran at once, want 1", most.Load())
	}
}

func TestAcquireScanGivesUpOnCancel(t *testing.T) {
	release, _ := AcquireScan(context.Background())
	defer release()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r2, err := AcquireScan(ctx)
	r2()
	if err == nil {
		t.Fatal("a cancelled wait took the gate")
	}
}

// A holder that never lets go must not stall every later sync.
func TestAcquireScanRunsAnywayAfterTheWait(t *testing.T) {
	old := ScanGateWait
	ScanGateWait = 20 * time.Millisecond
	defer func() { ScanGateWait = old }()
	release, _ := AcquireScan(context.Background())
	defer release()
	start := time.Now()
	r2, err := AcquireScan(context.Background())
	r2() // the no-op: must not free the real holder's slot
	if err != nil || time.Since(start) < ScanGateWait {
		t.Fatalf("err %v after %v", err, time.Since(start))
	}
	select {
	case scanGate <- struct{}{}:
		t.Fatal("the ungated scan's release freed the holder's slot")
	default:
	}
}
