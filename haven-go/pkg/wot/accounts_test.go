package wot

import (
	"context"
	"encoding/json"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

func readAccountWeb(t *testing.T, cachePath, owner string) (accountCache, map[string][]int, bool) {
	t.Helper()
	dir := filepath.Dir(cachePath)
	var c accountCache
	data, err := os.ReadFile(filepath.Join(dir, accountCachePrefix+owner+".json"))
	if err != nil {
		t.Fatalf("no web file for the account: %v", err)
	}
	if err := json.Unmarshal(data, &c); err != nil {
		t.Fatal(err)
	}
	var l wotLinks
	data, err = os.ReadFile(filepath.Join(dir, accountLinksPrefix+owner+".json"))
	if err == nil {
		if err := json.Unmarshal(data, &l); err != nil {
			t.Fatal(err)
		}
	}
	return c, l.Links, err == nil
}

func owners(keys ...testKey) map[string]struct{} {
	out := map[string]struct{}{}
	for _, k := range keys {
		out[k.pk] = struct{}{}
	}
	return out
}

// With one account on the device nothing may change: its own web is the
// pooled web, person for person, vouch for vouch, link for link. Checked for
// a full web and for a new account's widened one (fewer follows than the bar).
func TestOneAccountsOwnWebIsThePooledWeb(t *testing.T) {
	owner, a, b, c, d := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	x, y, z := newTestKey(t), newTestKey(t), newTestKey(t)
	cases := []struct {
		name   string
		bar    int
		events []*nostr.Event
	}{
		{"full web", 3, []*nostr.Event{
			owner.followList(t, a, b, c, d),
			a.followList(t, x, y, z, b, owner),
			b.followList(t, x, y, z),
			c.followList(t, x, z),
			d.followList(t, z),
		}},
		{"new account", 3, []*nostr.Event{
			owner.followList(t, a, b),
			a.followList(t, x, y, b),
			b.followList(t, x, z),
		}},
		{"no bar", 0, []*nostr.Event{
			owner.followList(t, a, b),
			a.followList(t, x, y),
			b.followList(t, x),
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			path := filepath.Join(t.TempDir(), "wot_cache.json")
			wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), owners(owner),
				[]string{seedRelay(t, tc.events...)}, 3, tc.bar, 5, path, 60)
			wt.Refresh(ctx)

			pooled := readGraph(t, path)
			var pooledCache wotCache
			data, _ := os.ReadFile(path)
			_ = json.Unmarshal(data, &pooledCache)
			own, links, haveLinks := readAccountWeb(t, path, owner.pk)
			if len(pooled.pubkeys) < 4 {
				t.Fatalf("fixture: pooled web has only %d people", len(pooled.pubkeys))
			}
			if !maps.Equal(own.Pubkeys, pooled.pubkeys) {
				t.Errorf("own web has %d people, the pooled web %d", len(own.Pubkeys), len(pooled.pubkeys))
			}
			if !maps.Equal(own.Vouches, pooled.vouches) {
				t.Errorf("own vouches %v, pooled %v", own.Vouches, pooled.vouches)
			}
			if !slices.Equal(own.Follows, pooledCache.Follows) {
				t.Errorf("own follows differ from the pooled web's")
			}
			if !haveLinks || !maps.EqualFunc(links, pooled.links, slices.Equal[[]int]) {
				t.Errorf("own links %v, pooled %v", links, pooled.links)
			}
			if own.Version != accountCacheVersion || own.Depth != 3 || own.MinFollowers != tc.bar {
				t.Errorf("file says version %d depth %d bar %d", own.Version, own.Depth, own.MinFollowers)
			}
			for pk := range pooled.pubkeys {
				if !wt.HasFor(ctx, owner.pk, pk) {
					t.Errorf("HasFor refuses someone the pooled web holds")
				}
			}
			if wt.HasFor(ctx, owner.pk, newTestKey(t).pk) {
				t.Error("HasFor lets a stranger in")
			}
		})
	}
}

// Three accounts on one device, each at its own level. Each one's web comes
// from its own follows only: nothing one account follows gets anyone through
// to another. The pooled web (what Has still answers) is unchanged.
func TestEachAccountGetsItsOwnWeb(t *testing.T) {
	main, alt, quiet := newTestKey(t), newTestKey(t), newTestKey(t)
	a, b, c := newTestKey(t), newTestKey(t), newTestKey(t)
	x, shared, viaC := newTestKey(t), newTestKey(t), newTestKey(t)
	relay := seedRelay(t,
		main.followList(t, a, b),
		alt.followList(t, c),
		quiet.followList(t, c), // level 1: its follows must not count
		a.followList(t, x, shared),
		b.followList(t, x),
		c.followList(t, shared, viaC),
	)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	path := filepath.Join(t.TempDir(), "wot_cache.json")
	// The vault's single value is level 3, bar 2. main keeps it; alt is at
	// level 2 and quiet at level 1.
	wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), owners(main, alt, quiet),
		[]string{relay}, 3, 2, 5, path, 60)
	wt.ReachFor = func(owner string) (AccountReach, bool) {
		switch owner {
		case alt.pk:
			return AccountReach{Depth: 2, MinFollowers: 9}, true
		case quiet.pk:
			return AccountReach{Depth: 1}, true
		}
		return AccountReach{}, false
	}
	wt.Refresh(ctx)

	// Pooled, as before: every account's follows, and vouches pooled across
	// them (shared: a is main's follow, c is alt's).
	for name, pk := range map[string]string{"a": a.pk, "c": c.pk, "x": x.pk, "shared": shared.pk} {
		if !wt.Has(ctx, pk) {
			t.Errorf("pooled web lost %s", name)
		}
	}

	check := func(owner testKey, ownerName string, want map[string]bool) {
		t.Helper()
		people := map[string]string{"a": a.pk, "b": b.pk, "c": c.pk, "x": x.pk, "shared": shared.pk, "viaC": viaC.pk,
			"main": main.pk, "alt": alt.pk, "quiet": quiet.pk}
		file, _, _ := readAccountWeb(t, path, owner.pk)
		for name, pk := range people {
			if got := wt.HasFor(ctx, owner.pk, pk); got != want[name] {
				t.Errorf("%s: HasFor(%s) = %v, want %v", ownerName, name, got, want[name])
			}
			if file.Pubkeys[pk] != want[name] {
				t.Errorf("%s's file: %s in = %v, want %v", ownerName, name, file.Pubkeys[pk], want[name])
			}
		}
	}
	own := map[string]bool{"main": true, "alt": true, "quiet": true}
	with := func(names ...string) map[string]bool {
		m := maps.Clone(own)
		for _, n := range names {
			m[n] = true
		}
		return m
	}
	// main, level 3 bar 2: its follows, and x (a and b follow x). shared has
	// one of main's follows, not two: c's vouch is alt's, not main's.
	check(main, "main", with("a", "b", "x"))
	// alt, level 2: c only. Not viaC (no second layer), not main's follows.
	check(alt, "alt", with("c"))
	// quiet, level 1: nobody but your own accounts, which always get through.
	check(quiet, "quiet", own)

	mainFile, mainLinks, haveLinks := readAccountWeb(t, path, main.pk)
	if !haveLinks || len(mainLinks[x.pk]) != 2 || mainFile.Vouches[x.pk] != 2 {
		t.Errorf("main: x should have 2 vouches and 2 links, got %v / %v", mainFile.Vouches, mainLinks)
	}
	altFile, _, altLinks := readAccountWeb(t, path, alt.pk)
	if altLinks || len(altFile.Vouches) != 0 || altFile.Depth != 2 || altFile.MinFollowers != 9 {
		t.Errorf("alt at level 2 should have no links file and no vouches: %+v", altFile)
	}

	// A fresh start reads the same answers back from the files.
	again := NewSimpleInMemory(nostr.NewSimplePool(ctx), owners(main, alt, quiet), nil, 3, 2, 5, path, 60)
	again.ReachFor = wt.ReachFor
	if ok, _ := again.LoadFromCache(); !ok || again.MissingFiles() {
		t.Fatal("saved webs did not load whole")
	}
	if !again.HasFor(ctx, main.pk, x.pk) || again.HasFor(ctx, alt.pk, x.pk) || again.HasFor(ctx, quiet.pk, c.pk) {
		t.Error("loaded webs answer differently from the built ones")
	}

	// alt's level changes: its saved web is another graph, so it is not
	// loaded, the pooled web answers for alt, and a rebuild is due.
	moved := NewSimpleInMemory(nostr.NewSimplePool(ctx), owners(main, alt, quiet), nil, 3, 2, 5, path, 60)
	moved.ReachFor = func(owner string) (AccountReach, bool) {
		if owner == alt.pk {
			return AccountReach{Depth: 3, MinFollowers: 1}, true
		}
		return wt.ReachFor(owner)
	}
	if ok, _ := moved.LoadFromCache(); !ok || !moved.MissingFiles() {
		t.Fatal("a web saved at another level must count as missing")
	}
	if !moved.HasFor(ctx, alt.pk, x.pk) || moved.HasFor(ctx, quiet.pk, x.pk) {
		t.Error("alt (no web loaded) should get the pooled answer; quiet keeps its own")
	}

	// quiet is removed from the device: the next rebuild deletes its files.
	gone := NewSimpleInMemory(nostr.NewSimplePool(ctx), owners(main, alt), []string{relay}, 3, 2, 5, path, 60)
	gone.Refresh(ctx)
	if _, err := os.Stat(filepath.Join(filepath.Dir(path), accountCachePrefix+quiet.pk+".json")); !os.IsNotExist(err) {
		t.Error("a removed account's web file was left behind")
	}
	if _, err := os.Stat(path); err != nil {
		t.Error("the pooled cache must stay")
	}
	// A public relay (level 0) builds nothing, and still clears them.
	altPath := filepath.Join(filepath.Dir(path), accountCachePrefix+alt.pk+".json")
	if _, err := os.Stat(altPath); err != nil {
		t.Fatal("fixture: alt's file should exist")
	}
	NewSimpleInMemory(nil, owners(main), nil, 0, 0, 5, path, 60).Init(ctx)
	if _, err := os.Stat(altPath); !os.IsNotExist(err) {
		t.Error("level 0: a removed account's web file was left behind")
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(path), accountCachePrefix+main.pk+".json")); err != nil {
		t.Error("level 0: the remaining account's file must stay")
	}
}

// An account can be at a higher level than the vault's single value. The
// pooled build then fetches less than that account needs, so the account
// build fetches the rest itself, and the pooled web stays what it was.
func TestAccountAboveTheVaultsLevel(t *testing.T) {
	main, alt := newTestKey(t), newTestKey(t)
	a, b, c, x, y := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	old := nostr.Now() - 3600*48
	for _, vault := range []int{1, 2} {
		relay := newLiveRelay(t,
			main.listAt(t, old, a, b),
			alt.listAt(t, old, c),
			a.listAt(t, old, x),
			b.listAt(t, old, x),
			c.listAt(t, old, y),
		)
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		path := filepath.Join(t.TempDir(), "wot_cache.json")
		wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), owners(main, alt), urls(relay), vault, 2, 5, path, 60)
		wt.ReachFor = func(owner string) (AccountReach, bool) {
			return AccountReach{Depth: 3, MinFollowers: 2}, owner == main.pk
		}
		wt.Refresh(ctx)

		if !wt.HasFor(ctx, main.pk, a.pk) || !wt.HasFor(ctx, main.pk, x.pk) {
			t.Errorf("vault level %d: main at level 3 should hold its follow a and x (2 vouches)", vault)
		}
		if wt.HasFor(ctx, main.pk, y.pk) || wt.HasFor(ctx, main.pk, c.pk) {
			t.Errorf("vault level %d: alt's side leaked into main's web", vault)
		}
		if wt.Has(ctx, x.pk) {
			t.Errorf("vault level %d: the pooled web grew a second layer", vault)
		}
		if got := wt.HasFor(ctx, alt.pk, c.pk); got != (vault == 2) {
			t.Errorf("vault level %d: alt uses the vault's level, HasFor(c) = %v", vault, got)
		}
		lists, since, _, ok := wt.loadLists()
		if !ok || since == 0 || len(lists) != 2 {
			t.Fatalf("vault level %d: want main's 2 follows' lists stored and stamped, got %d (since %d)", vault, len(lists), since)
		}

		// The next rebuild asks only for changes to those lists.
		relay.forget()
		time.Sleep(1100 * time.Millisecond)
		wt.Refresh(ctx)
		for _, f := range relay.asked() {
			if slices.Contains(f.Authors, a.pk) && f.Since == nil {
				t.Errorf("vault level %d: the second rebuild downloaded every list again", vault)
			}
		}
		if !wt.HasFor(ctx, main.pk, x.pk) {
			t.Errorf("vault level %d: x fell out on the incremental rebuild", vault)
		}
		cancel()
	}
}

// A rebuild that reaches no relay keeps each account's web, like the pooled
// one: at vault level 1 the account build does its own fetch.
func TestAccountWebsSurviveAnEmptyFetch(t *testing.T) {
	main, a := newTestKey(t), newTestKey(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	path := filepath.Join(t.TempDir(), "wot_cache.json")
	reach := func(string) (AccountReach, bool) { return AccountReach{Depth: 2}, true }
	wt := NewSimpleInMemory(nostr.NewSimplePool(ctx), owners(main), []string{seedRelay(t, main.followList(t, a))}, 1, 0, 3, path, 60)
	wt.ReachFor = reach
	wt.Refresh(ctx)
	if !wt.HasFor(ctx, main.pk, a.pk) {
		t.Fatal("fixture: main's level-2 web should hold a")
	}
	wt.SeedRelays = []string{seedRelay(t)} // answers, but holds nothing
	wt.Refresh(ctx)
	if !wt.HasFor(ctx, main.pk, a.pk) {
		t.Error("an empty fetch replaced main's web with an empty one")
	}
	if file, _, _ := readAccountWeb(t, path, main.pk); !file.Pubkeys[a.pk] {
		t.Error("an empty fetch rewrote main's file without a")
	}
}

// Before any web per account exists (first start after the update), HasFor
// is the pooled answer, and the level-0 public relay lets everyone in.
func TestHasForWithoutAccountWebs(t *testing.T) {
	ctx := context.Background()
	wt := NewSimpleInMemory(nil, map[string]struct{}{"owner": {}}, nil, 2, 0, 5, "", 60)
	wt.pubkeys.Store(&map[string]bool{"owner": true, "friend": true})
	if !wt.HasFor(ctx, "owner", "friend") || wt.HasFor(ctx, "owner", "stranger") {
		t.Error("with no account webs HasFor must answer like Has")
	}
	open := NewSimpleInMemory(nil, map[string]struct{}{"owner": {}}, nil, 0, 0, 5, "", 60)
	if !open.HasFor(ctx, "owner", "stranger") {
		t.Error("level 0 lets everyone in")
	}
}
