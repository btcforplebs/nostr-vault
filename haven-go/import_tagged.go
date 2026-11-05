package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"maps"
	"runtime/debug"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/runsafe"
	"github.com/barrydeen/haven/pkg/wot"
)

// Moving in's tagged notes: replies, reactions, zaps and messages to the
// owner, and the zaps the owner sent. They used to come from one request per
// filter with no paging, so a relay's answer cap (often its newest 500) was
// all anyone got of years of replies (Tidy import audit, item 3). Now each
// filter is paged per relay, newest first, the same way as the owner's own
// notes (fetchPaged), until a page brings nothing older.

// importTaggedDeadline: when the tagged step gives up, ~15 min (Logen
// 2026-11-05), however IMPORT_TAGGED_NOTES_FETCH_TIMEOUT_SECONDS is set: its
// 120 s default cut a paged pull short, and a larger value let one relay that
// keeps sending hold setup for as long as it liked. A request still ends
// sooner when its relay goes quiet (importIdleTimeout). Shorter in tests.
var importTaggedDeadline = 15 * time.Minute

// taggedReport: what one tagged run did. unread: per relay, what it could
// not read (silent, stopped partway, cut by the deadline or a stop, an empty
// answer it couldn't confirm); done: the relays that answered to the end,
// which a resumed run can skip. wotRejected: notes the web of trust kept
// out (a wider web may let them in).
type taggedReport struct {
	stored, failed int
	wotRejected    int
	timedOut       bool
	unread         []jobRange
	done           []string
}

// importTaggedNotes is the import cycle's tagged step.
func importTaggedNotes(ctx context.Context) {
	rep := importTaggedRun(ctx, importRelays(), nil)
	// Honest result (Tron, background risks 1): a relay that never answered,
	// stopped partway or was cut is missing replies, not "complete".
	if o := currentImport.Load(); o != nil {
		for _, u := range rep.unread {
			o.cut("tagged_" + u.Why)
			o.unreadRange(u)
		}
	}
}

// importTaggedProbeWindow: how far back the check of an empty answer asks.
const importTaggedProbeWindow = 10 * 24 * time.Hour

// importTaggedRun pulls the owners' tagged notes from relays under
// importTaggedDeadline. Each relay runs on its own, both filters paged
// newest first; onDone (may be nil) hears each relay that answered to the
// end, as it does, so a job can save that before a kill.
func importTaggedRun(ctx context.Context, relays []string, onDone func(url string)) (rep taggedReport) {
	timeout := importTaggedDeadline
	parent := ctx
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	wdbInbox := eventstore.RelayWrapper{Store: inboxDB}
	wdbChat := eventstore.RelayWrapper{Store: chatDB}
	pTags := slices.Collect(maps.Keys(config.WhitelistedPubKeys))
	start, err := time.Parse(layout, config.ImportStartDate)
	if err != nil {
		start = time.Unix(0, 0)
	}

	log.Println("📦 importing inbox notes, please wait up to", timeout)

	// The live inbox rules need a web of trust; with none yet (a job run
	// before any WoT, Tron background risks) every check would panic.
	if wot.GetInstance() == nil {
		for _, url := range relays {
			rep.unread = append(rep.unread, jobRange{Relay: url, From: start.Format(layout), To: time.Now().Format(layout), Why: "no_web_of_trust"})
		}
		log.Println("🚫 no web of trust yet; tagged notes not imported")
		return rep
	}

	// keep stores one note at a time, whichever relay sent it. Same rules
	// as the live inbox (classifyInboxEvent), so a zap is judged by its
	// zapper here too, plus the zaps you sent.
	var keepMu sync.Mutex
	keep := func(ev *nostr.Event) {
		keepMu.Lock()
		defer keepMu.Unlock()
		c := classifyInboxEvent(ctx, ev)
		if !c.accept {
			if c.reason == rejectNotInWot {
				rep.wotRejected++
			}
			return
		}
		dbToWrite := wdbInbox
		if c.chat {
			dbToWrite = wdbChat
		}
		if isDeleted(ctx, dbToWrite.Store, ev) {
			slog.Debug("🚫 skipping deleted tagged event", "id", ev.ID)
			return
		}
		if err := dbToWrite.Publish(ctx, *ev); err != nil {
			if !errors.Is(err, eventstore.ErrDupEvent) {
				log.Println("🚫 error importing tagged note", ev.ID, ":", err)
				rep.failed++
			}
			return
		}
		rep.stored++
	}

	filters := []nostr.Filter{{Tags: nostr.TagMap{"p": pTags}}, givenZapsFilter(pTags, nil)}
	var (
		mu sync.Mutex
		wg sync.WaitGroup
	)
	for _, url := range relays {
		wg.Add(1)
		go func(url string) {
			defer wg.Done()
			var left *jobRange
			runsafe.Run("importTaggedNotes.relay", func() { left = importTaggedRelay(ctx, parent, url, filters, start, keep) })
			mu.Lock()
			defer mu.Unlock()
			if left != nil {
				rep.unread = append(rep.unread, *left)
				return
			}
			rep.done = append(rep.done, url)
			if onDone != nil {
				onDone(url)
			}
		}(url)
	}
	wg.Wait()
	slices.SortFunc(rep.unread, func(a, b jobRange) int { return strings.Compare(a.Relay, b.Relay) })
	slices.Sort(rep.done)
	rep.timedOut = ctx.Err() != nil && parent.Err() == nil && errors.Is(context.Cause(ctx), context.DeadlineExceeded)

	switch {
	case rep.timedOut:
		log.Println("🚫 Timeout after", timeout, "while importing tagged notes;", fmt.Sprintf("imported %d tagged notes", rep.stored))
	case len(rep.unread) > 0:
		names := make([]string, len(rep.unread))
		for i, u := range rep.unread {
			names[i] = seedHost(u.Relay) + " (" + u.Why + ")"
		}
		log.Printf("⚠️ %d relay(s) didn't hand over all your tagged notes; older ones from them may be missing: %v", len(rep.unread), names)
		log.Println("📦 imported", rep.stored, "tagged notes")
	default:
		log.Println("📦 imported", rep.stored, "tagged notes")
	}
	if rep.failed > 0 {
		log.Printf("⚠️ Failed to import %d tagged notes", rep.failed)
	}

	log.Println("✅ tagged import complete")
	debug.FreeOSMemory()
	return rep
}

// importTaggedRelay reads every filter from one relay; nil when it answered
// to the end, else what it left unread. An empty first answer is checked
// with one narrow ask (the last 10 days): some relays answer a wide scan
// empty but hand over a narrow one (Tidy, 12 mini 2026-11-05), and such an
// answer is unconfirmed, not "nothing" (Tron, PR 1763).
func importTaggedRelay(ctx, parent context.Context, url string, filters []nostr.Filter, start time.Time, keep func(*nostr.Event)) *jobRange {
	cutWhy := func() string {
		if parent.Err() == nil {
			return "deadline"
		}
		return "cut"
	}
	for _, f := range filters {
		if ctx.Err() != nil {
			return &jobRange{Relay: url, From: start.Format(layout), To: time.Now().Format(layout), Why: cutWhy()}
		}
		res := fetchPaged(ctx, []string{url}, f, importLaneMaxPages, keep)
		reached := time.Now()
		if o, ok := res.Oldest[url]; ok {
			reached = o.Time()
		}
		switch {
		case slices.Contains(res.Cut, url):
			return &jobRange{Relay: url, From: start.Format(layout), To: reached.Format(layout), Why: cutWhy()}
		case slices.Contains(res.Silent, url):
			return &jobRange{Relay: url, From: start.Format(layout), To: time.Now().Format(layout), Why: "silent"}
		case slices.Contains(res.Short, url):
			return &jobRange{Relay: url, From: start.Format(layout), To: reached.Format(layout), Why: "stopped_partway"}
		case slices.Contains(res.Empty, url):
			probe := f
			since := nostr.Timestamp(time.Now().Add(-importTaggedProbeWindow).Unix())
			if probe.Since == nil || *probe.Since < since {
				probe.Since = &since
			}
			probe.Limit = 1
			var evs []*nostr.Event
			runsafe.Run("importTaggedNotes.probe", func() { evs, _ = importPage(ctx, url, probe) })
			for _, ev := range evs {
				if ev != nil && probe.Matches(ev) {
					return &jobRange{Relay: url, From: start.Format(layout), To: time.Now().Format(layout), Why: "empty_unconfirmed"}
				}
			}
		}
	}
	return nil
}
