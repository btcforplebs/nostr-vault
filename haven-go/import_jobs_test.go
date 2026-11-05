package main

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// First run and the Vault jobs (import_jobs.go): honest status, resume after a
// cut, one job at a time, the API the apps read.

type jobsView struct {
	Account string      `json:"account"`
	Running string      `json:"running"`
	Jobs    []*jobState `json:"jobs"`
}

func readJobs(t *testing.T) jobsView {
	t.Helper()
	var v jobsView
	if err := json.Unmarshal([]byte(importJobsJSON()), &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func (v jobsView) job(name string) *jobState {
	for _, j := range v.Jobs {
		if j.Name == name {
			return j
		}
	}
	return nil
}

// jobsSetup: moveInSetup plus a private jobs file and a fresh runner.
func jobsSetup(t *testing.T, days int, relays ...string) (testKey, DBBackend) {
	t.Helper()
	owner, db := moveInSetup(t, days, relays...)
	path := filepath.Join(t.TempDir(), "import_jobs.json")
	prevPath, prevEnsure := importJobsPath, jobsEnsureSeeds
	importJobsPath = func() string { return path }
	importJobsRunner = jobRunner{}
	t.Cleanup(func() {
		importJobsRunner.wait()
		importJobsPath, jobsEnsureSeeds = prevPath, prevEnsure
		importJobsRunner = jobRunner{}
	})
	return owner, db
}

// goSpawn stands in for a relay cycle's spawn.
func goSpawn(_ string, fn func()) { go fn() }

// runJobAndWait runs name to its end on ctx.
func runJobAndWait(t *testing.T, ctx context.Context, name string, resume bool) {
	t.Helper()
	if got := importJobsRunner.run(ctx, goSpawn, name, resume); got != runStarted {
		t.Fatalf("run %s: %d", name, got)
	}
	importJobsRunner.wait()
}

// Seeds as given: all answer the connect check, or only those in reach.
func seedsAnswer(t *testing.T, reach ...string) {
	t.Helper()
	jobsEnsureSeeds = func() bool {
		r := slices.Clone(reach)
		reachableImportRelays.Store(&r)
		return len(r) > 0
	}
}

// The way in, end to end over real sockets: own notes and current lists from
// a relay that answers, and a seed that doesn't answer is never "done": the
// setup job is partial, with that relay's whole range unread.
func TestJobsSetupNeverSaysDoneWhenASeedDidNotAnswer(t *testing.T) {
	skipWithoutSockets(t)
	noNegentropy(t)
	relay := newFakeMac(t, false, 0)
	dead := "ws://127.0.0.1:1/never"
	owner, db := jobsSetup(t, 400, relay.url, dead)
	seedsAnswer(t, relay.url)
	ctx := context.Background()
	notes := spread(t, owner, 30, 24*time.Hour)
	// A follow list from before the start date: only the current-lists step brings it.
	follows := owner.sign(t, nostr.Event{Kind: nostr.KindFollowList, CreatedAt: nostr.Timestamp(time.Now().AddDate(-3, 0, 0).Unix()), Tags: nostr.Tags{{"p", hexid('f')}}})
	for _, ev := range append(notes, &follows) {
		if err := relay.store.Store.SaveEvent(ctx, ev); err != nil {
			t.Fatal(err)
		}
	}

	runJobAndWait(t, ctx, jobSetup, false)

	if got := count(t, db, owner.pk); got != 31 {
		t.Fatalf("vault has %d of the owner's events, want 30 notes + the follow list", got)
	}
	setup := readJobs(t).job(jobSetup)
	if setup.Status != jobPartial {
		t.Fatalf("setup status %q with a seed that never answered, want partial", setup.Status)
	}
	if len(setup.Unread) != 1 || setup.Unread[0].Relay != dead || setup.Unread[0].Why != "unreachable" {
		t.Fatalf("unread %+v, want the dead seed's whole range", setup.Unread)
	}
	if setup.Stored != 31 || setup.EndedAt == 0 {
		t.Fatalf("stored %d ended %d", setup.Stored, setup.EndedAt)
	}
	if older := readJobs(t).job(jobOlderRelays); older.Cursor[dead] == "" {
		t.Fatalf("the dead seed was not handed to older_relays: %v", older.Cursor)
	}
	// Every seed answering: done.
	seedsAnswer(t, relay.url)
	config.ImportSeedRelays = []string{relay.url}
	runJobAndWait(t, ctx, jobSetup, false)
	if s := readJobs(t).job(jobSetup); s.Status != jobDone || len(s.Unread) != 0 {
		t.Fatalf("all seeds answered: %s %+v", s.Status, s.Unread)
	}
}

// A relay setup couldn't finish is not walked during setup (that's what
// made the way in take minutes): it is handed to older_relays, which reads it
// only when run. Cut mid-run (the relay stopped), older_relays stays
// "running" with its cursor and the next relay start picks it up and
// finishes, with every note.
func TestJobsOlderRelaysResumesAfterACutAndGetsEverything(t *testing.T) {
	noNegentropy(t)
	owner, db := jobsSetup(t, 200, "wss://slow.example")
	seedsAnswer(t, "wss://slow.example")
	prevQuiet := importQuietIdle
	importQuietIdle = 50 * time.Millisecond
	t.Cleanup(func() { importQuietIdle = prevQuiet })
	notes := spread(t, owner, 400, 12*time.Hour) // 200 days
	held := &pagingRelay{held: notes}
	var (
		mu      sync.Mutex
		windows int
		block   atomic.Bool
	)
	prev := importPage
	importPage = func(ctx context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		if f.Until == nil || f.Since == nil || *f.Until-*f.Since > 30*24*3600 {
			return nil, false // a whole-history ask times out: setup can't finish it
		}
		mu.Lock()
		windows++
		mu.Unlock()
		if block.Load() {
			<-ctx.Done() // the relay stops under the run
			return nil, false
		}
		mu.Lock()
		defer mu.Unlock()
		return held.answer(f)
	}
	t.Cleanup(func() { importPage = prev })

	runJobAndWait(t, context.Background(), jobSetup, false)
	v := readJobs(t)
	if s := v.job(jobSetup); s.Status != jobPartial || len(s.Unread) != 1 || s.Unread[0].Why != "slow" {
		t.Fatalf("setup: %s %+v", s.Status, s.Unread)
	}
	if windows != 0 {
		t.Fatalf("setup walked %d windows: the slow relay belongs to older_relays", windows)
	}
	if o := v.job(jobOlderRelays); o.Status != jobNever || len(o.Unread) != 1 || o.Unread[0].Why != "not_read_yet" {
		t.Fatalf("older_relays before its run: %s %+v", o.Status, o.Unread)
	}
	if got := count(t, db, owner.pk); got != 0 {
		t.Fatalf("setup stored %d notes from a relay it couldn't read", got)
	}

	// Run it; stop the relay after a few windows.
	cycle, stop := context.WithCancel(context.Background())
	if got := importJobsRunner.run(cycle, goSpawn, jobOlderRelays, false); got != runStarted {
		t.Fatal(got)
	}
	for deadline := time.Now().Add(10 * time.Second); ; {
		mu.Lock()
		w := windows
		mu.Unlock()
		if w >= 4 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("older_relays asked %d windows in 10 s", w)
		}
		time.Sleep(5 * time.Millisecond)
	}
	block.Store(true)
	stop()
	importJobsRunner.wait()
	cut := readJobs(t).job(jobOlderRelays)
	if cut.Status != jobRunning || cut.Cursor["wss://slow.example"] == "" {
		t.Fatalf("after the cut: %s cursor %v", cut.Status, cut.Cursor)
	}
	partway := count(t, db, owner.pk)
	if partway == 0 || partway == 400 {
		t.Fatalf("the cut should land partway, got %d of 400", partway)
	}

	// The next relay start resumes it from the cursor and finishes.
	block.Store(false)
	mu.Lock()
	windows = 0
	mu.Unlock()
	resumeImportJobs(context.Background(), goSpawn)
	importJobsRunner.wait()
	done := readJobs(t).job(jobOlderRelays)
	if done.Status != jobDone || len(done.Unread) != 0 || len(done.Cursor) != 0 {
		t.Fatalf("after resume: %s unread %+v cursor %v", done.Status, done.Unread, done.Cursor)
	}
	if got := count(t, db, owner.pk); got != 400 {
		t.Fatalf("vault has %d of 400 notes after the resume", got)
	}
	if done.Stored != 400 {
		t.Fatalf("stored %d across the cut and the resume, want 400", done.Stored)
	}
	// What setup handed over is read now: setup is no longer partial for it.
	if s := readJobs(t).job(jobSetup); s.Status != jobDone || len(s.Unread) != 0 {
		t.Fatalf("setup after older_relays finished: %s %+v", s.Status, s.Unread)
	}
}

// replies: a relay that never answers leaves the job partial with its range
// unread (it used to count as complete, Tron background risks 1). Cut while
// that relay hangs, the resumed run skips the relay that already answered.
func TestJobsRepliesSilentRelayIsPartialAndResumeSkipsFinishedRelays(t *testing.T) {
	owner, _ := jobsSetup(t, 30, "wss://good.example", "wss://hangs.example")
	seedsAnswer(t, "wss://good.example", "wss://hangs.example")
	inbox, chat := newTestBackend(t, "inbox"), newTestBackend(t, "chat")
	for _, db := range []DBBackend{inbox, chat} {
		if err := db.Init(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(db.Close)
	}
	savedInbox, savedChat := inboxDB, chatDB
	inboxDB, chatDB = inbox, chat
	t.Cleanup(func() { inboxDB, chatDB = savedInbox, savedChat })
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})
	stranger := newTestKey(t)
	reply := stranger.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "hi", Tags: nostr.Tags{{"p", owner.pk}}})
	prevIdle := importIdleTimeout
	importIdleTimeout = 100 * time.Millisecond
	t.Cleanup(func() { importIdleTimeout = prevIdle })

	var goodAsks atomic.Int32
	var hang atomic.Bool
	prev := importPage
	importPage = func(ctx context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
		if url == "wss://good.example" {
			goodAsks.Add(1)
			if f.Matches(&reply) && f.Until == nil {
				return []*nostr.Event{&reply}, true
			}
			return nil, true
		}
		if hang.Load() {
			<-ctx.Done() // hangs; each relay runs on its own, so the good one still finishes
		}
		return nil, false // silent
	}
	t.Cleanup(func() { importPage = prev })

	runJobAndWait(t, context.Background(), jobReplies, false)
	j := readJobs(t).job(jobReplies)
	if j.Status != jobPartial {
		t.Fatalf("replies with a silent relay: %s, want partial", j.Status)
	}
	if len(j.Unread) != 1 || j.Unread[0].Relay != "wss://hangs.example" || j.Unread[0].Why != "silent" {
		t.Fatalf("unread %+v", j.Unread)
	}
	if j.Stored != 1 {
		t.Fatalf("stored %d replies, want 1", j.Stored)
	}

	// Now the bad relay hangs and the relay stops under the run.
	hang.Store(true)
	cycle, stop := context.WithCancel(context.Background())
	if got := importJobsRunner.run(cycle, goSpawn, jobReplies, false); got != runStarted {
		t.Fatal(got)
	}
	// The good relay takes 3 asks a run (two pages for replies, one for zaps).
	for deadline := time.Now().Add(10 * time.Second); goodAsks.Load() < 6; {
		if time.Now().After(deadline) {
			t.Fatalf("the good relay was asked %d times", goodAsks.Load())
		}
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)
	stop()
	importJobsRunner.wait()
	cut := readJobs(t).job(jobReplies)
	if cut.Status != jobRunning || cut.Cursor["wss://good.example"] != "done" {
		t.Fatalf("after the cut: %s cursor %v", cut.Status, cut.Cursor)
	}
	before := goodAsks.Load()
	hang.Store(false)
	resumeImportJobs(context.Background(), goSpawn)
	importJobsRunner.wait()
	if got := goodAsks.Load(); got != before {
		t.Fatalf("the resumed run asked the finished relay again (%d more)", got-before)
	}
	if r := readJobs(t).job(jobReplies); r.Status != jobPartial || len(r.Unread) != 1 {
		t.Fatalf("resumed: %s %+v (the silent relay is still unread)", r.Status, r.Unread)
	}
}

// The import cycle's result (still used by today's apps) is honest too: a
// tagged relay that never answered makes it partial with that range unread.
func TestImportResultTaggedSilentRelayIsPartial(t *testing.T) {
	owner, _ := jobsSetup(t, 30, "wss://silent.example")
	inbox, chat := newTestBackend(t, "inbox"), newTestBackend(t, "chat")
	for _, db := range []DBBackend{inbox, chat} {
		if err := db.Init(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(db.Close)
	}
	savedInbox, savedChat := inboxDB, chatDB
	inboxDB, chatDB = inbox, chat
	t.Cleanup(func() { inboxDB, chatDB = savedInbox, savedChat })
	_ = owner
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})
	reach := []string{"wss://silent.example"}
	reachableImportRelays.Store(&reach)
	prev := importPage
	importPage = func(context.Context, string, nostr.Filter) ([]*nostr.Event, bool) { return nil, false }
	t.Cleanup(func() { importPage = prev })

	o := newImportOutcome()
	currentImport.Store(o)
	t.Cleanup(func() { currentImport.Store(nil) })
	importTaggedNotes(context.Background())
	status, reason := o.status()
	if status != "partial" || !strings.Contains(reason, "tagged_silent") {
		t.Fatalf("got %s %s, want partial tagged_silent", status, reason)
	}
	if !strings.HasSuffix(o.line(), "unread=1") {
		t.Fatalf("line %q", o.line())
	}
}

// The API the apps call: unknown job, busy, no relay, cancel, and the list
// with every job and its estimate, before anything ran.
func TestJobsAPI(t *testing.T) {
	jobsSetup(t, 30, "wss://a.example")
	prevRun := runJob
	release := make(chan struct{})
	runJob = func(ctx context.Context, _ func(string, func()), name string, res *jobResult) {
		select {
		case <-release:
		case <-ctx.Done():
		}
	}
	t.Cleanup(func() { runJob = prevRun })

	v := readJobs(t)
	if len(v.Jobs) != len(jobOrder) {
		t.Fatalf("%d jobs listed", len(v.Jobs))
	}
	for i, j := range v.Jobs {
		if j.Name != jobOrder[i] || j.Status != jobNever || j.EstSeconds == 0 || j.Unread == nil {
			t.Fatalf("job %d: %+v", i, j)
		}
	}
	if got := importJobsRunner.run(context.Background(), goSpawn, "nope", false); got != runUnknownJob {
		t.Fatalf("unknown job: %d", got)
	}
	dead, cancel := context.WithCancel(context.Background())
	cancel()
	if got := importJobsRunner.run(dead, goSpawn, jobReplies, false); got != runRelayNotReady {
		t.Fatalf("no relay: %d", got)
	}
	if got := importJobsRunner.run(context.Background(), goSpawn, jobReplies, false); got != runStarted {
		t.Fatalf("start: %d", got)
	}
	if got := importJobsRunner.run(context.Background(), goSpawn, jobListHistory, false); got != runBusy {
		t.Fatalf("second job while one runs: %d", got)
	}
	if v := readJobs(t); v.Running != jobReplies || v.job(jobReplies).Status != jobRunning {
		t.Fatalf("while running: %+v", v)
	}
	if importJobsRunner.cancelJob(jobListHistory) != 1 {
		t.Fatal("cancelled a job that isn't running")
	}
	if importJobsRunner.cancelJob(jobReplies) != 0 {
		t.Fatal("couldn't cancel the running job")
	}
	importJobsRunner.wait()
	if j := readJobs(t).job(jobReplies); j.Status != jobCancelled || j.EndedAt == 0 {
		t.Fatalf("after cancel: %+v", j)
	}
	// A cancelled job is not resumed: only a cut one is.
	resumeImportJobs(context.Background(), goSpawn)
	importJobsRunner.wait()
	if j := readJobs(t).job(jobReplies); j.Status != jobCancelled {
		t.Fatalf("a cancelled job ran again on resume: %s", j.Status)
	}
	close(release)
}

// Nothing starts on its own: a relay start resumes only what was cut, and a
// file another account wrote is not this one's.
func TestJobsNothingStartsUnasked(t *testing.T) {
	jobsSetup(t, 30, "wss://a.example")
	ran := map[string]int{}
	var mu sync.Mutex
	prevRun := runJob
	runJob = func(_ context.Context, _ func(string, func()), name string, _ *jobResult) {
		mu.Lock()
		ran[name]++
		mu.Unlock()
	}
	t.Cleanup(func() { runJob = prevRun })

	resumeImportJobs(context.Background(), goSpawn) // no file yet
	runJobAndWait(t, context.Background(), jobSetup, false)
	resumeImportJobs(context.Background(), goSpawn)
	importJobsRunner.wait()
	if fmt.Sprint(ran) != "map[setup:1]" {
		t.Fatalf("ran %v, want setup once (the long items wait for Run)", ran)
	}
	// Mark replies cut, then switch account: the other account's cut is not resumed.
	updateJob(func(f *jobsFile) { f.job(jobReplies).Status = jobRunning })
	config.OwnerPubKey = hexid('9')
	resumeImportJobs(context.Background(), goSpawn)
	importJobsRunner.wait()
	if ran[jobReplies] != 0 {
		t.Fatal("resumed another account's job")
	}
	if v := readJobs(t); v.job(jobReplies).Status != jobNever {
		t.Fatalf("a new account sees the old one's jobs: %+v", v.job(jobReplies))
	}
}

// The relay's web depth on the first-run flow: follows only until the wider
// network job has run; everyone without a jobs file keeps the configured depth.
func TestEffectiveWotDepth(t *testing.T) {
	jobsSetup(t, 30, "wss://a.example")
	config.WotDepth = 3
	if d := effectiveWotDepth(); d != 3 {
		t.Fatalf("no jobs file: depth %d, want the configured 3", d)
	}
	// The first start of the first-run flow, before setup wrote the file.
	t.Setenv(firstRunEnv, "1")
	if d := effectiveWotDepth(); d != 2 {
		t.Fatalf("first-run start, no file yet: depth %d, want 2", d)
	}
	t.Setenv(firstRunEnv, "")
	updateJob(func(f *jobsFile) { f.job(jobSetup).Status = jobDone })
	if d := effectiveWotDepth(); d != 2 {
		t.Fatalf("first run, wider network not run: depth %d, want 2", d)
	}
	updateJob(func(f *jobsFile) { f.job(jobWiderNetwork).Status = jobDone })
	if d := effectiveWotDepth(); d != 3 {
		t.Fatalf("wider network done: depth %d, want 3", d)
	}
}

// A hard kill (jetsam, process death) skips the end-of-run save: the cursor
// must already be on disk as relays finish, or the resume repeats the whole
// run (Tron, PR 1763). Read the file while the run is still going.
func TestJobsCheckpointBeforeTheRunEnds(t *testing.T) {
	noNegentropy(t)
	owner, _ := jobsSetup(t, 200, "wss://slow.example")
	seedsAnswer(t, "wss://slow.example")
	prevEvery := jobCheckpointEvery
	jobCheckpointEvery = 0
	t.Cleanup(func() { jobCheckpointEvery = prevEvery })
	notes := spread(t, owner, 400, 12*time.Hour)
	held := &pagingRelay{held: notes}
	var (
		mu      sync.Mutex
		windows int
	)
	release := make(chan struct{})
	prev := importPage
	importPage = func(ctx context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		if f.Until == nil || f.Since == nil || *f.Until-*f.Since > 30*24*3600 {
			return nil, false
		}
		mu.Lock()
		windows++
		w := windows
		mu.Unlock()
		if w > 3 {
			select { // hangs: the process "dies" here
			case <-release:
			case <-ctx.Done():
			}
			return nil, false
		}
		mu.Lock()
		defer mu.Unlock()
		return held.answer(f)
	}
	t.Cleanup(func() { importPage = prev })

	runJobAndWait(t, context.Background(), jobSetup, false)
	before := readJobs(t).job(jobOlderRelays).Cursor["wss://slow.example"]
	cycle, stop := context.WithCancel(context.Background())
	defer stop()
	if got := importJobsRunner.run(cycle, goSpawn, jobOlderRelays, false); got != runStarted {
		t.Fatal(got)
	}
	var now string
	for deadline := time.Now().Add(10 * time.Second); ; {
		if j := readJobs(t).job(jobOlderRelays); j.Status == jobRunning {
			now = j.Cursor["wss://slow.example"]
		}
		if now != "" && now != before {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("cursor still %q (setup left %q) while the run is going: a kill would start over", now, before)
		}
		time.Sleep(10 * time.Millisecond)
	}
	close(release)
	stop()
	importJobsRunner.wait()
}

// replies: an empty answer to the wide ask is checked with one narrow ask.
// A relay that then hands over a recent note is "empty_unconfirmed", not
// done (Tron, PR 1763); one that is empty there too is done.
func TestJobsRepliesEmptyAnswerIsCheckedNotTrusted(t *testing.T) {
	owner, _ := jobsSetup(t, 30, "wss://wide-empty.example", "wss://really-empty.example")
	seedsAnswer(t, "wss://wide-empty.example", "wss://really-empty.example")
	repliesStores(t)
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})
	stranger := newTestKey(t)
	reply := stranger.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "hi", Tags: nostr.Tags{{"p", owner.pk}}})
	prev := importPage
	importPage = func(_ context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
		narrow := f.Since != nil && time.Since(f.Since.Time()) < 11*24*time.Hour
		if url == "wss://wide-empty.example" && narrow && f.Matches(&reply) {
			return []*nostr.Event{&reply}, true
		}
		return nil, true // every wide ask: an empty answer, with EOSE
	}
	t.Cleanup(func() { importPage = prev })

	runJobAndWait(t, context.Background(), jobReplies, false)
	j := readJobs(t).job(jobReplies)
	if j.Status != jobPartial || len(j.Unread) != 1 || j.Unread[0].Relay != "wss://wide-empty.example" || j.Unread[0].Why != "empty_unconfirmed" {
		t.Fatalf("got %s %+v", j.Status, j.Unread)
	}
	if j.Cursor["wss://really-empty.example"] != "done" || j.Cursor["wss://wide-empty.example"] != "" {
		t.Fatalf("cursor %v", j.Cursor)
	}
}

// replies the follows-only web kept out make the job partial until the
// wider web has run, so it is offered again (Tron, PR 1763).
func TestJobsRepliesKeptOutByAFollowsOnlyWebAreNotDone(t *testing.T) {
	owner, _ := jobsSetup(t, 30, "wss://a.example")
	seedsAnswer(t, "wss://a.example")
	repliesStores(t)
	wot.MarkReady(wot.NewCycle(), stubWot{members: map[string]bool{owner.pk: true}})
	stranger := newTestKey(t)
	mention := stranger.sign(t, nostr.Event{Kind: nostr.KindTextNote, Content: "hey", Tags: nostr.Tags{{"p", owner.pk}}})
	prev := importPage
	importPage = func(_ context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		if f.Until == nil && f.Matches(&mention) {
			return []*nostr.Event{&mention}, true
		}
		return nil, true
	}
	t.Cleanup(func() { importPage = prev })

	runJobAndWait(t, context.Background(), jobReplies, false)
	if j := readJobs(t).job(jobReplies); j.Status != jobPartial || !strings.Contains(j.Reason, "web_of_trust_follows_only") {
		t.Fatalf("follows-only web kept a mention out: %s %q", j.Status, j.Reason)
	}
	updateJob(func(f *jobsFile) { f.job(jobWiderNetwork).Status = jobDone })
	runJobAndWait(t, context.Background(), jobReplies, false)
	if j := readJobs(t).job(jobReplies); j.Status != jobDone {
		t.Fatalf("with the wider web run: %s %q", j.Status, j.Reason)
	}
}

func repliesStores(t *testing.T) {
	t.Helper()
	inbox, chat := newTestBackend(t, "inbox"), newTestBackend(t, "chat")
	for _, db := range []DBBackend{inbox, chat} {
		if err := db.Init(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(db.Close)
	}
	savedInbox, savedChat := inboxDB, chatDB
	inboxDB, chatDB = inbox, chat
	t.Cleanup(func() { inboxDB, chatDB = savedInbox, savedChat })
}
