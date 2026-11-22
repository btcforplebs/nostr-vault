package wot

import (
	"context"
	"log/slog"
	"maps"
	"slices"
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/runsafe"
)

// fetchFollowLists is the depth-3 pass's list fetch, moved out of build
// unchanged: it gets the list of everyone in follows, from the stored lists
// (wot_lists.json) plus what the relays say changed, or from the relays in
// full, and hands each list to tally.
//
// It returns the lists, how many of them came from relays, whether the pass
// was incremental, whether the full and the changes fetches were whole, and
// the stored lists' since and fullAt stamps as loaded, for build to move.
func (wt *SimpleInMemory) fetchFollowLists(
	ctx context.Context,
	timeout time.Duration,
	follows []string,
	followIndex map[string]int,
	previous map[string]bool,
	ownersWhole bool,
	eventsAnalysed *atomic.Int64,
	tally func(pk string, l followList),
) (map[string]followList, int, bool, bool, bool, int64, int64) {
	keys := follows
	// Start from the lists the last rebuild kept (wot_lists.json) and ask
	// relays only for what changed since it, plus every list of a follow it
	// has none for. A first build, a graph of just the owners, a week since
	// the last full fetch, or a fetch that never completed asks for them all.
	stored, since, fullAt, haveStored := wt.loadLists()
	incremental := haveStored && since > 0 && hasPeople(previous, wt.WhitelistedPubKeys) &&
		time.Since(time.Unix(fullAt, 0)) < fullListsEvery
	lists := make(map[string]followList, len(follows))
	var fresh, known []string
	for _, pk := range follows {
		if l, ok := stored[pk]; ok && incremental {
			lists[pk] = l
			known = append(known, pk)
		} else {
			fresh = append(fresh, pk)
		}
	}
	type listJob struct {
		authors []string
		since   int64 // 0: every list, not only changes
	}
	var jobs []listJob
	for batch := range slices.Chunk(fresh, listBatchSize) {
		jobs = append(jobs, listJob{authors: batch})
	}
	for batch := range slices.Chunk(known, listBatchSize) {
		jobs = append(jobs, listJob{authors: batch, since: max(since-sinceSlack, 1)})
	}

	slog.Info("🕸️ starting deeper Web of Trust analysis", "total_keys", len(keys), "incremental", incremental, "new_lists", len(fresh), "changed_since", len(known))
	updateProgress(func(p *Progress) {
		p.Phase = "lists"
		p.Batches = len(jobs)
		p.Lists = eventsAnalysed.Load()
	})

	// Every batch is in flight at once (up to maxParallelBatches), and each
	// ends once enough relays have answered (fetchLatestLists). Results are
	// counted here, on this goroutine, as each batch lands.
	type listResult struct {
		job listJob
		got listFetch
	}
	results := make(chan listResult, len(jobs))
	slots := make(chan struct{}, maxParallelBatches)
	run := func(job listJob, relays []string, retry bool) {
		go func() {
			var got listFetch
			// Always answer, even after a panic: the loops below wait for
			// one result per batch.
			defer func() { results <- listResult{job, got} }()
			runsafe.Run("wot.listBatch", func() {
				slots <- struct{}{}
				defer func() { <-slots }()
				wait := timeout
				if retry {
					wait = min(timeout, listRetryWait)
				}
				batchCtx, cancel := context.WithTimeout(ctx, wait)
				defer cancel()
				filter := nostr.Filter{Authors: job.authors, Kinds: []int{nostr.KindFollowList}}
				if job.since > 0 {
					s := nostr.Timestamp(job.since)
					filter.Since = &s
				}
				if retry {
					got = fetchListsFromEvery(batchCtx, wt.Pool, relays, filter)
				} else {
					got = fetchLatestLists(batchCtx, wt.Pool, relays, filter)
				}
			})
		}()
	}
	// An owners' fetch that did not finish leaves the full pass unstamped,
	// like an incomplete batch.
	freshComplete, changesComplete := ownersWhole, true
	incomplete := func(job listJob) {
		if job.since > 0 {
			changesComplete = false
		} else {
			freshComplete = false
		}
	}
	fetched := 0
	merge := func(got listFetch) {
		eventsAnalysed.Add(got.received)
		for pk, ev := range got.lists {
			if _, isFollow := followIndex[pk]; !isFollow {
				continue
			}
			if old, ok := lists[pk]; ok && int64(ev.CreatedAt) <= old.at {
				continue
			}
			lists[pk] = listFromEvent(ev)
			fetched++
			if !incremental {
				tally(pk, lists[pk])
			}
		}
		updateProgress(func(p *Progress) {
			p.BatchesDone++
			p.Lists = eventsAnalysed.Load()
		})
		slog.Info("🕸️ verified identities in community", "count", eventsAnalysed.Load())
	}
	for _, job := range jobs {
		run(job, wt.SeedRelays, false)
	}
	// A quorum may cut the one relay holding a list (a follow's kind 3 is
	// only on the relays it was sent to). Each batch that cut relays asks
	// just those once more, waiting for them: a full batch for the follows
	// still without a list, a changes batch for its whole window, so its
	// since stamp can move.
	type retryJob struct {
		job    listJob
		relays []string
	}
	var retries []retryJob
	for range jobs {
		r := <-results
		merge(r.got)
		if !r.got.complete {
			incomplete(r.job)
			continue
		}
		if len(r.got.cut) == 0 {
			continue
		}
		retry := listJob{since: r.job.since}
		if r.job.since > 0 {
			retry.authors = r.job.authors
		} else {
			for _, pk := range r.job.authors {
				if _, ok := lists[pk]; !ok {
					retry.authors = append(retry.authors, pk)
				}
			}
		}
		if len(retry.authors) > 0 {
			retries = append(retries, retryJob{retry, r.got.cut})
		}
	}
	if len(retries) > 0 {
		updateProgress(func(p *Progress) { p.Batches += len(retries) })
		slog.Info("🕸️ asking the relays a quorum cut", "batches", len(retries))
	}
	for _, r := range retries {
		run(r.job, r.relays, true)
	}
	for range retries {
		r := <-results
		merge(r.got)
		if len(r.got.cut) > 0 {
			incomplete(r.job)
		}
	}
	// Changed lists replace stored ones, so the counts start over from the
	// merged set once everything has landed.
	if incremental {
		for _, pk := range follows {
			if l, ok := lists[pk]; ok {
				tally(pk, l)
			}
		}
	}

	return lists, fetched, incremental, freshComplete, changesComplete, since, fullAt
}

// fetchOwnerLists is build's first fetch, moved out unchanged: every owner's
// own follow list, the newest of what the seed relays and this relay hold.
// whole is false when a relay was cut before it finished.
func (wt *SimpleInMemory) fetchOwnerLists(timeoutCtx context.Context, eventsAnalysed *atomic.Int64) (map[string]*nostr.Event, bool) {
	filter := nostr.Filter{
		Authors: slices.Collect(maps.Keys(wt.WhitelistedPubKeys)),
		Kinds:   []int{nostr.KindFollowList},
	}

	slog.Info("🛜 fetching Nostr events to build WoT")

	// The owners' lists wait for every relay: no quorum cut. Every other
	// list hangs off them, and a first build has no saved web to fall back
	// on if the one relay holding them was cut.
	got := fetchListsFromEvery(timeoutCtx, wt.Pool, wt.SeedRelays, filter)
	ownersWhole := got.whole()
	eventsAnalysed.Add(got.received)
	ownerLists := got.lists
	if wt.LocalFollowLists != nil {
		for _, ev := range wt.LocalFollowLists() {
			if _, owner := wt.WhitelistedPubKeys[ev.PubKey]; !owner || ev.Kind != nostr.KindFollowList {
				continue
			}
			if old, ok := ownerLists[ev.PubKey]; !ok || ev.CreatedAt > old.CreatedAt {
				if !ok {
					eventsAnalysed.Add(1)
				}
				ownerLists[ev.PubKey] = ev
			}
		}
	}
	return ownerLists, ownersWhole
}
