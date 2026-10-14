//go:build js && wasm

package idbstore_test

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"slices"
	"strings"
	"syscall/js"
	"testing"
	"time"

	"github.com/barrydeen/haven/idbstore"
	"github.com/nbd-wtf/go-nostr"
	"github.com/stretchr/testify/require"
)

// TestContext proves where the binary ran: the harness sets IDBSTORE_CONTEXT
// to "page" or "worker", and the global scope has to agree.
func TestContext(t *testing.T) {
	want := map[string]string{"page": "Window", "worker": "DedicatedWorkerGlobalScope"}[os.Getenv("IDBSTORE_CONTEXT")]
	got := js.Global().Get("constructor").Get("name").String()
	t.Logf("global scope %s, user agent %s", got, js.Global().Get("navigator").Get("userAgent").String())
	if want == "" {
		t.Skip("IDBSTORE_CONTEXT not set")
	}
	require.Equal(t, want, got)
}

// awaitPromise blocks on a JS promise. Not for use inside a js.FuncOf callback.
func awaitPromise(p js.Value) (js.Value, error) {
	done := make(chan struct{})
	var v js.Value
	var err error
	ok := js.FuncOf(func(_ js.Value, a []js.Value) any { v = a[0]; close(done); return nil })
	fail := js.FuncOf(func(_ js.Value, a []js.Value) any {
		err = fmt.Errorf("%s", a[0].Call("toString").String())
		close(done)
		return nil
	})
	defer ok.Release()
	defer fail.Release()
	p.Call("then", ok, fail)
	<-done
	return v, err
}

func deleteDB(t *testing.T, name string) {
	req := js.Global().Get("indexedDB").Call("deleteDatabase", name)
	done := make(chan struct{})
	f := js.FuncOf(func(js.Value, []js.Value) any { close(done); return nil })
	defer f.Release()
	req.Set("onsuccess", f)
	req.Set("onerror", f)
	req.Set("onblocked", f)
	<-done
}

type storageInfo struct {
	PersistExposed bool    `json:"persist_exposed"`
	Persisted      bool    `json:"persisted"`
	UsageMB        float64 `json:"usage_mb"`
	QuotaMB        float64 `json:"quota_mb"`
	IndexedDBMB    float64 `json:"indexeddb_mb,omitempty"`
}

func storage(t *testing.T) storageInfo {
	s := js.Global().Get("navigator").Get("storage")
	var info storageInfo
	info.PersistExposed = s.Get("persist").Type() == js.TypeFunction
	p, err := awaitPromise(s.Call("persisted"))
	require.NoError(t, err)
	info.Persisted = p.Bool()
	e, err := awaitPromise(s.Call("estimate"))
	require.NoError(t, err)
	info.UsageMB = e.Get("usage").Float() / 1e6
	info.QuotaMB = e.Get("quota").Float() / 1e6
	if d := e.Get("usageDetails"); !d.IsUndefined() && !d.Get("indexedDB").IsUndefined() {
		info.IndexedDBMB = d.Get("indexedDB").Float() / 1e6
	}
	return info
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

// TestBench (IDBSTORE_BENCH=1): fills a store to 50k events the way Haven
// does (one SaveEvent per event) and times feed-style and #p queries apart
// from the inserts. Events carry real ids but a dummy signature: the store
// never checks signatures (khatru does, before SaveEvent), and signing 50k in
// wasm would only slow the fill.
func TestBench(t *testing.T) {
	if os.Getenv("IDBSTORE_BENCH") == "" {
		t.Skip("set IDBSTORE_BENCH=1")
	}
	const total = 50_000
	const name = "bench"
	phase2 := os.Getenv("IDBSTORE_PHASE") == "2"
	if !phase2 {
		deleteDB(t, name)
	}

	db := &idbstore.IDBBackend{Name: name}
	t0 := time.Now()
	require.NoError(t, db.Init())
	openMs := ms(time.Since(t0))
	defer db.Close()

	report := map[string]any{"context": os.Getenv("IDBSTORE_CONTEXT"), "events": total}
	timeQuery := func(label string, f nostr.Filter, runs int) {
		var times []float64
		n := 0
		for i := 0; i < runs; i++ {
			t0 := time.Now()
			got := query(t, db, f)
			times = append(times, ms(time.Since(t0)))
			n = len(got)
			if i == 0 {
				require.True(t, slices.IsSortedFunc(got, nostr.CompareEventPtrReverse), label)
			}
		}
		sorted := slices.Clone(times)
		slices.Sort(sorted)
		report[label] = map[string]any{"results": n, "first_ms": times[0], "median_ms": sorted[len(sorted)/2], "runs_ms": times}
	}
	rng := rand.New(rand.NewPCG(1, 2))
	hexn := func(n int) string {
		b := make([]byte, n)
		for i := range b {
			b[i] = byte(rng.UintN(256))
		}
		return hex.EncodeToString(b)
	}
	authors := make([]string, 300)
	for i := range authors {
		authors[i] = hexn(32)
	}
	queries := func() {
		target := authors[7]
		timeQuery("q_feed_kinds_1_6_limit_250", nostr.Filter{Kinds: []int{1, 6}, Limit: 250}, 7)
		timeQuery("q_p_lookup_default_limit", nostr.Filter{Tags: nostr.TagMap{"p": {target}}}, 7)
		timeQuery("q_p_lookup_kind_7_limit_100", nostr.Filter{Kinds: []int{7}, Tags: nostr.TagMap{"p": {target}}}, 7)
		timeQuery("q_follows_100_authors_x_kinds_1_6_limit_250", nostr.Filter{Authors: authors[:100], Kinds: []int{1, 6}, Limit: 250}, 7)
	}
	if phase2 {
		// After a real reload: new Go runtime, new connection, nothing cached
		// in Go. first_ms is the cold number.
		defer deleteDB(t, name)
		report["phase"] = "after reload"
		report["open_ms"] = openMs
		queries()
		report["storage_after_reload"] = storage(t)
		out, _ := json.MarshalIndent(report, "", "  ")
		fmt.Printf("BENCH %s\n", out)
		return
	}
	sig := strings.Repeat("0", 128)
	words := strings.Fields("the relay keeps notes local first and syncs them over fips when a peer shows up nostr vault haven browser test event")
	text := func(n int) string {
		w := make([]string, n)
		for i := range w {
			w[i] = words[rng.IntN(len(words))]
		}
		return strings.Join(w, " ")
	}

	report["storage_empty"] = storage(t)

	var ids []string
	base := 1_700_000_000
	start := time.Now()
	var insert1100 time.Duration
	for i := 0; i < total; i++ {
		a := authors[rng.IntN(len(authors))]
		p := authors[rng.IntN(len(authors))]
		evt := &nostr.Event{PubKey: a, CreatedAt: nostr.Timestamp(base + i*7), Sig: sig}
		switch r := rng.IntN(100); {
		case r < 55:
			evt.Kind, evt.Content = 1, text(20+rng.IntN(40))
			evt.Tags = nostr.Tags{{"p", p}}
			if len(ids) > 0 && r < 20 {
				evt.Tags = append(evt.Tags, nostr.Tag{"e", ids[rng.IntN(len(ids))], "", "reply"})
			}
		case r < 65:
			evt.Kind = 6
			evt.Tags = nostr.Tags{{"p", p}}
			if len(ids) > 0 {
				evt.Tags = append(evt.Tags, nostr.Tag{"e", ids[rng.IntN(len(ids))]})
			}
		case r < 92:
			evt.Kind, evt.Content = 7, "+"
			evt.Tags = nostr.Tags{{"p", p}}
			if len(ids) > 0 {
				evt.Tags = append(evt.Tags, nostr.Tag{"e", ids[rng.IntN(len(ids))]})
			}
		default:
			evt.Kind, evt.Content = 1111, text(10)
			evt.Tags = nostr.Tags{{"p", p}, {"t", "haven"}}
		}
		evt.ID = evt.GetID()
		ids = append(ids, evt.ID)
		require.NoError(t, db.SaveEvent(ctx, evt))
		if i+1 == 1100 {
			insert1100 = time.Since(start)
			report["storage_1100"] = storage(t)
		}
	}
	insertAll := time.Since(start)
	report["insert_1100_ms"] = ms(insert1100)
	report["insert_50k_ms"] = ms(insertAll)
	report["insert_per_event_ms"] = ms(insertAll) / total
	report["storage_50k"] = storage(t)

	report["phase"] = "fill, then warm"
	queries()

	target := authors[7]
	n, err := db.CountEvents(ctx, nostr.Filter{Tags: nostr.TagMap{"p": {target}}})
	require.NoError(t, err)
	report["p_lookup_total_matches"] = n

	out, _ := json.MarshalIndent(report, "", "  ")
	fmt.Printf("BENCH %s\n", out)
}
