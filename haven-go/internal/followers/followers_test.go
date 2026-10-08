package followers

import (
	"testing"
	"time"

	"github.com/spf13/afero"
)

const owner = "owner"

func openAt(t *testing.T, fs afero.Fs, now *time.Time) *Ledger {
	t.Helper()
	l, err := open(fs, "followers.json", []string{owner}, func() time.Time { return *now })
	if err != nil {
		t.Fatal(err)
	}
	return l
}

func TestLifecycle(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	fs := afero.NewMemMapFs()
	l := openAt(t, fs, &now)
	seeded := l.owners[owner].SeededAt

	steps := []struct {
		name      string
		follower  string
		createdAt int64
		tags      bool
		want      Change
		advance   time.Duration // clock moves this far before the step
	}{
		{"old list is existing", "old", seeded - 100, true, Existing, 0},
		{"fresh list is new", "alice", seeded + 10, true, New, 0},
		{"republish is refresh", "alice", seeded + 20, true, Refresh, 0},
		{"out-of-order older list ignored", "alice", seeded + 15, false, Ignored, 0},
		{"same list again ignored", "alice", seeded + 20, true, Ignored, 0},
		{"drop owner is unfollow", "alice", seeded + 30, false, Unfollow, 0},
		{"still not following ignored", "alice", seeded + 40, false, Ignored, 0},
		{"quick re-follow is a flap, not news", "alice", seeded + 50, true, Refresh, time.Hour},
		{"flap restored the follow", "alice", seeded + 60, true, Refresh, 0},
		{"drop owner again", "alice", seeded + 70, false, Unfollow, 0},
		{"follow again a week later is returning", "alice", seeded + 70 + int64(flapWindow/time.Second), true, Returning, time.Minute},
		{"stranger without owner ignored", "bob", seeded + 10, false, Ignored, 0},
		{"owner's own list ignored", owner, seeded + 10, true, Ignored, 0},
	}
	for _, s := range steps {
		now = now.Add(s.advance)
		if got := l.ObserveList(owner, s.follower, s.createdAt, s.tags, 100); got != s.want {
			t.Fatalf("%s: got %v want %v", s.name, got, s.want)
		}
	}
	if got := l.ObserveList("someone-else", "alice", seeded+70+int64(flapWindow/time.Second)+10, true, 1); got != Ignored {
		t.Fatalf("unknown owner: got %v", got)
	}

	r := l.owners[owner].Followers["alice"]
	if r.Follows != 2 || !r.Following() || r.FollowedAt != now.Unix() {
		t.Fatalf("alice record: follows=%d following=%v", r.Follows, r.Following())
	}
	if _, ok := l.owners[owner].Followers["bob"]; ok {
		t.Fatal("bob should not be tracked")
	}
	if got := l.SweepTargets(owner); len(got) != 2 || got[0] != "alice" || got[1] != "old" {
		t.Fatalf("Followers = %v", got)
	}
}

func TestPersistKeepsSeedAndState(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	fs := afero.NewMemMapFs()
	l := openAt(t, fs, &now)
	seeded := l.owners[owner].SeededAt
	l.ObserveList(owner, "alice", seeded+10, true, 5)
	if err := l.Flush(); err != nil {
		t.Fatal(err)
	}

	now = now.Add(48 * time.Hour)
	l2 := openAt(t, fs, &now)
	if l2.owners[owner].SeededAt != seeded {
		t.Fatalf("reopen reseeded: %d != %d", l2.owners[owner].SeededAt, seeded)
	}
	// A list made between the original seed and the reopen is still news.
	if got := l2.ObserveList(owner, "carol", seeded+5, true, 5); got != New {
		t.Fatalf("carol after reopen: got %v want new", got)
	}
	if got := l2.ObserveList(owner, "alice", seeded+30, true, 5); got != Refresh {
		t.Fatalf("alice after reopen: got %v want refresh", got)
	}
}

func TestBackfillFlagSurvivesReopen(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	fs := afero.NewMemMapFs()
	l := openAt(t, fs, &now)
	if got := l.NeedsBackfill(); len(got) != 1 || got[0] != owner {
		t.Fatalf("fresh ledger NeedsBackfill = %v", got)
	}
	if err := l.Flush(); err != nil {
		t.Fatal(err)
	}
	// Interrupted first run: reopen still needs it.
	if got := openAt(t, fs, &now).NeedsBackfill(); len(got) != 1 {
		t.Fatalf("after interrupted run NeedsBackfill = %v", got)
	}
	l.MarkBackfilled([]string{owner})
	if err := l.Flush(); err != nil {
		t.Fatal(err)
	}
	if got := openAt(t, fs, &now).NeedsBackfill(); len(got) != 0 {
		t.Fatalf("after backfill NeedsBackfill = %v", got)
	}
}

func TestBeginBackfillReseedsUntilDone(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	l := openAt(t, afero.NewMemMapFs(), &now)
	// First attempt interrupted; three days pass.
	now = now.Add(72 * time.Hour)
	l.BeginBackfill([]string{owner})
	// A long-time follower edited their list yesterday: still old news.
	if got := l.ObserveList(owner, "veteran", now.Add(-24*time.Hour).Unix(), true, 10); got != Existing {
		t.Fatalf("veteran after reseed: got %v want existing", got)
	}
	l.MarkBackfilled([]string{owner})
	seeded := l.owners[owner].SeededAt
	now = now.Add(time.Hour)
	l.BeginBackfill([]string{owner}) // no-op once backfilled
	if l.owners[owner].SeededAt != seeded {
		t.Fatal("BeginBackfill moved the seed after a completed backfill")
	}
}

func TestSweepDuePersists(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	fs := afero.NewMemMapFs()
	l := openAt(t, fs, &now)
	if !l.SweepDue(6 * time.Hour) {
		t.Fatal("never-swept ledger should be due")
	}
	l.MarkSwept()
	if err := l.Flush(); err != nil {
		t.Fatal(err)
	}
	now = now.Add(5 * time.Hour)
	l2 := openAt(t, fs, &now)
	if l2.SweepDue(6 * time.Hour) {
		t.Fatal("sweep 5h ago should not be due after reopen")
	}
	now = now.Add(time.Hour)
	if !l2.SweepDue(6 * time.Hour) {
		t.Fatal("sweep 6h ago should be due")
	}
}

func TestSweepTargetsSkipSpam(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	l := openAt(t, afero.NewMemMapFs(), &now)
	seeded := l.owners[owner].SeededAt
	l.ObserveList(owner, "real", seeded+1, true, 100)
	l.ObserveList(owner, "followbot", seeded+1, true, SpamListSize)
	if got := l.SweepTargets(owner); len(got) != 1 || got[0] != "real" {
		t.Fatalf("SweepTargets = %v", got)
	}
}

func TestCorruptFileStartsOver(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	fs := afero.NewMemMapFs()
	if err := afero.WriteFile(fs, "followers.json", []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	l := openAt(t, fs, &now)
	if l.owners[owner] == nil {
		t.Fatal("owner book missing after corrupt load")
	}
	if err := l.Flush(); err != nil {
		t.Fatal(err)
	}
}

func TestSnapshotTiersAndCounts(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	l := openAt(t, afero.NewMemMapFs(), &now)
	seeded := l.owners[owner].SeededAt

	l.ObserveList(owner, "friend", seeded+1, true, 300)
	l.ObserveList(owner, "newbie", seeded+2, true, 12)
	l.ObserveList(owner, "followbot", seeded+3, true, SpamListSize)
	for i := int64(0); i < SpamChurn24h; i++ {
		l.ObserveList(owner, "churnbot", seeded+10+i, true, 50)
	}
	l.ObserveList(owner, "leaver", seeded+4, true, 40)
	l.ObserveList(owner, "leaver", seeded+5, false, 39)

	snap := l.Snapshot(owner, func(pk string) bool { return pk == "friend" })
	want := Counts{Trusted: 1, Others: 1, Spam: 2, Unfollowed: 1}
	if snap.Counts != want {
		t.Fatalf("counts = %+v want %+v", snap.Counts, want)
	}
	tiers := map[string]Tier{}
	for _, e := range snap.Followers {
		tiers[e.Pubkey] = e.Tier
	}
	if tiers["friend"] != TierTrusted || tiers["newbie"] != TierOther ||
		tiers["followbot"] != TierSpam || tiers["churnbot"] != TierSpam {
		t.Fatalf("tiers = %v", tiers)
	}

	// Churn ages out: a day later the refollow bot is just "other".
	now = now.Add(churnWindow + time.Hour)
	snap = l.Snapshot(owner, func(string) bool { return false })
	for _, e := range snap.Followers {
		if e.Pubkey == "churnbot" && e.Tier != TierOther {
			t.Fatalf("churnbot after a day: %v", e.Tier)
		}
	}
}

// An old follower whose clients disagree about the list (one drops the owner,
// another puts them back) must stay old news, not resurface as a comeback.
func TestFlapKeepsExistingFollowQuiet(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	l := openAt(t, afero.NewMemMapFs(), &now)
	seeded := l.owners[owner].SeededAt
	l.ObserveList(owner, "carol", seeded-100, true, 50)
	before := *l.owners[owner].Followers["carol"]

	for i := int64(1); i <= 10; i++ {
		now = now.Add(30 * time.Minute)
		l.ObserveList(owner, "carol", seeded+2*i, false, 49)
		if got := l.ObserveList(owner, "carol", seeded+2*i+1, true, 50); got != Refresh {
			t.Fatalf("flap %d: got %v want refresh", i, got)
		}
	}
	r := l.owners[owner].Followers["carol"]
	if !r.Existing || r.Follows != 1 || r.FollowedAt != before.FollowedAt || !r.Following() {
		t.Fatalf("flapping follower resurfaced: %+v", *r)
	}
}

// The flap window is the gap between the two lists, not between our reads of
// them: a phone relay can sleep through a week, or catch up a week at once.
func TestFlapWindowUsesListTimes(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	l := openAt(t, afero.NewMemMapFs(), &now)
	seeded := l.owners[owner].SeededAt
	week := int64(flapWindow / time.Second)

	// Dropped and re-added a minute apart, read eight days apart: a flap.
	l.ObserveList(owner, "dave", seeded+10, true, 5)
	l.ObserveList(owner, "dave", seeded+20, false, 4)
	now = now.Add(8 * 24 * time.Hour)
	if got := l.ObserveList(owner, "dave", seeded+80, true, 5); got != Refresh {
		t.Fatalf("minute flap read days apart: got %v want refresh", got)
	}

	// Away nine days, both lists read within a minute: a real comeback.
	l.ObserveList(owner, "erin", seeded+10, true, 5)
	l.ObserveList(owner, "erin", seeded+20, false, 4)
	now = now.Add(time.Minute)
	if got := l.ObserveList(owner, "erin", seeded+20+week+2*24*3600, true, 5); got != Returning {
		t.Fatalf("nine-day absence read at once: got %v want returning", got)
	}
}

// Spam reports the churn tier as well as list size, so a refollow bot with a
// small list is never announced.
func TestSpamCountsChurn(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	l := openAt(t, afero.NewMemMapFs(), &now)
	seeded := l.owners[owner].SeededAt
	l.ObserveList(owner, "frank", seeded+1, true, 10)
	if l.Spam(owner, "frank") {
		t.Fatal("one list is not spam")
	}
	for i := int64(2); i <= SpamChurn24h; i++ {
		l.ObserveList(owner, "frank", seeded+i, true, 10)
	}
	if !l.Spam(owner, "frank") {
		t.Fatal("constant republisher should be spam")
	}
	l.ObserveList(owner, "gina", seeded+1, true, SpamListSize)
	if !l.Spam(owner, "gina") {
		t.Fatal("follow-everyone list should be spam")
	}
	if l.Spam(owner, "nobody") {
		t.Fatal("unknown follower is not spam")
	}
}
