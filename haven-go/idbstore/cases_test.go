package idbstore_test

// Cases shared by the browser run (IDBBackend, idbstore_test.go) and the native
// run (badger, badger_native_test.go), so both backends answer the same
// questions with the same expected numbers.

import (
	"context"
	"fmt"
	"slices"
	"testing"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
	"github.com/stretchr/testify/require"
)

var ctx = context.Background()

const (
	skA = "000000000000000000000000000000000000000000000000000000000000000a"
	skB = "000000000000000000000000000000000000000000000000000000000000000b"
	skC = "000000000000000000000000000000000000000000000000000000000000000c"
)

func pub(sk string) string { pk, _ := nostr.GetPublicKey(sk); return pk }

func mk(t *testing.T, sk string, kind int, ts int, tags ...nostr.Tag) *nostr.Event {
	evt := &nostr.Event{Kind: kind, CreatedAt: nostr.Timestamp(ts), Tags: nostr.Tags(tags), Content: fmt.Sprintf("%d-%d", kind, ts)}
	require.NoError(t, evt.Sign(sk))
	return evt
}

func save(t *testing.T, db eventstore.Store, evts ...*nostr.Event) {
	for _, e := range evts {
		require.NoError(t, db.SaveEvent(ctx, e))
	}
}

func query(t *testing.T, db eventstore.Store, f nostr.Filter) []*nostr.Event {
	ch, err := db.QueryEvents(ctx, f)
	require.NoError(t, err)
	var out []*nostr.Event
	for e := range ch {
		out = append(out, e)
	}
	return out
}

func ids(evts []*nostr.Event) []string {
	out := make([]string, len(evts))
	for i, e := range evts {
		out[i] = e.ID
	}
	slices.Sort(out)
	return out
}

// runCombinations: a filter with several authors/kinds/tag values matches
// every combination of them, and nothing outside the combinations.
func runCombinations(t *testing.T, db eventstore.Store) {
	require.NoError(t, db.Init())
	defer db.Close()

	a1 := mk(t, skA, 1, 10)
	a7 := mk(t, skA, 7, 11)
	b1 := mk(t, skB, 1, 12)
	b7 := mk(t, skB, 7, 13)
	a3 := mk(t, skA, 3, 14) // right author, wrong kind
	c1 := mk(t, skC, 1, 15) // right kind, wrong author
	dX := mk(t, skA, 30000, 16, nostr.Tag{"d", "x"})
	dY := mk(t, skB, 30000, 17, nostr.Tag{"d", "y"})
	dZ := mk(t, skA, 30000, 18, nostr.Tag{"d", "z"})
	pe := mk(t, skC, 1, 19, nostr.Tag{"p", pub(skA)}, nostr.Tag{"e", "ee"})
	pOnly := mk(t, skC, 1, 20, nostr.Tag{"p", pub(skB)})
	eOnly := mk(t, skC, 1, 21, nostr.Tag{"e", "ee"})
	save(t, db, a1, a7, b1, b7, a3, c1, dX, dY, dZ, pe, pOnly, eOnly)

	got := query(t, db, nostr.Filter{Authors: []string{pub(skA), pub(skB)}, Kinds: []int{1, 7}})
	require.Equal(t, ids([]*nostr.Event{a1, a7, b1, b7}), ids(got), "authors x kinds")

	got = query(t, db, nostr.Filter{Kinds: []int{30000}, Authors: []string{pub(skA), pub(skB)}, Tags: nostr.TagMap{"d": {"x", "y"}}})
	require.Equal(t, ids([]*nostr.Event{dX, dY}), ids(got), "kinds x authors x #d")

	got = query(t, db, nostr.Filter{Kinds: []int{30000}, Tags: nostr.TagMap{"d": {"x", "z"}}})
	require.Equal(t, ids([]*nostr.Event{dX, dZ}), ids(got), "#d values across authors")

	// Two tag keys: one of the #p values AND the #e value.
	got = query(t, db, nostr.Filter{Tags: nostr.TagMap{"p": {pub(skA), pub(skB)}, "e": {"ee"}}})
	require.Equal(t, ids([]*nostr.Event{pe}), ids(got), "#p x #e")

	n, err := db.(eventstore.Counter).CountEvents(ctx, nostr.Filter{Authors: []string{pub(skA), pub(skB)}, Kinds: []int{1, 7}})
	require.NoError(t, err)
	require.EqualValues(t, 4, n, "count authors x kinds")
}

// limitCase: with `stored` events, a REQ with `limit` returns `want` events.
// The numbers are badger's (Haven on the phones), measured by the native run.
type limitCase struct {
	limit int
	want  int
}

const limitStored = 1100

var limitCases = []limitCase{
	{limit: 0, want: 250},     // no limit: MaxLimit/4
	{limit: 10, want: 10},     // honoured
	{limit: 1000, want: 1000}, // == MaxLimit: honoured
	{limit: 1001, want: 250},  // > MaxLimit: not clamped to 1000, falls back to MaxLimit/4
	{limit: 5000, want: 250},
}

func runLimits(t *testing.T, db eventstore.Store) {
	require.NoError(t, db.Init())
	defer db.Close()

	all := make([]*nostr.Event, 0, limitStored)
	for i := 0; i < limitStored; i++ {
		all = append(all, mk(t, skA, 1, 1000+i))
	}
	save(t, db, all...)
	slices.SortFunc(all, nostr.CompareEventPtrReverse)

	for _, c := range limitCases {
		got := query(t, db, nostr.Filter{Kinds: []int{1}, Limit: c.limit})
		require.Len(t, got, c.want, "limit %d", c.limit)
		require.Equal(t, all[:c.want], got, "limit %d returns the newest, in order", c.limit)
	}

	// Negentropy sessions use MaxLimitNegentropy and ignore the cap.
	got := query(t, db, nostr.Filter{Kinds: []int{1}})
	require.Len(t, got, 250)
	negCtx := eventstore.SetNegentropy(ctx)
	ch, err := db.QueryEvents(negCtx, nostr.Filter{Kinds: []int{1}})
	require.NoError(t, err)
	n := 0
	for range ch {
		n++
	}
	require.Equal(t, limitStored, n, "negentropy session sees everything")

	// Paging with until walks the whole store without gaps or repeats.
	seen := map[string]bool{}
	var until *nostr.Timestamp
	for {
		page := query(t, db, nostr.Filter{Kinds: []int{1}, Limit: 300, Until: until})
		if len(page) == 0 {
			break
		}
		for _, e := range page {
			seen[e.ID] = true
		}
		u := page[len(page)-1].CreatedAt - 1
		until = &u
	}
	require.Len(t, seen, limitStored, "until-paging covers the store")
}

func runReplace(t *testing.T, db eventstore.Store) {
	require.NoError(t, db.Init())
	defer db.Close()

	old := mk(t, skA, 0, 100)
	cur := mk(t, skA, 0, 200)
	require.NoError(t, db.ReplaceEvent(ctx, old))
	require.NoError(t, db.ReplaceEvent(ctx, cur))
	require.NoError(t, db.ReplaceEvent(ctx, old)) // older arrives late: ignored
	got := query(t, db, nostr.Filter{Kinds: []int{0}, Authors: []string{pub(skA)}})
	require.Equal(t, ids([]*nostr.Event{cur}), ids(got), "replaceable keeps newest")

	x1 := mk(t, skA, 30023, 100, nostr.Tag{"d", "x"})
	x2 := mk(t, skA, 30023, 200, nostr.Tag{"d", "x"})
	y1 := mk(t, skA, 30023, 150, nostr.Tag{"d", "y"})
	for _, e := range []*nostr.Event{x1, y1, x2} {
		require.NoError(t, db.ReplaceEvent(ctx, e))
	}
	got = query(t, db, nostr.Filter{Kinds: []int{30023}, Authors: []string{pub(skA)}})
	require.Equal(t, ids([]*nostr.Event{x2, y1}), ids(got), "addressable replaces per d tag")

	dup := mk(t, skB, 1, 300)
	require.NoError(t, db.SaveEvent(ctx, dup))
	require.ErrorIs(t, db.SaveEvent(ctx, dup), eventstore.ErrDupEvent)

	require.NoError(t, db.DeleteEvent(ctx, dup))
	require.Empty(t, query(t, db, nostr.Filter{IDs: []string{dup.ID}}))
}
