package wot

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

var zNow = time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)

func zpk(i int) string { return fmt.Sprintf("%064x", i) }

func daysAgo(d int) nostr.Timestamp { return nostr.Timestamp(zNow.Unix() - int64(d)*day) }

// fakeRelays answers a filter the way a relay would: by author, kind, since
// and only from the relays the event is on.
type fakeRelays struct {
	events map[string][]*nostr.Event // relay -> events
	asked  []nostr.Filter
}

func (f *fakeRelays) add(relay string, ev *nostr.Event) {
	if f.events == nil {
		f.events = map[string][]*nostr.Event{}
	}
	f.events[relay] = append(f.events[relay], ev)
}

func (f *fakeRelays) fetch(_ context.Context, relays []string, filter nostr.Filter) []*nostr.Event {
	f.asked = append(f.asked, filter)
	var out []*nostr.Event
	for _, r := range relays {
		for _, ev := range f.events[r] {
			if filter.Matches(ev) {
				out = append(out, ev)
			}
		}
	}
	return out
}

func zcheck(f *fakeRelays) ZombieCheck {
	return ZombieCheck{
		Now:    func() time.Time { return zNow },
		Fetch:  f.fetch,
		Relays: []string{"wss://big.example"},
	}
}

func byPubkey(r ZombieReport) map[string]Zombie {
	out := map[string]Zombie{}
	for _, z := range r.Zombies {
		out[z.Pubkey] = z
	}
	return out
}

func TestZombieBucketEdges(t *testing.T) {
	cases := []struct {
		days int
		want string
	}{
		{0, ""}, {89, ""}, {90, BucketFresh}, {179, BucketFresh},
		{180, BucketRotting}, {364, BucketRotting}, {365, BucketAncient}, {3000, BucketAncient},
	}
	for _, c := range cases {
		if got := ZombieBucket(c.days); got != c.want {
			t.Errorf("ZombieBucket(%d) = %q, want %q", c.days, got, c.want)
		}
	}
}

// Through the whole check, someone last seen exactly 89/90/179/180/364/365
// days ago lands in the right bucket, and the counts add up.
func TestZombieRunBucketsAtTheEdges(t *testing.T) {
	f := &fakeRelays{}
	ages := []int{89, 90, 179, 180, 364, 365}
	var follows []string
	for i, d := range ages {
		pk := zpk(i + 1)
		follows = append(follows, pk)
		f.add("wss://big.example", &nostr.Event{ID: zpk(100 + i), PubKey: pk, Kind: 1, CreatedAt: daysAgo(d)})
	}
	r := zcheck(f).Run(context.Background(), zpk(999), follows)
	got := byPubkey(r)
	want := map[int]string{89: "", 90: BucketFresh, 179: BucketFresh, 180: BucketRotting, 364: BucketRotting, 365: BucketAncient}
	for i, d := range ages {
		z, ok := got[zpk(i+1)]
		if want[d] == "" {
			if ok {
				t.Errorf("%d days: listed as %q, should be alive", d, z.Bucket)
			}
			continue
		}
		if !ok || z.Bucket != want[d] || z.Days != d {
			t.Errorf("%d days: got %+v (listed %v), want bucket %q", d, z, ok, want[d])
		}
	}
	if r.Fresh != 2 || r.Rotting != 2 || r.Ancient != 1 || len(r.Zombies) != 5 || r.Follows != 6 {
		t.Errorf("counts fresh/rotting/ancient/listed/follows = %d/%d/%d/%d/%d, want 2/2/1/5/6",
			r.Fresh, r.Rotting, r.Ancient, len(r.Zombies), r.Follows)
	}
}

// Any signed event is alive, whatever its kind: the dry run's misses were
// kinds 30443 and 17, which Plebs vs. Zombies never asks for.
func TestZombieAnyKindIsAlive(t *testing.T) {
	f := &fakeRelays{}
	kinds := []int{30443, 17, 7, 10002, 0, 9735, 31234}
	var follows []string
	for i, k := range kinds {
		pk := zpk(i + 1)
		follows = append(follows, pk)
		f.add("wss://big.example", &nostr.Event{ID: zpk(100 + i), PubKey: pk, Kind: k, CreatedAt: daysAgo(5)})
		// An old note too, so a kind-restricted ask would call them zombies.
		f.add("wss://big.example", &nostr.Event{ID: zpk(200 + i), PubKey: pk, Kind: 1, CreatedAt: daysAgo(400)})
	}
	r := zcheck(f).Run(context.Background(), zpk(999), follows)
	if len(r.Zombies) != 0 {
		t.Fatalf("someone alive by another kind was listed: %+v", r.Zombies)
	}
	for _, flt := range f.asked {
		if len(flt.Kinds) != 0 && !slices.Equal(flt.Kinds, []int{nostr.KindRelayListMetadata}) {
			t.Errorf("an activity ask was limited to kinds %v", flt.Kinds)
		}
	}
}

// Activity on the local store counts too, with no relay asked about them.
func TestZombieLocalActivityIsAlive(t *testing.T) {
	f := &fakeRelays{}
	check := zcheck(f)
	check.Local = func(_ context.Context, authors []string) map[string]Seen {
		return map[string]Seen{zpk(1): {At: int64(daysAgo(2)), Kind: 1111}}
	}
	r := check.Run(context.Background(), zpk(999), []string{zpk(1)})
	if len(r.Zombies) != 0 {
		t.Fatalf("locally active follow listed: %+v", r.Zombies)
	}
	if len(f.asked) != 0 {
		t.Errorf("asked relays %d times about nobody quiet", len(f.asked))
	}
}

// A follow list the web build saw is a floor: it never hides a newer event,
// it never makes someone look quieter than that, and an old one does not
// skip the public check.
func TestZombieFollowListIsAFloor(t *testing.T) {
	f := &fakeRelays{}
	// 1: only an old kind 3 known locally; a recent note sits on the relays.
	f.add("wss://big.example", &nostr.Event{ID: zpk(101), PubKey: zpk(1), Kind: 1, CreatedAt: daysAgo(10)})
	// 2: old kind 3 (200 d) and nothing newer anywhere: bucketed by it, flagged.
	// 3: kind 3 (300 d) but an even older note on the relays: the floor wins.
	f.add("wss://big.example", &nostr.Event{ID: zpk(103), PubKey: zpk(3), Kind: 1, CreatedAt: daysAgo(700)})
	// 4: a kind 3 inside the window is itself a signed event: alive.
	// 5: an old kind 3 floor, and a note newer than it but still old (250 d).
	f.add("wss://big.example", &nostr.Event{ID: zpk(105), PubKey: zpk(5), Kind: 1, CreatedAt: daysAgo(250)})
	check := zcheck(f)
	// 6: a note stored locally (120 d) newer than an old kind 3 floor (400 d).
	check.Local = func(_ context.Context, _ []string) map[string]Seen {
		return map[string]Seen{zpk(6): {At: int64(daysAgo(120)), Kind: 1}}
	}
	check.Floors = map[string]int64{
		zpk(6): int64(daysAgo(400)),
		zpk(1): int64(daysAgo(500)),
		zpk(2): int64(daysAgo(200)),
		zpk(3): int64(daysAgo(300)),
		zpk(4): int64(daysAgo(30)),
		zpk(5): int64(daysAgo(600)),
	}
	r := check.Run(context.Background(), zpk(999), []string{zpk(1), zpk(2), zpk(3), zpk(4), zpk(5), zpk(6)})
	got := byPubkey(r)
	if _, ok := got[zpk(1)]; ok {
		t.Errorf("old kind 3 hid a recent note: %+v", got[zpk(1)])
	}
	if z := got[zpk(2)]; z.Bucket != BucketRotting || !z.Floor || z.Days != 200 || z.Kind != 3 {
		t.Errorf("kind-3-only follow = %+v, want rotting at 200 days, floor", z)
	}
	if z := got[zpk(3)]; z.Days != 300 || !z.Floor {
		t.Errorf("an older note beat the kind 3 floor: %+v", z)
	}
	if _, ok := got[zpk(4)]; ok {
		t.Errorf("kind 3 inside the window should be alive")
	}
	if z := got[zpk(5)]; z.Days != 250 || z.Floor || z.Kind != 1 {
		t.Errorf("a newer note should replace the floor: %+v", z)
	}
	if z := got[zpk(6)]; z.Days != 120 || z.Floor {
		t.Errorf("an older kind 3 floor replaced a newer local note: %+v", z)
	}
}

// The quiet ones' own write relays (NIP-65) are asked: four of the dry run's
// misses were only there.
func TestZombieAsksTheirWriteRelays(t *testing.T) {
	f := &fakeRelays{}
	f.add("wss://big.example", &nostr.Event{ID: zpk(201), PubKey: zpk(1), Kind: nostr.KindRelayListMetadata, CreatedAt: daysAgo(400),
		Tags: nostr.Tags{{"r", "wss://their.example/"}, {"r", "wss://inbox-only.example", "read"}}})
	f.add("wss://their.example", &nostr.Event{ID: zpk(101), PubKey: zpk(1), Kind: 1, CreatedAt: daysAgo(3)})
	f.add("wss://inbox-only.example", &nostr.Event{ID: zpk(102), PubKey: zpk(2), Kind: 1, CreatedAt: daysAgo(3)})
	r := zcheck(f).Run(context.Background(), zpk(999), []string{zpk(1), zpk(2)})
	got := byPubkey(r)
	if _, ok := got[zpk(1)]; ok {
		t.Errorf("activity on their write relay missed")
	}
	if z, ok := got[zpk(2)]; !ok || z.LastSeen != 0 || z.Bucket != BucketAncient {
		t.Errorf("a read-only relay was asked, or nothing-found is not ancient: %+v %v", z, ok)
	}
}

// Longest quiet first; nothing found at all comes first. The owner, repeats
// and malformed keys are not counted.
func TestZombieOrderAndCleanup(t *testing.T) {
	f := &fakeRelays{}
	f.add("wss://big.example", &nostr.Event{ID: zpk(101), PubKey: zpk(1), Kind: 1, CreatedAt: daysAgo(100)})
	f.add("wss://big.example", &nostr.Event{ID: zpk(102), PubKey: zpk(2), Kind: 1, CreatedAt: daysAgo(500)})
	f.add("wss://big.example", &nostr.Event{ID: zpk(103), PubKey: zpk(3), Kind: 1, CreatedAt: daysAgo(200)})
	owner := zpk(999)
	r := zcheck(f).Run(context.Background(), owner, []string{zpk(1), zpk(2), zpk(3), zpk(4), zpk(2), owner, "nope", ""})
	var order []string
	for _, z := range r.Zombies {
		order = append(order, z.Pubkey)
	}
	if want := []string{zpk(4), zpk(2), zpk(3), zpk(1)}; !slices.Equal(order, want) {
		t.Errorf("order = %v, want %v", order, want)
	}
	if r.Follows != 4 {
		t.Errorf("follows = %d, want 4", r.Follows)
	}
}

// The cache: one check at a time per owner, reused for a day, force re-runs.
func TestZombiesCache(t *testing.T) {
	resetZombies()
	defer resetZombies()
	runs := 0
	var pending []func()
	spawn := func(_ string, fn func()) { pending = append(pending, fn) }
	run := func() (ZombieReport, bool) {
		runs++
		return ZombieReport{Owner: "o", CheckedAt: zNow.Unix(), Zombies: []Zombie{}}, true
	}
	if s := Zombies("o", false, zNow, spawn, run); !s.Checking || s.Report != nil {
		t.Fatalf("first read = %+v, want checking with no report", s)
	}
	Zombies("o", false, zNow, spawn, run) // still running: no second check
	if len(pending) != 1 {
		t.Fatalf("started %d checks, want 1", len(pending))
	}
	pending[0]()
	pending = nil
	if s := Zombies("o", false, zNow.Add(23*time.Hour), spawn, run); s.Checking || s.Report == nil || len(pending) != 0 {
		t.Fatalf("within a day = %+v (%d started), want the cached report", s, len(pending))
	}
	if s := Zombies("o", false, zNow.Add(24*time.Hour), spawn, run); !s.Checking || s.Report == nil {
		t.Errorf("a day later = %+v, want a re-check while showing the old report", s)
	}
	pending = nil
	resetZombies()
	run2 := func() (ZombieReport, bool) { return ZombieReport{}, false }
	Zombies("o", true, zNow, spawn, run2)
	pending[0]()
	if s := Zombies("o", false, zNow, func(string, func()) {}, run); s.Report != nil {
		t.Errorf("a failed check left a report: %+v", s)
	}
	_ = runs
}
