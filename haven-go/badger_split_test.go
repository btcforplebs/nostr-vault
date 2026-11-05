//go:build !wasm

package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"
	"testing"

	badgerdb "github.com/dgraph-io/badger/v4"
	"github.com/nbd-wtf/go-nostr"
)

func openSplitStore(t *testing.T, goos string) *badgerStore {
	t.Helper()
	s := newBadgerStoreFor(t.TempDir(), goos)
	if err := s.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s
}

// bigFollowList: a kind 3 following n made-up people, shaped like 08c2d8f1
// (p tags with a relay and a petname).
func bigFollowList(t *testing.T, sk string, n int, at nostr.Timestamp) *nostr.Event {
	t.Helper()
	ev := &nostr.Event{Kind: nostr.KindFollowList, CreatedAt: at}
	for i := 0; i < n; i++ {
		ev.Tags = append(ev.Tags, nostr.Tag{"p", lastFollow(i + 1), "wss://relay.example.com/", "pet"})
	}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

func queryIDs(t *testing.T, s DBBackend, f nostr.Filter) []string {
	t.Helper()
	ch, err := s.QueryEvents(context.Background(), f)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for ev := range ch {
		ids = append(ids, ev.ID)
	}
	return ids
}

// keysWithPrefix lists every key in the store starting with one of prefixes.
func keysWithPrefix(t *testing.T, s *badgerStore, prefixes ...byte) [][]byte {
	t.Helper()
	var out [][]byte
	err := s.View(func(txn *badgerdb.Txn) error {
		it := txn.NewIterator(badgerdb.IteratorOptions{PrefetchValues: false})
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() {
			k := it.Item().KeyCopy(nil)
			for _, p := range prefixes {
				if k[0] == p {
					out = append(out, k)
				}
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// lastFollow is the nth made-up follow. The number leads, since eventstore
// indexes a hex value by its first 8 bytes only.
func lastFollow(n int) string { return fmt.Sprintf("%016x%048x", n, 0) }

// The 08c2d8f1 failure: a 7,136-person follow list replacing an older copy
// of itself on a phone-sized store. eventstore alone refuses it; the store
// replaces it, and only the new copy is left, findable by any follow.
func TestBadgerReplaceBigFollowListOnPhone(t *testing.T) {
	ctx := context.Background()
	sk := nostr.GeneratePrivateKey()
	old := bigFollowList(t, sk, 7136, 1000)
	next := bigFollowList(t, sk, 7136, 2000)

	// Before the fix: eventstore's single transaction is too big.
	raw := openSplitStore(t, "ios")
	if err := raw.BadgerBackend.SaveEvent(ctx, old); err != nil {
		t.Fatal(err)
	}
	if err := raw.BadgerBackend.ReplaceEvent(ctx, next); !errors.Is(err, badgerdb.ErrTxnTooBig) {
		t.Fatalf("eventstore replace: want ErrTxnTooBig, got %v", err)
	}

	s := openSplitStore(t, "ios")
	if err := s.SaveEvent(ctx, old); err != nil {
		t.Fatal(err)
	}
	if err := s.ReplaceEvent(ctx, next); err != nil {
		t.Fatalf("replace: %v", err)
	}
	got := queryIDs(t, s, nostr.Filter{Kinds: []int{3}, Tags: nostr.TagMap{"p": []string{lastFollow(7136)}}, Limit: 10})
	if len(got) != 1 || got[0] != next.ID {
		t.Fatalf("by last follow: got %v, want only the new copy %s", got, next.ID)
	}
	if got := queryIDs(t, s, nostr.Filter{IDs: []string{old.ID}}); len(got) != 0 {
		t.Fatalf("old copy still stored: %v", got)
	}
	// Every key the old copy had is gone: one copy's worth of tag keys left.
	if n := len(keysWithPrefix(t, s, badgerIndexTagPrefix, badgerIndexTag32Prefix, badgerIndexTagAddrPrefix)); n != 7136 {
		t.Fatalf("tag index keys: got %d, want 7136", n)
	}
	// An older copy arriving now is not stored over the new one.
	if err := s.ReplaceEvent(ctx, old); err != nil {
		t.Fatal(err)
	}
	if got := queryIDs(t, s, nostr.Filter{Authors: []string{next.PubKey}, Kinds: []int{3}}); len(got) != 1 || got[0] != next.ID {
		t.Fatalf("after late old copy: got %v", got)
	}
}

// A list too big for one transaction even on its own, on the Mac: saved,
// found by its first and last follow, a second save is a duplicate, and a
// delete leaves no key behind.
func TestBadgerSaveAndDeleteHugeEventOnMac(t *testing.T) {
	ctx := context.Background()
	sk := nostr.GeneratePrivateKey()
	ev := bigFollowList(t, sk, 30000, 1000)

	raw := openSplitStore(t, "darwin")
	if err := raw.BadgerBackend.SaveEvent(ctx, ev); !errors.Is(err, badgerdb.ErrTxnTooBig) {
		t.Fatalf("eventstore save: want ErrTxnTooBig, got %v", err)
	}

	s := openSplitStore(t, "darwin")
	if err := s.SaveEvent(ctx, ev); err != nil {
		t.Fatalf("save: %v", err)
	}
	for _, p := range []string{lastFollow(1), lastFollow(30000)} {
		if got := queryIDs(t, s, nostr.Filter{Tags: nostr.TagMap{"p": []string{p}}, Limit: 5}); len(got) != 1 || got[0] != ev.ID {
			t.Fatalf("by p %s…: got %v", p[:8], got)
		}
	}
	if got := queryIDs(t, s, nostr.Filter{Authors: []string{ev.PubKey}, Kinds: []int{3}}); len(got) != 1 {
		t.Fatalf("by author: got %v", got)
	}
	if err := s.SaveEvent(ctx, ev); err == nil {
		t.Fatal("second save of the same event: want a duplicate error")
	}
	if n := len(keysWithPrefix(t, s, badgerIndexTagPrefix, badgerIndexTag32Prefix, badgerIndexTagAddrPrefix)); n != 30000 {
		t.Fatalf("tag index keys after a duplicate save: got %d, want 30000", n)
	}

	if err := s.DeleteEvent(ctx, ev); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if got := queryIDs(t, s, nostr.Filter{IDs: []string{ev.ID}}); len(got) != 0 {
		t.Fatalf("still stored after delete: %v", got)
	}
	if left := keysWithPrefix(t, s, 0, 1, 2, 3, 4, 5, 6, 7, 8); len(left) != 0 {
		t.Fatalf("%d keys left after delete", len(left))
	}
}

// Other big events take the same path: a huge addressable event replacing
// an older copy on a phone, with its d tag kept straight.
func TestBadgerReplaceHugeAddressableOnPhone(t *testing.T) {
	ctx := context.Background()
	sk := nostr.GeneratePrivateKey()
	mk := func(at nostr.Timestamp, d string) *nostr.Event {
		ev := &nostr.Event{Kind: 30000, CreatedAt: at, Tags: nostr.Tags{{"d", d}}}
		for i := 0; i < 14000; i++ {
			ev.Tags = append(ev.Tags, nostr.Tag{"t", fmt.Sprintf("topic%d", i)})
		}
		ev.Sign(sk)
		return ev
	}
	other := mk(500, "other")
	old, next := mk(1000, "people"), mk(2000, "people")
	s := openSplitStore(t, "ios")
	for _, ev := range []*nostr.Event{other, old} {
		if err := s.ReplaceEvent(ctx, ev); err != nil {
			t.Fatalf("first copy: %v", err)
		}
	}
	if err := s.ReplaceEvent(ctx, next); err != nil {
		t.Fatalf("replace: %v", err)
	}
	got := queryIDs(t, s, nostr.Filter{Authors: []string{next.PubKey}, Kinds: []int{30000}, Limit: 10})
	sort.Strings(got)
	want := []string{other.ID, next.ID}
	sort.Strings(want)
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got %v, want the other list and the new copy %v", got, want)
	}
}

// badgerTagIndexKeys must be exactly the tag keys eventstore writes, or a
// split write would leave events unfindable and a split delete would leave
// keys behind. Covers every tag shape getIndexKeysForEvent branches on.
func TestBadgerTagIndexKeysMatchEventstore(t *testing.T) {
	ctx := context.Background()
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	long := string(bytes.Repeat([]byte("x"), 101))
	hundred := string(bytes.Repeat([]byte("y"), 100))
	ev := &nostr.Event{Kind: 1, CreatedAt: 1234567, Tags: nostr.Tags{
		{"p", pk},                         // 32-byte hex
		{"p", pk},                         // duplicate
		{"e", lastFollow(7), "wss://r/"},  // 32-byte hex with extras
		{"a", "30023:" + pk + ":my-post"}, // address
		{"a", "30023:" + pk + ":"},        // address, empty d
		{"a", "x:" + pk + ":bad"},         // not an address
		{"t", "nostr"},                    // plain
		{"t", "Nostr"},                    // case differs
		{"T", "nostr"},                    // other letter
		{"t", hundred},                    // longest indexed
		{"t", long},                       // too long
		{"t", ""},                         // empty
		{"t"},                             // no value
		{"client", "x"},                   // long name
		{"r", "abcd"},                     // short hex
	}}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	s := openSplitStore(t, "darwin")
	if err := s.BadgerBackend.SaveEvent(ctx, ev); err != nil {
		t.Fatal(err)
	}
	serial, ok := s.serialOf(ev)
	if !ok {
		t.Fatal("no serial")
	}
	stored := keysWithPrefix(t, s, badgerIndexTagPrefix, badgerIndexTag32Prefix, badgerIndexTagAddrPrefix)
	mine := badgerTagIndexKeys(ev, serial)
	hexAll := func(ks [][]byte) []string {
		var out []string
		for _, k := range ks {
			out = append(out, fmt.Sprintf("%x", k))
		}
		sort.Strings(out)
		return out
	}
	if a, b := hexAll(stored), hexAll(mine); fmt.Sprint(a) != fmt.Sprint(b) {
		t.Fatalf("tag keys differ\neventstore: %v\nours:       %v", a, b)
	}
	if len(stored) != 10 {
		t.Fatalf("eventstore wrote %d tag keys, the cases above expect 10", len(stored))
	}
}

// The same list on the Mac: one older copy fits a Mac transaction, but a
// store that holds several (saved, not replaced, by an older path) can't
// replace them in one.
func TestBadgerReplaceBigFollowListOverCopiesOnMac(t *testing.T) {
	ctx := context.Background()
	sk := nostr.GeneratePrivateKey()
	var olds []*nostr.Event
	for i := 0; i < 3; i++ {
		olds = append(olds, bigFollowList(t, sk, 7136, nostr.Timestamp(1000+i)))
	}
	next := bigFollowList(t, sk, 7136, 2000)

	raw := openSplitStore(t, "darwin")
	s := openSplitStore(t, "darwin")
	for _, old := range olds {
		for _, st := range []*badgerStore{raw, s} {
			if err := st.BadgerBackend.SaveEvent(ctx, old); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := raw.BadgerBackend.ReplaceEvent(ctx, next); !errors.Is(err, badgerdb.ErrTxnTooBig) {
		t.Fatalf("eventstore replace: want ErrTxnTooBig, got %v", err)
	}
	if err := s.ReplaceEvent(ctx, next); err != nil {
		t.Fatalf("replace: %v", err)
	}
	got := queryIDs(t, s, nostr.Filter{Kinds: []int{3}, Tags: nostr.TagMap{"p": []string{lastFollow(1)}}, Limit: 10})
	if len(got) != 1 || got[0] != next.ID {
		t.Fatalf("got %v, want only the new copy", got)
	}
}
