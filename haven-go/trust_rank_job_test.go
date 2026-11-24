//go:build !(js && wasm)

package main

import (
	"slices"
	"testing"
	"time"

	"github.com/barrydeen/haven/pkg/trustrank"
)

func TestTrustRankNeverOnPhones(t *testing.T) {
	for _, c := range []struct {
		goos, env string
		want      bool
	}{
		{"linux", "", true}, {"darwin", "", true}, {"linux", "off", false}, {"darwin", " OFF ", false},
		{"ios", "", false}, {"android", "", false}, {"ios", "on", false},
	} {
		if got := trustRankWanted(c.goos, c.env); got != c.want {
			t.Errorf("%s %q: %v", c.goos, c.env, got)
		}
	}
}

func TestTrustRankMayRun(t *testing.T) {
	now := time.Now()
	long := now.Add(-time.Hour)
	if trustRankMayRun(true, false, false, long, now) {
		t.Error("the Mac app runs it only when it says so (window closed, background mode on)")
	}
	if !trustRankMayRun(true, true, false, long, now) || !trustRankMayRun(false, false, false, long, now) {
		t.Error("allowed: the Mac with the flag, and the server CLI without one")
	}
	if trustRankMayRun(false, false, true, long, now) {
		t.Error("an import or a copy running comes first")
	}
	if trustRankMayRun(false, false, false, now.Add(-30*time.Second), now) {
		t.Error("and it keeps out of the way for a minute after")
	}
}

func TestTrustRankDue(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	day := int64(24 * 3600)
	cases := []struct {
		name         string
		st           trustrank.State
		refresh, due bool
	}{
		{"never ran", trustrank.State{}, false, true},
		{"fresh full pass", trustrank.State{Hop: 1, FullAt: now.Unix() - 3600, GlobeStep: true}, false, false},
		{"a day old: refresh", trustrank.State{Hop: 1, FullAt: now.Unix() - day - 1, GlobeStep: true}, true, true},
		{"refreshed today", trustrank.State{Hop: 1, FullAt: now.Unix() - 3*day, RefreshAt: now.Unix() - 60, GlobeStep: true}, false, false},
		{"a week: full", trustrank.State{Hop: 1, FullAt: now.Unix() - 7*day, RefreshAt: now.Unix() - 60, GlobeStep: true}, false, true},
		{"cut full pass resumes", trustrank.State{Hop: 2, FullAt: now.Unix() - 60, GlobeStep: true}, false, true},
		{"cut refresh resumes", trustrank.State{Hop: 1, Last: "ab", Refresh: true, FullAt: now.Unix() - 60, GlobeStep: true}, true, true},
		// A checkpoint from before the globe step (build 50): the file has
		// no globe rows, so a full pass is due now, not in a week.
		{"fresh full pass before the globe step: full now", trustrank.State{Hop: 1, FullAt: now.Unix() - 3600}, false, true},
		{"refreshed today before the globe step: full now", trustrank.State{Hop: 1, FullAt: now.Unix() - 3*day, RefreshAt: now.Unix() - 60}, false, true},
		// A cut refresh from before it goes on as a refresh; the full pass
		// comes right after it finishes.
		{"cut refresh before the globe step resumes", trustrank.State{Hop: 1, Last: "ab", Refresh: true, FullAt: now.Unix() - 60}, true, true},
	}
	for _, c := range cases {
		r, d := trustRankDue(c.st, now)
		if r != c.refresh || d != c.due {
			t.Errorf("%s: refresh %v due %v", c.name, r, d)
		}
	}
}

func TestCappedPassRetriedOnceADay(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	st := trustrank.State{Capped: true}
	if cappedRetryDue("acct", st, now) {
		t.Fatal("not again right after the cap")
	}
	if cappedRetryDue("acct", st, now.Add(time.Hour)) {
		t.Fatal("not within the day")
	}
	if !cappedRetryDue("acct", st, now.Add(25*time.Hour)) {
		t.Fatal("once a day")
	}
	if !cappedRetryDue("acct", trustrank.State{}, now) {
		t.Fatal("an uncapped state is always let through")
	}
}

// A capped retry that was paused halfway goes on at once, not a day later
// (Tron #2394 must-fix 2).
func TestPausedCappedRetryResumes(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	capped := trustrank.State{Capped: true}
	if cappedRetryDue("acct2", capped, now) {
		t.Fatal("fresh capped state should be held")
	}
	for _, cut := range []trustrank.State{
		{Capped: true, Hop: 2},
		{Capped: true, Hop: 1, Last: "ab"},
	} {
		if _, due := trustRankDue(cut, now); !due {
			t.Fatalf("%+v not due", cut)
		}
		if !cappedRetryDue("acct2", cut, now.Add(time.Minute)) {
			t.Fatalf("cut capped pass %+v held for a day", cut)
		}
		if retryingCap(cut) {
			t.Fatalf("cut pass %+v counted as a fresh retry", cut)
		}
	}
	if !retryingCap(capped) {
		t.Fatal("fresh capped state is a retry")
	}
}

func TestCappedRetryNeedsHeadroom(t *testing.T) {
	if hasHeadroom(trustRankCap) || hasHeadroom(trustRankCap-trustRankHeadroom+1) {
		t.Fatal("a full store has no headroom")
	}
	if !hasHeadroom(trustRankCap - trustRankHeadroom) {
		t.Fatal("headroom at the line")
	}
}

// damus, nos.lol and nostr.mom never take part in the crawl, whatever the
// owner's relay list says; the rest keep their order.
func TestTrustRankRelaysSkipsHosts(t *testing.T) {
	got := trustRankRelays([]string{"wss://relay.primal.net", "wss://nos.lol/", "wss://Relay.Damus.io",
		"wss://relay.btcforplebs.com", "wss://nostr.mom", "wss://nostr-pub.wellorder.net"})
	want := []string{"wss://relay.primal.net", "wss://relay.btcforplebs.com", "wss://nostr-pub.wellorder.net"}
	if !slices.Equal(got, want) {
		t.Fatalf("got %v", got)
	}
}

// A list of only skipped relays is used as it is, so the rank still builds.
func TestTrustRankRelaysOnlySkippedKeepsList(t *testing.T) {
	in := []string{"wss://relay.damus.io", "wss://nos.lol"}
	if got := trustRankRelays(in); !slices.Equal(got, in) {
		t.Fatalf("got %v", got)
	}
}
