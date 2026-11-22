package main

// The trust rank crawler (pkg/trustrank), run by the always-on Haven server
// only (Logen 2026-11-21): havend on a box or Pi, the standalone relay, and
// the Mac app while "Run in background" is on and its window is closed.
// Phones never run it. It reads public follow and mute lists one at a time,
// ranks each own account's network out to hop 3, and writes
// wot_rank_<account>.json next to the WoT cache. It signs nothing and
// publishes nothing; the file never leaves this machine in this step.

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/trustrank"
	"github.com/barrydeen/haven/pkg/wot"
)

const (
	trustRankBar      = 15.0               // Tod's pick until Strayhorn sends weights
	trustRankPace     = time.Second        // one list a second
	trustRankCap      = 500 << 20          // list store cap on a server
	trustRankRefresh  = 24 * time.Hour     // ask for changed lists once a day
	trustRankFullPass = 7 * 24 * time.Hour // read everything again weekly
	trustRankIdle     = 5 * time.Minute    // between checks when nothing is due
	trustRankPoll     = 5 * time.Second    // while waiting to be allowed
	trustRankAfterJob = time.Minute        // stay out of the way after real work
)

// trustRankHost is the Mac app's say: 1 while "Run in background" is on and
// the window is closed (SetTrustRankC). The standalone relay never sets it.
var trustRankHost atomic.Bool

// trustRankWanted: whether this process runs the crawler at all.
// TRUST_RANK=off turns it off anywhere; on a phone it is always off.
func trustRankWanted(goos string, env string) bool {
	switch strings.ToLower(strings.TrimSpace(env)) {
	case "off", "0", "false", "no":
		return false
	}
	if goos == "ios" || goos == "android" {
		return false
	}
	return true
}

// trustRankMayRun: allowed right now. In the app library the host's flag
// decides (window closed, background mode on); the CLI is a server and has
// no window. Either way it gives way to an import or a copy, and for a
// minute after one.
func trustRankMayRun(cshared bool, host bool, busy bool, lastBusy, now time.Time) bool {
	if cshared && !host {
		return false
	}
	if busy || now.Sub(lastBusy) < trustRankAfterJob {
		return false
	}
	return true
}

func (r *copyRunner) busy() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.running
}

func realWorkRunning() bool {
	return importJobsRunner.current() != "" || copyRuns.busy()
}

// trustRankAccounts: the accounts ranked here, hex. The signed-in accounts
// (never a watch-only one), or the configured owner.
func trustRankAccounts() []string {
	if a := ownSigningAccounts(); len(a) > 0 {
		return a
	}
	if config.OwnerPubKey != "" {
		return []string{config.OwnerPubKey}
	}
	return nil
}

// ownerPublicMutes: the people on account's own public mute list (kind
// 10000) as stored here. Private mutes are encrypted to the account's key,
// which the engine does not hold; the apps apply them on top.
func ownerPublicMutes(account string) []string {
	if outboxDB == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ch, err := outboxDB.QueryEvents(ctx, nostr.Filter{Kinds: []int{10000}, Authors: []string{account}, Limit: 1})
	if err != nil {
		return nil
	}
	var newest *nostr.Event
	for ev := range ch {
		if newest == nil || ev.CreatedAt > newest.CreatedAt {
			newest = ev
		}
	}
	if newest == nil {
		return nil
	}
	var out []string
	for _, t := range newest.Tags {
		if len(t) >= 2 && t[0] == "p" && len(t[1]) == 64 {
			out = append(out, t[1])
		}
	}
	return out
}

// trustRankDir: next to wot_cache.json.
func trustRankDir() string {
	return filepath.Dir(config.WotCachePath)
}

// runTrustRank is the job: until ctx ends, for each account whose pass is
// due, run it while allowed; a pause keeps the place for next time.
func runTrustRank(ctx context.Context, pool *nostr.SimplePool, cshared bool) {
	if !trustRankWanted(runtime.GOOS, os.Getenv("TRUST_RANK")) {
		return
	}
	dir := trustRankDir()
	store, err := trustrank.OpenStore(filepath.Join(dir, "wot_deep"), trustRankCap)
	if err != nil {
		log.Printf("trust rank: list store: %v", err)
		return
	}
	defer store.Close()
	var lastBusy time.Time
	mayRun := func() bool {
		now := time.Now()
		busy := realWorkRunning()
		if busy {
			lastBusy = now
		}
		return trustRankMayRun(cshared, trustRankHost.Load(), busy, lastBusy, now)
	}
	fetch := &trustrank.RelayFetcher{Pool: pool, Relays: config.ImportSeedRelays}
	for ctx.Err() == nil {
		ran := false
		for _, account := range trustRankAccounts() {
			if ctx.Err() != nil || !mayRun() {
				break
			}
			st := trustrank.LoadState(dir, account)
			refresh, due := trustRankDue(st, time.Now())
			if !due || !cappedRetryDue(account, st, time.Now()) {
				continue
			}
			c := &trustrank.Crawler{
				Store: store, Dir: dir, Owner: account, Fetch: fetch,
				Params: trustrank.DefaultParams(), ParamsVersion: 1, Bar: trustRankBar,
				OwnerBlocks: func() []string { return ownerPublicMutes(account) },
				Wait:        func(context.Context) bool { return mayRun() },
				Pace:        trustRankPace,
			}
			start := time.Now()
			res, err := c.RunPass(ctx, refresh)
			switch {
			case err == trustrank.ErrStopped:
				log.Printf("trust rank: paused for %s…, place kept", account[:8])
			case err != nil:
				log.Printf("trust rank: %s…: %v", account[:8], err)
			default:
				ran = true
				log.Printf("trust rank: %s… ranked %d people in %s (%d lists, %d KB stored)",
					account[:8], len(res.People()), time.Since(start).Round(time.Second), store.Lists(), store.Bytes()>>10)
			}
		}
		wait := trustRankIdle
		if !ran && !mayRun() {
			wait = trustRankPoll
		}
		select {
		case <-ctx.Done():
		case <-time.After(wait):
		}
	}
}

// trustRankDue: whether account's pass is due now, and whether it is a
// refresh (changed lists only) or a full pass. A pass cut halfway is always
// due, of the same kind.
func trustRankDue(st trustrank.State, now time.Time) (refresh, due bool) {
	if st.Hop > 1 || st.Last != "" {
		return st.Refresh, true
	}
	if st.FullAt == 0 || now.Sub(time.Unix(st.FullAt, 0)) >= trustRankFullPass {
		return false, true
	}
	last := max(st.FullAt, st.RefreshAt)
	if now.Sub(time.Unix(last, 0)) >= trustRankRefresh {
		return true, true
	}
	return false, false
}

// A pass that stopped at the store cap has no finished time, so it would be
// due again at once; try it again only once a day.
var trustRankCapped sync.Map // account -> time.Time of the capped pass

func cappedRetryDue(account string, st trustrank.State, now time.Time) bool {
	if !st.Capped {
		trustRankCapped.Delete(account)
		return true
	}
	at, seen := trustRankCapped.LoadOrStore(account, now)
	if seen && now.Sub(at.(time.Time)) >= trustRankRefresh {
		trustRankCapped.Store(account, now)
		return true
	}
	return false
}

// spawnWotJobs starts the app library's WoT refresh ticker and the trust
// rank job (kept here so cshared.go does not grow).
func spawnWotJobs(ctx context.Context, pool *nostr.SimplePool, spawn func(string, func())) {
	spawn("wot.PeriodicRefresh", func() { wot.PeriodicRefresh(ctx, config.WotRefreshInterval) })
	spawn("trustRank", func() { runTrustRank(ctx, pool, true) })
}
