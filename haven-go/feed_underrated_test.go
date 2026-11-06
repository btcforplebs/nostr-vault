package main

import (
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// reactors builds a tally entry: n distinct reactors, each a like.
func dvmReactors(prefix string, n int) map[string]float64 {
	m := make(map[string]float64, n)
	for i := 0; i < n; i++ {
		m[prefix+string(rune('a'+i))] = 1
	}
	return m
}

// anyOneStepOut treats every author as one step out with one vouch.
func anyOneStepOut(string) (int, bool) { return 1, true }

func dvmRank(notes []PopularNote, id string) int {
	for i, n := range notes {
		if n.ID == id {
			return i
		}
	}
	return -1
}

// The point of the feed: a quiet person's one good note beats a busy,
// widely known account's note with more likes.
func TestUnderratedPutsAQuietPersonsGoodNoteFirst(t *testing.T) {
	now := time.Now()
	quiet, busy := dvmPK('q'), dvmPK('b')
	events := []*nostr.Event{
		dvmNote("quiet", quiet, now.Add(-time.Hour)),
		dvmNote("busy", busy, now.Add(-time.Hour)),
	}
	tally := map[string]map[string]float64{"quiet": dvmReactors("r", 4), "busy": dvmReactors("s", 12)}
	in := underratedInputs{
		posts: map[string]int{quiet: 1, busy: 40},
		oneStepOut: func(p string) (int, bool) {
			if p == busy {
				return 300, true
			}
			return 2, true
		},
	}
	got := scoreUnderrated(events, tally, in, now)
	if dvmRank(got, "quiet") != 0 || dvmRank(got, "busy") != 1 {
		t.Fatalf("order %v, want [quiet busy]", dvmIDs(got))
	}
	// Popular orders the same two the other way.
	pop := scoreNotes(events, tally, 2, now)
	if pop[0].ID != "busy" {
		t.Fatalf("popular order %v", dvmIDs(pop))
	}
}

// Measured against the author's own usual: of one person's notes, the one
// that drew more than they usually get ranks first, and a person whose every
// note draws the same scores lift 1 (no bonus for being consistently big).
func TestUnderratedScoresAgainstTheAuthorsUsual(t *testing.T) {
	now := time.Now()
	a := dvmPK('a')
	events := []*nostr.Event{dvmNote("a1", a, now), dvmNote("a2", a, now)}
	tally := map[string]map[string]float64{"a1": dvmReactors("r", 6), "a2": dvmReactors("s", 3)}
	got := scoreUnderrated(events, tally, underratedInputs{posts: map[string]int{a: 10}, oneStepOut: anyOneStepOut}, now)
	if len(got) != 2 || got[0].ID != "a1" {
		t.Fatalf("got %v", dvmIDs(got))
	}
}

func TestUnderratedWeighsBridgedNotes(t *testing.T) {
	now := time.Now()
	a, b := dvmPK('a'), dvmPK('b')
	events := []*nostr.Event{
		dvmNote("native", a, now),
		dvmNote("bridged", b, now, nostr.Tag{"proxy", "https://mastodon.social/@x/1", "activitypub"}),
	}
	tally := map[string]map[string]float64{"native": dvmReactors("r", 3), "bridged": dvmReactors("s", 3)}
	got := scoreUnderrated(events, tally, underratedInputs{oneStepOut: anyOneStepOut}, now)
	if got[0].ID != "bridged" || got[0].Score <= got[1].Score*1.4 {
		t.Fatalf("got %+v", got)
	}
	if isBridged(nostr.Tags{{"proxy", ""}}) || isBridged(nostr.Tags{{"proxy", "x"}}) {
		t.Fatal("a proxy tag needs an id and a protocol")
	}
}

// Popular's defences hold: the author's own like does not count, and two
// trusted reactors are under Popular's bar of three, which a manufactured
// campaign already cleared at two (Tron, #1830).
func TestUnderratedNeedsThreeOtherPeople(t *testing.T) {
	now := time.Now()
	a := dvmPK('a')
	events := []*nostr.Event{dvmNote("self", a, now), dvmNote("two", dvmPK('b'), now)}
	tally := map[string]map[string]float64{
		"self": {a: 3, "r1": 1, "r2": 1},
		"two":  {"r1": 1, "r2": 1},
	}
	if got := scoreUnderrated(events, tally, underratedInputs{oneStepOut: anyOneStepOut}, now); len(got) != 0 {
		t.Fatalf("got %v, want none", dvmIDs(got))
	}
}

func TestUnderratedCapsNotesPerAuthor(t *testing.T) {
	now := time.Now()
	a := dvmPK('a')
	var events []*nostr.Event
	tally := map[string]map[string]float64{}
	for _, id := range []string{"n1", "n2", "n3", "n4"} {
		events = append(events, dvmNote(id, a, now))
		tally[id] = dvmReactors(id, 3)
	}
	if got := scoreUnderrated(events, tally, underratedInputs{oneStepOut: anyOneStepOut}, now); len(got) != underratedMaxPerAuthor {
		t.Fatalf("got %d notes from one author, want %d", len(got), underratedMaxPerAuthor)
	}
}

// A stranger nothing local knows gets no "posts less" boost: feedDB holds
// only follows, so an unknown count is not one post (Tron, #1830).
func TestUnderratedGivesNoPostsBoostToAnUnknownAuthor(t *testing.T) {
	now := time.Now()
	known, stranger := dvmPK('k'), dvmPK('s')
	events := []*nostr.Event{dvmNote("z-known", known, now), dvmNote("a-stranger", stranger, now)}
	tally := map[string]map[string]float64{"z-known": dvmReactors("r", 3), "a-stranger": dvmReactors("s", 3)}
	got := scoreUnderrated(events, tally, underratedInputs{posts: map[string]int{known: 1}, oneStepOut: anyOneStepOut}, now)
	if len(got) != 2 || got[0].ID != "z-known" {
		t.Fatalf("got %+v, want the one-post follow first", got)
	}
}

// Logen 2026-11-06: only people he does not follow, picked from the people
// his follows follow. His own follows and strangers nobody he follows
// follows are left out, however well their notes did.
func TestUnderratedIsOnlyPeopleOneStepOut(t *testing.T) {
	now := time.Now()
	follow, out, stranger := dvmPK('f'), dvmPK('o'), dvmPK('s')
	events := []*nostr.Event{
		dvmNote("follow", follow, now), dvmNote("out", out, now), dvmNote("stranger", stranger, now),
	}
	tally := map[string]map[string]float64{
		"follow": dvmReactors("r", 9), "out": dvmReactors("s", 3), "stranger": dvmReactors("t", 9),
	}
	web := fakeReach{follows: map[string]bool{follow: true}, vouches: map[string]int{out: 2}, known: true}
	got := scoreUnderrated(events, tally, underratedInputs{oneStepOut: oneStepOutFrom(web)}, now)
	if len(got) != 1 || got[0].ID != "out" {
		t.Fatalf("got %v, want [out]", dvmIDs(got))
	}
	// A graph that can't tell (no vouch counts), or none at all: nobody.
	if got := scoreUnderrated(events, tally, underratedInputs{oneStepOut: oneStepOutFrom(fakeReach{})}, now); len(got) != 0 {
		t.Fatalf("unknown graph: got %v", dvmIDs(got))
	}
	if got := scoreUnderrated(events, tally, underratedInputs{}, now); len(got) != 0 {
		t.Fatalf("no graph: got %v", dvmIDs(got))
	}
}

type fakeReach struct {
	follows map[string]bool
	vouches map[string]int
	known   bool
}

func (f fakeReach) Reach(pk string) (int, bool, bool) {
	if f.follows[pk] {
		return 0, true, true
	}
	return f.vouches[pk], false, f.known
}
