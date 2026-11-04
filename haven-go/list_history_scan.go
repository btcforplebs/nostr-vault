package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Moving in also brings back the owner's older list versions (Logen
// 2026-11-04, Lazarus follow-up; twin of web-vault net/list-history-import.js).
// The notes import (runImport) asks the relays for every version of the
// owner's lists they still hold and files each one the vault doesn't have in
// the import store (fileImportedVersionAdded), where Recover a List finds it
// through /lists. Store only: nothing is signed or published, and nothing
// reaches the outbox, so an old version never becomes the current list.
//
// The scan follows the Lazarus spec (dmnyc/lazarus SPEC.md 0.6.2-draft,
// Scan): the import relays (the owner's own and the defaults) and an archival
// set that keeps full replaceable history; one request per kind per relay with
// a per-relay timeout; every event's signature, author and kind checked
// before it counts or moves a paging cursor; a full page asks again with
// `until` at the oldest one it returned; deduplicated by id. A relay counts as
// answered only on EOSE. The pool answers no AUTH (it has no auth handler), so
// the history relays aren't told the account itself is asking.

// historyRelays: relays observed keeping full replaceable history (Lazarus,
// informative). Configuration, not protocol.
var historyRelays = []string{"wss://hist.nostr.land", "wss://relay.ditto.pub"}

// historyScanKinds: the lists Recover a List handles, and the relay list.
var historyScanKinds = []int{3, 10000, 10003, 10063, 10050, 10006, 10007, 10015, 10001, 10004, 10030, 10002}

const (
	historyScanPage    = 100
	historyScanPages   = 5
	historyScanTimeout = 6 * time.Second
	historyScanSkew    = 15 * time.Minute
	historyScanWorkers = 8
)

// historyAsk asks one relay one filter: its events and whether it answered
// (sent EOSE). Replaced in tests.
var historyAsk = askRelayOnce

// askRelayOnce subscribes on `url`, collects until EOSE, a CLOSED or the
// timeout. Only an EOSE is an answer.
func askRelayOnce(ctx context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
	ctx, cancel := context.WithTimeout(ctx, historyScanTimeout)
	defer cancel()
	relay, err := pool.EnsureRelay(url)
	if err != nil {
		return nil, false
	}
	sub, err := relay.Subscribe(ctx, nostr.Filters{f})
	if err != nil {
		return nil, false
	}
	defer sub.Unsub()
	var out []*nostr.Event
	for {
		select {
		case ev, ok := <-sub.Events:
			if !ok {
				return out, false
			}
			out = append(out, ev)
		case <-sub.EndOfStoredEvents:
			return out, true
		case <-sub.ClosedReason:
			return out, false
		case <-ctx.Done():
			return out, false
		}
	}
}

// ownListVersion: a copy relays can't forge or slip in: `owner`'s, of `kind`,
// validly signed, not dated historyScanSkew or more ahead.
func ownListVersion(ev *nostr.Event, owner string, kind int, now time.Time) bool {
	if ev == nil || ev.PubKey != owner || ev.Kind != kind {
		return false
	}
	if !time.Unix(int64(ev.CreatedAt), 0).Before(now.Add(historyScanSkew)) {
		return false
	}
	ok, err := ev.CheckSignature()
	return err == nil && ok
}

// historyScanResult: what a scan did. found counts versions filed now.
type historyScanResult struct {
	Found, Answered, Asked int
	Skipped                bool // the user stopped the scan (SkipListHistoryScan)
}

// listHistoryOptInEnv: "1" when the user ticked the history scan for this import.
const listHistoryOptInEnv = "HAVEN_IMPORT_LIST_HISTORY"

// historyScanStop cancels the scan that is running, if any.
var historyScanStop atomic.Pointer[context.CancelFunc]

// SkipListHistoryScan stops a running scan; what it found so far is filed.
// Reports whether a scan was running.
func SkipListHistoryScan() bool {
	stop := historyScanStop.Load()
	if stop == nil {
		return false
	}
	log.Println("📜 skipping the rest of the list history scan")
	(*stop)()
	return true
}

// scanListHistory asks every relay for every kind of every owner, pages, and
// returns the valid versions found (each once, newest first) and how many
// relays answered.
func scanListHistory(ctx context.Context, relays, owners []string, kinds []int) ([]*nostr.Event, int) {
	now := time.Now()
	var mu sync.Mutex
	byID := map[string]*nostr.Event{}
	answered := 0
	jobs := make(chan string)
	var wg sync.WaitGroup
	for w := 0; w < historyScanWorkers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for url := range jobs {
				heard := false
				for _, owner := range owners {
					for _, kind := range kinds {
						var until *nostr.Timestamp
						for page := 0; page < historyScanPages; page++ {
							f := nostr.Filter{Kinds: []int{kind}, Authors: []string{owner}, Limit: historyScanPage, Until: until}
							evs, ok := historyAsk(ctx, url, f)
							if !ok {
								break
							}
							heard = true
							var valid []*nostr.Event
							for _, ev := range evs {
								if ownListVersion(ev, owner, kind, now) {
									valid = append(valid, ev)
								}
							}
							mu.Lock()
							for _, ev := range valid {
								if _, seen := byID[ev.ID]; !seen {
									byID[ev.ID] = ev
								}
							}
							mu.Unlock()
							if len(evs) < historyScanPage || len(valid) == 0 {
								break
							}
							oldest := valid[0].CreatedAt
							for _, ev := range valid {
								if ev.CreatedAt < oldest {
									oldest = ev.CreatedAt
								}
							}
							if until != nil && oldest >= *until {
								break // nothing older: exhausted
							}
							until = &oldest // inclusive: the repeat is dropped by id
						}
					}
				}
				if heard {
					mu.Lock()
					answered++
					mu.Unlock()
				}
			}
		}()
	}
	for _, url := range relays {
		jobs <- url
	}
	close(jobs)
	wg.Wait()
	out := make([]*nostr.Event, 0, len(byID))
	for _, ev := range byID {
		out = append(out, ev)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].CreatedAt != out[j].CreatedAt {
			return out[i].CreatedAt > out[j].CreatedAt
		}
		return out[i].ID < out[j].ID
	})
	return out, answered
}

// importListHistory scans for the owners' older list versions and files the
// new ones. It logs one line the apps show at the end of the import
// (RelayLogParser listHistoryNote): the 📜 marker and a plain sentence.
//
// The user chooses (Logen 2026-11-04): the scan runs only when the app set
// listHistoryOptInEnv to "1" (Moving in's "Also look for older versions of my
// lists on history relays" checkbox, off by default). SkipListHistoryScan
// stops it early and the versions found so far are still filed; the import
// carries on either way.
func importListHistory(ctx context.Context) historyScanResult {
	if os.Getenv(listHistoryOptInEnv) != "1" {
		return historyScanResult{}
	}
	log.Println("📜 looking for older versions of your lists")
	scanCtx, stop := context.WithCancel(ctx)
	historyScanStop.Store(&stop)
	defer func() {
		historyScanStop.Store(nil)
		stop()
	}()
	owners := make([]string, 0, len(config.WhitelistedPubKeys))
	for pk := range config.WhitelistedPubKeys {
		owners = append(owners, pk)
	}
	sort.Strings(owners)
	relays := uniqueRelays(append(append([]string{}, importRelays()...), historyRelays...))
	versions, answered := scanListHistory(scanCtx, relays, owners, historyScanKinds)
	res := historyScanResult{Answered: answered, Asked: len(relays), Skipped: scanCtx.Err() != nil && ctx.Err() == nil}
	for _, ev := range versions {
		if !isOwnerList(ev) {
			continue
		}
		if added, err := fileImportedVersionAdded(ctx, ev); err == nil && added {
			res.Found++
		}
	}
	log.Println("📜 " + historyScanLine(res))
	return res
}

// historyScanLine: the plain count (the same words as the web's).
func historyScanLine(r historyScanResult) string {
	switch {
	case r.Answered == 0 && r.Skipped:
		return "Skipped looking for older versions of your lists."
	case r.Answered == 0:
		return "Couldn't reach the relays to look for older versions of your lists."
	case r.Found == 0:
		return "No older versions of your lists found."
	case r.Found == 1:
		return "Found 1 older version of your lists."
	default:
		return fmt.Sprintf("Found %d older versions of your lists.", r.Found)
	}
}

// uniqueRelays: each relay once, in order, by its normalized URL.
func uniqueRelays(urls []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, u := range urls {
		n := nostr.NormalizeURL(u)
		if n == "" || seen[n] {
			continue
		}
		seen[n] = true
		out = append(out, n)
	}
	return out
}
