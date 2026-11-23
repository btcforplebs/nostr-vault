//go:build !(js && wasm)

package main

// Distant posts (discovery engine, design B): the always-on Haven fetches
// the recent posts of each own account's top distant connections (hop 3+,
// trustrank.Distant) into its feed store, where the age prune keeps them
// to the feed window. Paired devices get them over the mesh during the
// copy catch-up (copyv2_distant.go). It runs only where and when the trust
// rank crawler may run, signs nothing and publishes nothing.

import (
	"context"
	"log/slog"
	"runtime"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/trustrank"
)

const (
	distantPostsEvery   = 30 * time.Minute // between rounds
	distantPostsMax     = 2000             // events kept per account per round
	distantPostsTimeout = 30 * time.Second // per round's fetch, per account
)

// distantPick caches each account's distant list by the result's builtAt,
// so a catch-up asks only for the file's header when nothing changed.
var distantPick = struct {
	sync.Mutex
	built   map[string]int64
	authors map[string][]string
}{built: map[string]int64{}, authors: map[string][]string{}}

// distantAuthors: account's top distant connections from the result file
// in dir, less its public mutes. nil when there is no readable result.
func distantAuthors(dir, account string) []string {
	built, err := trustrank.ResultBuiltAt(dir, account)
	if err != nil {
		return nil
	}
	key := dir + "|" + account
	distantPick.Lock()
	if distantPick.built[key] == built {
		out := distantPick.authors[key]
		distantPick.Unlock()
		return out
	}
	distantPick.Unlock()
	f, err := trustrank.ReadResult(dir, account)
	if err != nil {
		return nil
	}
	skip := map[string]bool{}
	for _, pk := range ownerPublicMutes(account) {
		skip[pk] = true
	}
	out := f.Distant(trustrank.DistantMax, skip)
	distantPick.Lock()
	distantPick.built[key], distantPick.authors[key] = f.BuiltAt, out
	distantPick.Unlock()
	return out
}

// distantSince: the start of the feed window. Every round asks for the
// whole window: on Logen's map that is about 400 notes, under 1 MB, so a
// watermark would save little and lose posts when relays are down.
func distantSince(now time.Time) int64 {
	return now.Add(-time.Duration(config.FeedSyncWindowDays) * 24 * time.Hour).Unix()
}

// fetchDistantPosts asks the seed relays for authors' feed notes since
// since and keeps them in feedDB. Returns how many were new.
func fetchDistantPosts(ctx context.Context, pool *nostr.SimplePool, authors []string, since int64) int {
	relays := config.ImportSeedRelays
	if pool == nil || feedDB == nil || len(authors) == 0 || len(relays) == 0 {
		return 0
	}
	fetchCtx, cancel := context.WithTimeout(ctx, distantPostsTimeout)
	defer cancel()
	ts := nostr.Timestamp(since)
	filter := nostr.Filter{Kinds: feedPullKinds(), Authors: authors, Since: &ts, Limit: 500}
	allowed := make(map[string]bool, len(authors))
	for _, pk := range authors {
		allowed[pk] = true
	}
	seen, kept, now := map[string]bool{}, 0, time.Now()
	for ev := range pool.FetchMany(fetchCtx, relays, filter) {
		if ev.Event == nil || seen[ev.ID] || !allowed[ev.PubKey] {
			continue
		}
		seen[ev.ID] = true
		if len(seen) > distantPostsMax {
			break
		}
		// importOne checks the id and signature, refuses deleted notes and
		// applies a kind 5 to the author's own notes.
		if importOne(ctx, feedDB, ev.Event, now) == restoreStored {
			kept++
		}
	}
	return kept
}

// runDistantPosts is the job: every distantPostsEvery, for each own account
// with a result, fetch its distant connections' posts while allowed.
func runDistantPosts(ctx context.Context, pool *nostr.SimplePool, cshared bool) {
	if !trustRankWanted(runtime.GOOS, hostGetenv("TRUST_RANK")) {
		return
	}
	dir := trustRankDir()
	var lastBusy time.Time
	for ctx.Err() == nil {
		now := time.Now()
		busy := realWorkRunning()
		if busy {
			lastBusy = now
		}
		wait := distantPostsEvery
		if trustRankMayRun(cshared, trustRankHost.Load(), busy, lastBusy, now) {
			for _, account := range trustRankAccounts() {
				authors := distantAuthors(dir, account)
				if len(authors) == 0 || ctx.Err() != nil {
					continue
				}
				kept := fetchDistantPosts(ctx, pool, authors, distantSince(time.Now()))
				slog.Info("distant posts fetched", "account", account[:8], "people", len(authors), "new", kept)
			}
		} else {
			wait = trustRankPoll
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}
