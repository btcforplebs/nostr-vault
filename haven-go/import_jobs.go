package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/runsafe"
	"github.com/barrydeen/haven/pkg/wot"
)

// First run and the Vault's "Still to bring in" jobs (Logen 2026-11-05,
// PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md, "Engine API").
//
// They run inside the normal relay cycle, so the vault keeps serving while
// they do: no import mode, no stopped relay. setup is the way in (own notes,
// follow list, current lists); the long items run only when the user taps
// Run, each with its status, last run and what it could not read. A run cut
// by the relay stopping (app killed, suspended, relay restart) is resumed
// from its cursor the next time the relay starts. import_jobs.json keeps all
// of it, per account, next to the databases.

// jobRange: one stretch a run could not read, and why.
type jobRange struct {
	Relay string `json:"relay"`
	From  string `json:"from"` // yyyy-mm-dd
	To    string `json:"to"`   // yyyy-mm-dd
	Why   string `json:"why"`  // unreachable, silent, stopped_partway, slow, deadline, cut, …
}

const (
	jobSetup        = "setup"
	jobReplies      = "replies"
	jobOlderRelays  = "older_relays"
	jobWiderNetwork = "wider_network"
	jobListHistory  = "list_history"
)

// Job status values.
const (
	jobNever     = "never"
	jobRunning   = "running"
	jobDone      = "done"
	jobPartial   = "partial"
	jobFailed    = "failed"
	jobCancelled = "cancelled"
)

// jobOrder: the jobs, in the order a resume runs them and the list shows them.
var jobOrder = []string{jobSetup, jobReplies, jobOlderRelays, jobWiderNetwork, jobListHistory}

// jobEstimates: about how long each takes on a big account (Logen's, 12 mini).
var jobEstimates = map[string]int{
	jobSetup:        11,
	jobReplies:      180,
	jobOlderRelays:  240,
	jobWiderNetwork: 90,
	jobListHistory:  45,
}

// jobState is one job as the apps see it (ImportJobsC) and as the file keeps it.
type jobState struct {
	Name       string     `json:"name"`
	Status     string     `json:"status"`
	StartedAt  int64      `json:"started_at,omitempty"`
	EndedAt    int64      `json:"ended_at,omitempty"`
	Reason     string     `json:"reason,omitempty"`
	Stored     int        `json:"stored"`
	Unread     []jobRange `json:"unread"`
	EstSeconds int        `json:"est_seconds"`
	// Cursor: what a cut run resumes from. replies: relay -> "done";
	// older_relays: relay -> unix seconds it was read down to.
	Cursor map[string]string `json:"cursor,omitempty"`
}

type jobsFile struct {
	Version   int         `json:"version"`
	Account   string      `json:"account"`
	StartDate string      `json:"start_date"`
	Jobs      []*jobState `json:"jobs"`
}

const jobsFileVersion = 1

// importJobsPath: import_jobs.json next to the databases, by absolute path
// (the process directory moves with account switches, Tron background risks).
// Replaced in tests.
var importJobsPath = func() string {
	if db := hostGetenv("DATABASE_PATH"); db != "" {
		return filepath.Join(filepath.Dir(strings.TrimRight(db, "/")), "import_jobs.json")
	}
	if abs, err := filepath.Abs("import_jobs.json"); err == nil {
		return abs
	}
	return "import_jobs.json"
}

// jobsAccount: who the jobs are for. A different account gets a fresh file.
func jobsAccount() string {
	if config.OwnerPubKey != "" {
		return config.OwnerPubKey
	}
	keys := slices.Sorted(maps.Keys(whitelist()))
	return strings.Join(keys, ",")
}

// jobRunner runs one job at a time and owns the file.
type jobRunner struct {
	mu           sync.Mutex
	running      string
	cancel       context.CancelFunc
	userCancel   bool
	done         chan struct{}
	resuming     map[string]bool
	afterRunHook func(name string) // tests
}

var importJobsRunner jobRunner

// Run results (RunImportJobC).
const (
	runStarted       = 0
	runUnknownJob    = 1
	runBusy          = 2
	runRelayNotReady = 3
)

func loadJobsFile() *jobsFile {
	f := &jobsFile{}
	if data, err := os.ReadFile(importJobsPath()); err == nil {
		if json.Unmarshal(data, f) != nil {
			f = &jobsFile{}
		}
	}
	if f.Version != jobsFileVersion || f.Account != jobsAccount() {
		f = &jobsFile{Version: jobsFileVersion, Account: jobsAccount()}
	}
	f.StartDate = config.ImportStartDate
	for _, name := range jobOrder {
		if f.job(name) == nil {
			f.Jobs = append(f.Jobs, &jobState{Name: name, Status: jobNever})
		}
	}
	for _, j := range f.Jobs {
		j.EstSeconds = jobEstimates[j.Name]
		if j.Unread == nil {
			j.Unread = []jobRange{}
		}
	}
	sort.SliceStable(f.Jobs, func(a, b int) bool {
		return slices.Index(jobOrder, f.Jobs[a].Name) < slices.Index(jobOrder, f.Jobs[b].Name)
	})
	return f
}

func (f *jobsFile) job(name string) *jobState {
	for _, j := range f.Jobs {
		if j.Name == name {
			return j
		}
	}
	return nil
}

// jobsFileExists: this account has started the first-run flow (the file is
// only written by a job). Without it nothing here changes how the relay runs.
func jobsFileExists() bool {
	data, err := os.ReadFile(importJobsPath())
	if err != nil {
		return false
	}
	var f jobsFile
	return json.Unmarshal(data, &f) == nil && f.Account == jobsAccount()
}

func saveJobsFile(f *jobsFile) {
	data, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return
	}
	path := importJobsPath()
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		log.Println("🚫 couldn't save import jobs:", err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		log.Println("🚫 couldn't save import jobs:", err)
		_ = os.Remove(tmp)
	}
}

// jobCheckpointEvery: how often a run may save its cursor. Shorter in tests.
var jobCheckpointEvery = 2 * time.Second

// jobsMu guards the file between the runner and readers.
var jobsMu sync.Mutex

// updateJob loads the file, lets fn change it, and saves it.
func updateJob(fn func(f *jobsFile)) *jobsFile {
	jobsMu.Lock()
	defer jobsMu.Unlock()
	f := loadJobsFile()
	fn(f)
	saveJobsFile(f)
	return f
}

// importJobsJSON is ImportJobsC's answer.
func importJobsJSON() string {
	jobsMu.Lock()
	f := loadJobsFile()
	jobsMu.Unlock()
	out := struct {
		Account   string      `json:"account"`
		StartDate string      `json:"start_date"`
		Running   string      `json:"running"`
		Jobs      []*jobState `json:"jobs"`
	}{f.Account, f.StartDate, importJobsRunner.current(), f.Jobs}
	for _, j := range out.Jobs {
		if j.Status == jobRunning && out.Running != j.Name {
			// Cut, waiting for the next relay start to pick it up.
			j.Reason = "will_resume"
		}
	}
	data, _ := json.Marshal(out)
	return string(data)
}

func (r *jobRunner) current() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.running
}

// logJob prints the line the apps' pills read:
//
//	IMPORT_JOB name=<job> status=<status> stored=<n> unread=<n>
func logJob(j *jobState) {
	log.Printf("IMPORT_JOB name=%s status=%s stored=%d unread=%d", j.Name, j.Status, j.Stored, len(j.Unread))
}

// run starts name on ctx (the relay cycle's) through spawn. resume: a cut
// run picking up from its cursor rather than a fresh Run.
func (r *jobRunner) run(ctx context.Context, spawn func(string, func()), name string, resume bool) int {
	if !slices.Contains(jobOrder, name) {
		return runUnknownJob
	}
	if ctx == nil || ctx.Err() != nil {
		return runRelayNotReady
	}
	r.mu.Lock()
	if r.running != "" {
		r.mu.Unlock()
		return runBusy
	}
	jctx, cancel := context.WithCancel(ctx)
	r.running, r.cancel, r.userCancel = name, cancel, false
	done := make(chan struct{})
	r.done = done
	r.mu.Unlock()

	var st jobState
	updateJob(func(f *jobsFile) {
		j := f.job(name)
		// replies' cursor is its progress, so a fresh Run starts over;
		// older_relays' is what is left to read (setup fills it).
		if !resume && name == jobReplies {
			j.Cursor = nil
		}
		j.Status, j.StartedAt, j.EndedAt, j.Reason = jobRunning, time.Now().Unix(), 0, ""
		st = *j
		st.Cursor = maps.Clone(j.Cursor)
		logJob(j)
	})

	spawn("importJob."+name, func() {
		defer close(done)
		defer cancel()
		res := jobResult{cursor: st.Cursor, unread: []jobRange{}}
		if res.cursor == nil {
			res.cursor = map[string]string{}
		}
		var (
			cpMu   sync.Mutex
			cpLast time.Time
		)
		res.checkpoint = func() {
			cpMu.Lock()
			defer cpMu.Unlock()
			if time.Since(cpLast) < jobCheckpointEvery {
				return
			}
			cpLast = time.Now()
			res.cursorMu.Lock()
			cursor := maps.Clone(res.cursor)
			res.cursorMu.Unlock()
			updateJob(func(f *jobsFile) {
				if j := f.job(name); j != nil && j.Status == jobRunning {
					j.Cursor = cursor
				}
			})
		}
		panicked := false
		runsafe.Run("importJob."+name, func() {
			defer func() {
				if p := recover(); p != nil {
					panicked = true
					panic(p)
				}
			}()
			runJob(jctx, spawn, name, &res)
		})
		r.mu.Lock()
		userCancel := r.userCancel
		r.running, r.cancel = "", nil
		r.mu.Unlock()
		updateJob(func(f *jobsFile) {
			j := f.job(name)
			res.cursorMu.Lock()
			j.Cursor = maps.Clone(res.cursor)
			res.cursorMu.Unlock()
			if len(j.Cursor) == 0 {
				j.Cursor = nil
			}
			switch {
			case panicked:
				j.Status, j.Reason = jobFailed, "panic"
			case userCancel:
				j.Status, j.Reason = jobCancelled, "cancelled"
			case jctx.Err() != nil:
				// The relay stopped under it: still "running", so the next
				// relay start resumes it from the cursor.
				j.Status = jobRunning
				j.Stored += res.stored
				j.Unread = res.unread
				logJob(j)
				return
			case res.failReason != "":
				j.Status, j.Reason = jobFailed, res.failReason
			case len(res.unread) > 0 || len(res.partial) > 0:
				j.Status = jobPartial
				j.Reason = strings.Join(res.reasons(), ",")
			default:
				j.Status, j.Reason = jobDone, "ok"
			}
			if resume {
				j.Stored += res.stored
			} else {
				j.Stored = res.stored
			}
			j.Unread = res.unread
			j.EndedAt = time.Now().Unix()
			res.after(f)
			logJob(j)
		})
		if r.afterRunHook != nil {
			r.afterRunHook(name)
		}
		if name == jobSetup {
			r.autoStartWider(ctx, func() int { return r.run(ctx, spawn, jobWiderNetwork, false) })
		}
	})
	return runStarted
}

// cancelJob stops name if it runs: 0 cancelling, 1 not running.
func (r *jobRunner) cancelJob(name string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.running != name || r.cancel == nil {
		return 1
	}
	r.userCancel = true
	r.cancel()
	return 0
}

// wait blocks until the running job (if any) has ended.
func (r *jobRunner) wait() {
	r.mu.Lock()
	done := r.done
	r.mu.Unlock()
	if done != nil {
		<-done
	}
}

// resumeImportJobs is called once per relay start: every job a cut left
// "running" is run again from its cursor, setup first, one after another.
// Nothing that was never asked for starts (Logen: the long items run only on
// Run).
func resumeImportJobs(ctx context.Context, spawn func(string, func())) {
	if !jobsFileExists() {
		return
	}
	jobsMu.Lock()
	f := loadJobsFile()
	jobsMu.Unlock()
	var cut []string
	for _, name := range jobOrder {
		if j := f.job(name); j != nil && j.Status == jobRunning {
			cut = append(cut, name)
		}
	}
	for _, name := range cut {
		if ctx.Err() != nil {
			return
		}
		log.Printf("🔁 picking up %s where it was cut", name)
		for importJobsRunner.run(ctx, spawn, name, true) == runBusy {
			importJobsRunner.wait()
			if ctx.Err() != nil {
				return
			}
		}
		importJobsRunner.wait()
	}
}

// jobResult is what one run reports back to the runner.
type jobResult struct {
	// checkpoint saves the cursor now, throttled: a hard kill (jetsam,
	// process death) skips the end-of-run save, and a resume would then
	// repeat the whole run (Tron, PR 1763). Set by the runner.
	checkpoint func()
	stored     int
	cursorMu   sync.Mutex
	unread     []jobRange
	partial    []string // reasons with no range (e.g. web_of_trust_owners_only)
	failReason string
	cursor     map[string]string
	// after: changes to other jobs once this one ends (setup hands the
	// relays it couldn't finish to older_relays).
	afterFns []func(f *jobsFile)
}

func (r *jobResult) after(f *jobsFile) {
	for _, fn := range r.afterFns {
		fn(f)
	}
}

func (r *jobResult) reasons() []string {
	var out []string
	for _, u := range r.unread {
		if !slices.Contains(out, u.Why) {
			out = append(out, u.Why)
		}
	}
	for _, p := range r.partial {
		if !slices.Contains(out, p) {
			out = append(out, p)
		}
	}
	return out
}

// runJob dispatches one job. Replaced in tests.
var runJob = func(ctx context.Context, spawn func(string, func()), name string, res *jobResult) {
	switch name {
	case jobSetup:
		runSetupJob(ctx, spawn, res)
	case jobReplies:
		runRepliesJob(ctx, res)
	case jobOlderRelays:
		runOlderRelaysJob(ctx, res)
	case jobWiderNetwork:
		runWiderNetworkJob(ctx, res)
	case jobListHistory:
		runListHistoryJob(ctx, res)
	}
}

// jobStart: the import start date, or the epoch if it doesn't parse.
func jobStart() time.Time {
	if t, err := time.Parse(layout, config.ImportStartDate); err == nil {
		return t
	}
	return time.Unix(0, 0).UTC()
}

// jobsEnsureSeeds: ensureImportRelays, replaced in tests.
var jobsEnsureSeeds = ensureImportRelays

// checkSeeds dials the seed relays; every one that doesn't answer is an
// unread range for the whole history (never "done", Tron background risks 9).
func checkSeeds(res *jobResult) bool {
	ok := jobsEnsureSeeds()
	reach := importRelays()
	for _, url := range config.ImportSeedRelays {
		if !slices.Contains(reach, url) {
			res.unread = append(res.unread, jobRange{Relay: url, From: jobStart().Format(layout), To: time.Now().Format(layout), Why: "unreachable"})
		}
	}
	if !ok {
		res.failReason = "no_relay"
	}
	return ok
}

// runSetupJob: the way in. Own notes (NIP-77 first, then each relay paged),
// the follow list and current lists; the relays that couldn't be finished
// are handed to older_relays, not walked here.
func runSetupJob(ctx context.Context, spawn func(string, func()), res *jobResult) {
	if !checkSeeds(res) {
		return
	}
	rep := importOwnerNotesRun(ctx, false)
	res.stored += rep.stored
	if ctx.Err() != nil {
		return
	}
	res.stored += importCurrentLists(ctx, importRelays())
	if ctx.Err() != nil {
		return
	}
	if rep.failed > 0 {
		res.partial = append(res.partial, "notes_failed")
	}
	start := jobStart()
	pending := map[string]string{}
	for _, w := range rep.redo {
		res.unread = append(res.unread, jobRange{Relay: w.url, From: start.Format(layout), To: w.top.Format(layout), Why: "slow"})
		pending[w.url] = strconv.FormatInt(w.top.Unix(), 10)
	}
	// A seed that didn't answer the connect check is retried by older_relays
	// too, over its whole range (Tron nit, PR 1763).
	for _, u := range res.unread {
		if u.Why == "unreachable" {
			pending[u.Relay] = strconv.FormatInt(time.Now().Unix(), 10)
		}
	}
	res.afterFns = append(res.afterFns, func(f *jobsFile) {
		// older_relays reads exactly these, from where each stopped.
		older := f.job(jobOlderRelays)
		older.Cursor = pending
		older.Unread = []jobRange{}
		for _, u := range res.unread {
			if u.Why == "slow" || u.Why == "unreachable" {
				older.Unread = append(older.Unread, jobRange{Relay: u.Relay, From: u.From, To: u.To, Why: "not_read_yet"})
			}
		}
	})
	// The follows web: a fresh vault's WoT names only the owners until the
	// follow list just stored is read. Rebuild it now (follows only, fast;
	// the wider web is its own job).
	if inst := wot.GetInstance(); inst != nil {
		if o, ok := inst.(interface{ NamesOnlyOwners() bool }); ok && o.NamesOnlyOwners() {
			wot.RefreshNow(ctx, inst, spawn)
		}
	}
}

// importCurrentLists: the owners' current lists (follow list, mutes, relays,
// media servers, …), however old: the owner-notes step only reaches back to
// the start date. One request per relay; the store keeps the newest of each.
func importCurrentLists(ctx context.Context, relays []string) int {
	owners := slices.Collect(maps.Keys(whitelist()))
	f := nostr.Filter{Authors: owners, Kinds: historyScanKinds, Limit: importPageLimit}
	keeper := newOwnerKeeper(ctx)
	var (
		mu     sync.Mutex
		stored int
		wg     sync.WaitGroup
	)
	for _, url := range relays {
		wg.Add(1)
		go func(url string) {
			defer wg.Done()
			var evs []*nostr.Event
			runsafe.Run("importCurrentLists", func() { evs, _ = importPage(ctx, url, f) })
			for _, ev := range evs {
				if ev == nil || !f.Matches(ev) {
					continue
				}
				if keeper.keep(ev) {
					mu.Lock()
					stored++
					mu.Unlock()
				}
			}
		}(url)
	}
	wg.Wait()
	if stored > 0 {
		log.Printf("📦 Imported %d of your current lists", stored)
	}
	return stored
}

// runRepliesJob: replies, mentions and zaps since the start date. A resumed
// run skips the relays that already answered to the end.
func runRepliesJob(ctx context.Context, res *jobResult) {
	if !checkSeeds(res) {
		return
	}
	var relays []string
	for _, url := range importRelays() {
		if res.cursor[url] != "done" {
			relays = append(relays, url)
		}
	}
	rep := importTaggedRun(ctx, relays, func(url string) {
		res.cursorMu.Lock()
		res.cursor[url] = "done"
		res.cursorMu.Unlock()
		res.checkpoint()
	})
	res.stored += rep.stored
	res.unread = append(res.unread, rep.unread...)
	if rep.failed > 0 {
		res.partial = append(res.partial, "notes_failed")
	}
	if inst := wot.GetInstance(); inst != nil {
		if o, ok := inst.(interface{ NamesOnlyOwners() bool }); ok && o.NamesOnlyOwners() {
			// Only replies from the owners themselves pass a web this
			// empty: say so, so a later run (after the follows load) is offered.
			res.partial = append(res.partial, "web_of_trust_owners_only")
		}
	}
	// The web kept some out, and it is still the follows-only one: the wider
	// web may let them in, so this is offered again, not "done" (Tron, PR 1763).
	if rep.wotRejected > 0 && !widerNetworkRan() {
		res.partial = append(res.partial, "web_of_trust_follows_only")
		log.Printf("ℹ️ %d replies or mentions from people outside your follows were left out; run Wider network, then Replies again", rep.wotRejected)
	}
}

// widerNetworkRan: the wider_network job has built the full web.
func widerNetworkRan() bool {
	jobsMu.Lock()
	f := loadJobsFile()
	jobsMu.Unlock()
	j := f.job(jobWiderNetwork)
	return j != nil && (j.Status == jobDone || j.Status == jobPartial)
}

// runOlderRelaysJob: the relays setup couldn't finish, read 10 days at a
// time from where each stopped (cursor), down to the start date.
func runOlderRelaysJob(ctx context.Context, res *jobResult) {
	start := jobStart()
	var relays []walkRelay
	for url, v := range res.cursor {
		sec, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			continue
		}
		top := time.Unix(sec, 0)
		if top.After(start) {
			relays = append(relays, walkRelay{url: url, top: top})
		}
	}
	slices.SortFunc(relays, func(a, b walkRelay) int { return strings.Compare(a.url, b.url) })
	if len(relays) == 0 {
		return // nothing left: done
	}
	owners := slices.Collect(maps.Keys(whitelist()))
	keeper := newOwnerKeeper(ctx)
	setTops := func(tops map[string]time.Time) {
		res.cursorMu.Lock()
		defer res.cursorMu.Unlock()
		for url, top := range tops {
			if top.After(start) {
				res.cursor[url] = strconv.FormatInt(top.Unix(), 10)
			} else {
				delete(res.cursor, url)
			}
		}
	}
	rep := &walkReport{progress: func(tops map[string]time.Time) {
		setTops(tops)
		res.checkpoint()
	}}
	res.stored += importOwnerWindowsReport(ctx, relays, start, owners, keeper.keep, rep)
	setTops(rep.tops)
	res.afterFns = append(res.afterFns, func(f *jobsFile) {
		// setup handed these over: what older_relays has now read is no
		// longer setup's to report (Tron nit, PR 1763).
		older, setup := f.job(jobOlderRelays), f.job(jobSetup)
		setup.Unread = slices.DeleteFunc(setup.Unread, func(u jobRange) bool {
			_, left := older.Cursor[u.Relay]
			return (u.Why == "slow" || u.Why == "unreachable") && !left
		})
		if setup.Status == jobPartial && len(setup.Unread) == 0 && strings.Trim(strings.ReplaceAll(strings.ReplaceAll(setup.Reason, "slow", ""), "unreachable", ""), ",") == "" {
			setup.Status, setup.Reason = jobDone, "ok"
		}
	})
	res.unread = append(res.unread, rep.unread...)
	if keeper.failedCount() > 0 {
		res.partial = append(res.partial, "notes_failed")
	}
}

// runWiderNetworkJob: the full web of trust (follows of follows), saved to
// the cache the relay and the apps read, and swapped in for the running one.
func runWiderNetworkJob(ctx context.Context, res *jobResult) {
	// The relay's own first build (no cache yet) must finish first, or it
	// would store its follows-only web over this one (Tron nit, PR 1763).
	wot.WaitReady(ctx)
	if ctx.Err() != nil {
		return
	}
	model := wot.NewSimpleInMemory(
		pool,
		whitelist(),
		config.ImportSeedRelays,
		config.WotDepth,
		config.WotMinimumFollowers,
		config.WotFetchTimeoutSeconds,
		config.WotCachePath,
		config.WotCacheTTLMinutes,
	)
	model.LocalFollowLists = ownerFollowLists
	model.Init(ctx)
	if ctx.Err() != nil {
		return
	}
	if model.NamesOnlyOwners() {
		res.partial = append(res.partial, "no_follow_lists")
		return
	}
	wot.MarkReady(wot.NewCycle(), model)
	res.stored = model.Size()
}

// runListHistoryJob: older versions of the owners' lists, filed for Recover
// a List. The user ran it, so it runs whatever the import's opt-in says.
func runListHistoryJob(ctx context.Context, res *jobResult) {
	owners := slices.Sorted(maps.Keys(whitelist()))
	relays := uniqueRelays(append(append([]string{}, config.ImportSeedRelays...), historyRelays...))
	versions, answered := scanListHistory(ctx, relays, owners, historyScanKinds)
	if ctx.Err() != nil {
		return
	}
	for _, ev := range versions {
		if !isOwnerList(ev) {
			continue
		}
		if added, err := fileImportedVersionAdded(ctx, ev); err == nil && added {
			res.stored++
		}
	}
	if answered < len(relays) {
		res.partial = append(res.partial, fmt.Sprintf("relays_unanswered_%d_of_%d", len(relays)-answered, len(relays)))
	}
}

// firstRunEnv: the app sets it to "1" (SetHavenEnvC) before the first
// StartRelayC(0) of the first-run flow, so the relay's very first start,
// before setup has written import_jobs.json, already keeps to the follows
// web instead of starting the 90 s wider build on its own.
const firstRunEnv = "HAVEN_FIRST_RUN"

// effectiveWotDepth: the depth the relay builds its web at. On the first-run
// flow (a jobs file for this account) the wider web is a job the user runs
// (Logen, answer 2); until it has, the relay keeps to the follows web, which
// takes a second, not 90. Everyone else keeps the configured depth.
func effectiveWotDepth() int {
	if config.WotDepth <= 2 || (!jobsFileExists() && hostGetenv(firstRunEnv) != "1") {
		return config.WotDepth
	}
	jobsMu.Lock()
	f := loadJobsFile()
	jobsMu.Unlock()
	if j := f.job(jobWiderNetwork); j != nil && (j.Status == jobDone || j.Status == jobPartial) {
		return config.WotDepth
	}
	return 2
}
