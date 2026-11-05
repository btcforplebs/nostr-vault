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
// not read (silent, stopped partway, cut by the deadline or a stop); done: the
// relays that answered to the end, which a resumed run can skip.
type taggedReport struct {
	stored, failed int
	timedOut       bool
	unread         []jobRange
	done           []string
}

// importTaggedNotes is the import cycle's tagged step.
func importTaggedNotes(ctx context.Context) {
	rep := importTaggedRun(ctx, importRelays())
	// Honest result (Tron, background risks 1): a relay that never answered,
	// stopped partway or was cut is missing replies, not "complete".
	if o := currentImport.Load(); o != nil {
		for _, u := range rep.unread {
			o.cut("tagged_" + u.Why)
			o.unreadRange(u)
		}
	}
}

// importTaggedRun pulls the owners' tagged notes from relays, each filter
// paged per relay, under importTaggedDeadline.
func importTaggedRun(ctx context.Context, relays []string) (rep taggedReport) {
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

	// keep runs one note at a time (fetchPaged), whichever relay sent it.
	// Same rules as the live inbox (classifyInboxEvent), so a zap is judged
	// by its zapper here too, plus the zaps you sent.
	keep := func(ev *nostr.Event) {
		c := classifyInboxEvent(ctx, ev)
		if !c.accept {
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

	// Per relay, the worst of the two filters decides what is left unread.
	left := map[string]jobRange{}
	note := func(url string, to time.Time, why string) {
		if _, ok := left[url]; ok {
			return
		}
		left[url] = jobRange{Relay: url, From: start.Format(layout), To: to.Format(layout), Why: why}
	}
	filters := []nostr.Filter{{Tags: nostr.TagMap{"p": pTags}}, givenZapsFilter(pTags, nil)}
	ran := 0
	runsafe.Run("importTaggedNotes.fetch", func() {
		for _, f := range filters {
			if ctx.Err() != nil {
				break
			}
			res := fetchPaged(ctx, relays, f, importLaneMaxPages, keep)
			ran++
			reached := func(url string) time.Time {
				if o, ok := res.Oldest[url]; ok {
					return o.Time()
				}
				return time.Now()
			}
			for _, url := range res.Silent {
				note(url, time.Now(), "silent")
			}
			for _, url := range res.Short {
				note(url, reached(url), "stopped_partway")
			}
			for _, url := range res.Cut {
				why := "cut"
				if parent.Err() == nil {
					why = "deadline"
				}
				note(url, reached(url), why)
			}
		}
	})
	if ran < len(filters) {
		// A filter that never ran read nothing from anyone.
		why := "cut"
		if parent.Err() == nil {
			why = "deadline"
		}
		for _, url := range relays {
			note(url, time.Now(), why)
		}
	}
	for _, url := range relays {
		if u, ok := left[url]; ok {
			rep.unread = append(rep.unread, u)
		} else {
			rep.done = append(rep.done, url)
		}
	}
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
