package wot

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

type testKey struct{ sk, pk string }

func newTestKey(t *testing.T) testKey {
	sk := nostr.GeneratePrivateKey()
	pk, err := nostr.GetPublicKey(sk)
	if err != nil {
		t.Fatal(err)
	}
	return testKey{sk, pk}
}

// followList is k's signed kind-3 list naming follows.
func (k testKey) followList(t *testing.T, follows ...testKey) *nostr.Event {
	ev := &nostr.Event{PubKey: k.pk, Kind: nostr.KindFollowList, CreatedAt: nostr.Now()}
	for _, f := range follows {
		ev.Tags = append(ev.Tags, nostr.Tag{"p", f.pk})
	}
	if err := ev.Sign(k.sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

// seedRelay serves events to any matching filter.
func seedRelay(t *testing.T, events ...*nostr.Event) string {
	rl := khatru.NewRelay()
	rl.QueryEvents = append(rl.QueryEvents, func(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		ch := make(chan *nostr.Event, len(events))
		for _, ev := range events {
			if f.Matches(ev) {
				ch <- ev
			}
		}
		close(ch)
		return ch, nil
	})
	srv := httptest.NewServer(rl)
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http")
}

// The apps split the web into layers and rank it by vouches (how many of your
// follows follow someone), and fill the globe as a rebuild finds people. The
// saved graph has to carry both, and the newcomers list must name exactly the
// people the old graph didn't have.
func TestRebuildSavesLayersAndStreamsNewcomers(t *testing.T) {
	owner, a, b, c, d := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	x, y, z := newTestKey(t), newTestKey(t), newTestKey(t)
	relay := seedRelay(t,
		owner.followList(t, a, b, c, d),
		a.followList(t, x, y, z, b),
		b.followList(t, x, y, z),
		c.followList(t, x, z),
		d.followList(t, z),
	)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	path := filepath.Join(t.TempDir(), "wot_cache.json")
	wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), map[string]struct{}{owner.pk: {}},
		[]string{relay}, 3, 3, 5, path, 60)
	// The graph this rebuild replaces already had a and z.
	wt.pubkeys.Store(&map[string]bool{owner.pk: true, a.pk: true, z.pk: true})

	wt.Refresh(ctx)

	if p := CurrentProgress(); p.Phase != "saved" || p.Size != 7 || p.Found != 5+1 || p.New != 4 {
		t.Fatalf("progress %+v: want saved, size 7 (owner, 4 follows, x, z), found 6, new 4", p)
	}
	news, total := Newcomers(0)
	slices.Sort(news)
	want := []string{b.pk, c.pk, d.pk, x.pk}
	slices.Sort(want)
	if total != 4 || !slices.Equal(news, want) {
		t.Fatalf("newcomers %v (total %d), want b, c, d, x", news, total)
	}
	if rest, total := Newcomers(3); len(rest) != 1 || total != 4 {
		t.Fatalf("Newcomers(3) = %v, %d: an app polling with its count gets only the rest", rest, total)
	}
	if rest, _ := Newcomers(9); rest == nil || len(rest) != 0 {
		t.Fatal("polling past the end must be an empty list, not null")
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var saved wotCache
	if err := json.Unmarshal(data, &saved); err != nil {
		t.Fatal(err)
	}
	follows := []string{a.pk, b.pk, c.pk, d.pk}
	slices.Sort(follows)
	if !slices.Equal(saved.Follows, follows) {
		t.Errorf("saved follows %v, want the owner's 4", saved.Follows)
	}
	// y has 2 vouches, under the bar of 3. b is a follow, not web, though a follows b.
	if len(saved.Vouches) != 2 || saved.Vouches[x.pk] != 3 || saved.Vouches[z.pk] != 4 {
		t.Errorf("saved vouches %v, want x:3 z:4 only", saved.Vouches)
	}
	if saved.Pubkeys[y.pk] || !saved.Pubkeys[x.pk] {
		t.Error("pubkeys disagree with the bar of 3")
	}

	reloaded := NewSimpleInMemory(nil, nil, nil, 3, 3, 5, path, 60)
	if ok, _ := reloaded.LoadFromCache(); !ok {
		t.Fatal("saved graph does not load")
	}
	reloaded.SaveCache()
	data, _ = os.ReadFile(path)
	var again wotCache
	_ = json.Unmarshal(data, &again)
	if !slices.Equal(again.Follows, follows) || again.Vouches[x.pk] != 3 {
		t.Error("loading and re-saving the cache dropped its layers")
	}

	// The next rebuild starts a fresh newcomer list.
	if !claimRefresh() {
		t.Fatal("claim refused")
	}
	if _, total := Newcomers(0); total != 0 {
		t.Errorf("a new rebuild kept %d newcomers from the last one", total)
	}
	releaseRefresh("stopped", 0)
}
