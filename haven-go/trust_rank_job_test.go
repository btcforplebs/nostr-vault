package main

import (
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
		{"fresh full pass", trustrank.State{Hop: 1, FullAt: now.Unix() - 3600}, false, false},
		{"a day old: refresh", trustrank.State{Hop: 1, FullAt: now.Unix() - day - 1}, true, true},
		{"refreshed today", trustrank.State{Hop: 1, FullAt: now.Unix() - 3*day, RefreshAt: now.Unix() - 60}, false, false},
		{"a week: full", trustrank.State{Hop: 1, FullAt: now.Unix() - 7*day, RefreshAt: now.Unix() - 60}, false, true},
		{"cut full pass resumes", trustrank.State{Hop: 2, FullAt: now.Unix() - 60}, false, true},
		{"cut refresh resumes", trustrank.State{Hop: 1, Last: "ab", Refresh: true, FullAt: now.Unix() - 60}, true, true},
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
