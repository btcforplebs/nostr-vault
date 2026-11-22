//go:build !cshared && !(js && wasm)

package main

// Vault jobs the box asks for (One Vault spec E5): run or cancel an import
// job, rebuild the web of trust, and take the block list again. The apps
// call RunImportJobC, CancelImportJobC, RefreshWotC and UpdateBlacklistC;
// the command-line engine on a box has no host to call them, so havend
// (internal/box/routes_jobs.go, routes_access.go) asks through two files in
// the vault folder, the engine's working directory, as Auto-Mirror does:
//
//	box-jobs.json        havend writes: {"import":{"seq":3,"action":"run","job":"replies"},
//	                                     "wot":{"seq":1},"blocklist":{"seq":2}}
//	box-jobs-state.json  the engine writes: what it did with each seq, and
//	                     the trust rebuild's progress
//
// Each area runs once per new seq. The seqs done are saved, so a restart
// neither repeats a request nor drops one written while the engine was down.
// Nothing else writes box-jobs.json, so an engine without havend never acts.
//
// A cut import job is also picked up again at start here, as the apps do on
// every relay start (resumeImportJobs): without it a job a restart cut stayed
// "running" for ever on a box.

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"strings"
	"time"

	"github.com/barrydeen/haven/pkg/wot"
)

const (
	boxJobsFile      = "box-jobs.json"
	boxJobsStateFile = "box-jobs-state.json"
	boxJobsEvery     = 2 * time.Second
)

type boxJobAsk struct {
	Seq    int64  `json:"seq"`
	Action string `json:"action,omitempty"` // import: "run" | "cancel"
	Job    string `json:"job,omitempty"`    // import: the job's name (import_jobs.go jobOrder)
}

type boxJobAsks struct {
	Import    *boxJobAsk `json:"import,omitempty"`
	Wot       *boxJobAsk `json:"wot,omitempty"`
	Blocklist *boxJobAsk `json:"blocklist,omitempty"`
}

// boxJobDone is what the engine did with an area's last seq. Code: import
// run 0 started, 1 unknown job, 2 busy, 3 relay not ready; import cancel 0
// cancelling, 1 not running; wot 0 started (or already running), 1 trust is
// off; blocklist: how many keys it now blocks.
type boxJobDone struct {
	Seq  int64 `json:"seq"`
	Code int   `json:"code"`
	At   int64 `json:"at,omitempty"`
}

type boxJobsState struct {
	Import    boxJobDone   `json:"import"`
	Wot       boxJobDone   `json:"wot"`
	Blocklist boxJobDone   `json:"blocklist"`
	Trust     wot.Progress `json:"trust"`
}

// boxJobs follows box-jobs.json in dir. run/cancel/refresh/blocklist are the
// engine's own calls, swapped in tests.
type boxJobs struct {
	dir       string
	state     boxJobsState
	written   []byte
	run       func(name string) int
	cancel    func(name string) int
	refresh   func() bool
	blocklist func() int
	progress  func() wot.Progress
}

func (b *boxJobs) path(name string) string {
	if b.dir == "" {
		return name
	}
	return b.dir + string(os.PathSeparator) + name
}

func (b *boxJobs) loadState() {
	if raw, err := os.ReadFile(b.path(boxJobsStateFile)); err == nil {
		_ = json.Unmarshal(raw, &b.state)
	}
}

// tick applies every area whose seq is new, then saves the state when it
// changed. False: there is no box-jobs.json (not a box, or nothing asked yet).
func (b *boxJobs) tick() bool {
	raw, err := os.ReadFile(b.path(boxJobsFile))
	if errors.Is(err, os.ErrNotExist) {
		return false
	}
	var asks boxJobAsks
	if err != nil || json.Unmarshal(raw, &asks) != nil {
		if err == nil {
			log.Printf("🚫 %s does not parse; nothing done", boxJobsFile)
		}
		return true
	}
	now := time.Now().Unix()
	if a := asks.Import; a != nil && a.Seq > b.state.Import.Seq {
		code := 1
		switch a.Action {
		case "run":
			code = b.run(strings.TrimSpace(a.Job))
		case "cancel":
			code = b.cancel(strings.TrimSpace(a.Job))
		}
		log.Printf("📥 box asked to %s import job %q: %d", a.Action, a.Job, code)
		b.state.Import = boxJobDone{Seq: a.Seq, Code: code, At: now}
	}
	if a := asks.Wot; a != nil && a.Seq > b.state.Wot.Seq {
		code := 1
		if b.refresh() {
			code = 0
		}
		log.Printf("🔄 box asked for a web of trust rebuild: %d", code)
		b.state.Wot = boxJobDone{Seq: a.Seq, Code: code, At: now}
	}
	if a := asks.Blocklist; a != nil && a.Seq > b.state.Blocklist.Seq {
		n := b.blocklist()
		log.Printf("🚷 box changed the block list: %d blocked", n)
		b.state.Blocklist = boxJobDone{Seq: a.Seq, Code: n, At: now}
	}
	b.state.Trust = b.progress()
	b.save()
	return true
}

func (b *boxJobs) save() {
	body, err := json.Marshal(b.state)
	if err != nil || string(body) == string(b.written) {
		return
	}
	tmp := b.path(boxJobsStateFile + ".tmp")
	if err := os.WriteFile(tmp, body, 0o600); err != nil {
		log.Printf("🚫 %s: %v", boxJobsStateFile, err)
		return
	}
	if err := os.Rename(tmp, b.path(boxJobsStateFile)); err != nil {
		log.Printf("🚫 %s: %v", boxJobsStateFile, err)
		return
	}
	b.written = body
}

// reloadBlocklist reads BLACKLISTED_NPUBS_FILE again into the live block
// list (UpdateBlacklist, as UpdateBlacklistC does) and says how many it holds.
func reloadBlocklist() int {
	keys := getNpubsFromFile(getEnvString("BLACKLISTED_NPUBS_FILE", ""))
	UpdateBlacklist(keys)
	return len(keys)
}

// startBoxJobs picks up cut import jobs and follows box-jobs.json until ctx
// ends. ctx and spawn are the relay's (main.go).
func startBoxJobs(ctx context.Context, spawn func(string, func())) {
	spawn("importJobs.resume", func() { resumeImportJobs(ctx, spawn) })
	b := &boxJobs{
		run:       func(name string) int { return importJobsRunner.run(ctx, spawn, name, false) },
		cancel:    importJobsRunner.cancelJob,
		refresh:   func() bool { return wot.RefreshNow(ctx, wot.GetInstance(), spawn) },
		blocklist: reloadBlocklist,
		progress:  wot.CurrentProgress,
	}
	b.loadState()
	spawn("boxJobs", func() {
		t := time.NewTicker(boxJobsEvery)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				b.tick()
			}
		}
	})
}
