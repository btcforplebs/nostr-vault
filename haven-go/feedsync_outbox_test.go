package main

import (
	"context"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

func resetFeedOutboxLists(t *testing.T) {
	t.Helper()
	feedOutboxLists.Lock()
	feedOutboxLists.write, feedOutboxLists.at, feedOutboxLists.follows = nil, time.Time{}, 0
	feedOutboxLists.Unlock()
	t.Cleanup(func() {
		feedOutboxLists.Lock()
		feedOutboxLists.write = nil
		feedOutboxLists.Unlock()
	})
}

// A follow the owner's relays already reach adds nothing; the rest are
// covered greedily, a follow with no list gets no hidden fallback, private
// addresses never qualify, and at most feedOutboxMaxExtra relays are picked.
func TestFeedOutboxPlanCoversOnlyWhatTheOwnersRelaysMiss(t *testing.T) {
	write := map[string][]string{
		"a": {"wss://Own.example/", "wss://x.example"}, // reached by the owner's relay
		"b": {"wss://x.example", "wss://y.example"},
		"c": {"wss://x.example/"},
		"d": {"wss://y.example"},
		"e": {"ws://plain.example", "wss://192.168.1.4", "wss://box.local"},
		// "f" publishes no relay list.
	}
	got := feedOutboxPlan([]string{"a", "b", "c", "d", "e", "f"}, write, []string{"wss://own.example"}, feedOutboxMaxExtra)
	want := map[string][]string{"wss://x.example": {"b", "c"}, "wss://y.example": {"d"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("plan = %v, want %v", got, want)
	}

	many := map[string][]string{}
	var follows []string
	for i := range 20 {
		pk := fmt.Sprintf("p%02d", i)
		follows = append(follows, pk)
		many[pk] = []string{fmt.Sprintf("wss://r%02d.example", i)}
	}
	if n := len(feedOutboxPlan(follows, many, nil, feedOutboxMaxExtra)); n != 8 {
		t.Fatalf("picked %d extra relays, want the apps' cap of 8", n)
	}
}

// NIP-65: unmarked and "write" r tags are where a follow posts; "read" is
// not. The newest list wins.
func TestFollowWriteRelaysFromNewestList(t *testing.T) {
	old := &nostr.Event{PubKey: "f", Kind: nostr.KindRelayListMetadata, CreatedAt: 10, Tags: nostr.Tags{{"r", "wss://old.example"}}}
	cur := &nostr.Event{PubKey: "f", Kind: nostr.KindRelayListMetadata, CreatedAt: 20, Tags: nostr.Tags{
		{"r", "wss://both.example"}, {"r", "wss://post.example", "write"}, {"r", "wss://inbox.example", "read"},
	}}
	got := followWriteRelaysFrom([]*nostr.Event{cur, old})
	want := map[string][]string{"f": {"wss://both.example", "wss://post.example"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("write relays = %v, want %v", got, want)
	}
}

// The bug: the feed sync asked only the owner's relays, so a follow posting
// only to their own relay never reached the vault's feed. Now their list is
// read from the owner's relay, their write relay is asked for them alone,
// and their read relay is never asked.
func TestFeedSyncReadsAFollowOnTheirOwnWriteRelay(t *testing.T) {
	resetFeedOutboxLists(t)
	follow, reached := newTestKey(t), newTestKey(t)
	list := follow.sign(t, nostr.Event{Kind: nostr.KindRelayListMetadata, CreatedAt: 50_000, Tags: nostr.Tags{
		{"r", "wss://their-post.example", "write"}, {"r", "wss://their-inbox.example", "read"},
	}})
	reachedList := reached.sign(t, nostr.Event{Kind: nostr.KindRelayListMetadata, CreatedAt: 50_000, Tags: nostr.Tags{
		{"r", "wss://own.example"}, {"r", "wss://their-post.example"},
	}})
	theirNotes := notesOf(t, follow, 30, 100_000)
	reachedNotes := notesOf(t, reached, 30, 100_000)
	inbox := &pagingRelay{held: theirNotes}
	withPagingRelays(t, map[string]*pagingRelay{
		"wss://own.example":         {held: []*nostr.Event{&list, &reachedList}},
		"wss://their-post.example":  {held: append(append([]*nostr.Event{}, theirNotes...), reachedNotes...)},
		"wss://their-inbox.example": inbox,
	})

	ctx := context.Background()
	owners := []string{"wss://own.example"}
	follows := []string{follow.pk, reached.pk}
	plan := feedOutboxPlan(follows, followWriteRelays(ctx, follows, owners), owners, feedOutboxMaxExtra)
	got := map[string]int{}
	complete := pullFeedOutbox(ctx, plan, nil, 0, func(ev *nostr.Event) { got[ev.PubKey]++ }, map[string]int{})
	if !complete {
		t.Fatal("a pull that read everything was not complete")
	}
	if got[follow.pk] != 30 {
		t.Fatalf("got %d of the follow's 30 notes from their write relay", got[follow.pk])
	}
	if got[reached.pk] != 0 {
		t.Fatalf("asked the extra relay for %d notes of a follow the owner's relay already reaches", got[reached.pk])
	}
	if inbox.asks != 0 {
		t.Fatalf("asked the follow's read relay %d times", inbox.asks)
	}
}

// A follow's relay list can name any address; the vault dials only public
// hostnames (health audit Tron §5). Every one of these passed before.
func TestOutboxRelayKeyRefusesAddressesAFollowPicks(t *testing.T) {
	refused := []string{
		// the old prefix list
		"wss://10.0.0.1", "wss://192.168.1.4", "wss://127.0.0.1:7777", "wss://localhost", "wss://box.local", "wss://abc.onion",
		// private, CGNAT, link-local, other v4 literals
		"wss://172.16.0.1", "wss://172.31.255.254/", "wss://100.64.0.1", "wss://100.100.100.100", "wss://169.254.169.254/latest",
		"wss://0.0.0.0", "wss://8.8.8.8", "wss://1.2.3.4:443/path",
		// v6 literals
		"wss://[::1]", "wss://[fe80::1%25en0]", "wss://[fc00::1]", "wss://[fd7a:115c:a1e0::1]", "wss://[::ffff:10.0.0.1]", "wss://[2606:4700::1111]",
		// forms a resolver may read as an address
		"wss://127.1", "wss://0x7f.1", "wss://10.0.0.010", "wss://2130706433",
		// private-use names, trailing dot, dotless
		"wss://localhost.", "wss://relay.localhost", "wss://nas.lan", "wss://router.home.arpa", "wss://vault.internal", "wss://relay.test", "wss://intranet",
		"wss://LOCALHOST", "wss://Box.Local.",
		// not wss
		"ws://relay.example.com", "https://relay.example.com",
	}
	for _, raw := range refused {
		if k, ok := outboxRelayKey(raw); ok {
			t.Errorf("outboxRelayKey(%q) = %q, want refused", raw, k)
		}
	}
	kept := map[string]string{
		"wss://Relay.Damus.io/":         "wss://relay.damus.io",
		"wss://nos.lol":                 "wss://nos.lol",
		"wss://relay.example.com:8443/": "wss://relay.example.com:8443",
		"wss://relay.primal.net.":       "wss://relay.primal.net",
		"wss://10.example.com":          "wss://10.example.com",
		"wss://local.example.org/inbox": "wss://local.example.org/inbox",
	}
	for raw, want := range kept {
		if k, ok := outboxRelayKey(raw); !ok || k != want {
			t.Errorf("outboxRelayKey(%q) = %q, %v; want %q", raw, k, ok, want)
		}
	}
}
