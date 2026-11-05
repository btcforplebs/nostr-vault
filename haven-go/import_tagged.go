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

func importTaggedNotes(ctx context.Context) {
	timeout := importTaggedDeadline
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	wdbInbox := eventstore.RelayWrapper{Store: inboxDB}
	wdbChat := eventstore.RelayWrapper{Store: chatDB}
	pTags := slices.Collect(maps.Keys(config.WhitelistedPubKeys))

	log.Println("📦 importing inbox notes, please wait up to", timeout)

	stored, failed := 0, 0
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
				failed++
			}
			return
		}
		stored++
	}

	var short []string
	runsafe.Run("importTaggedNotes.fetch", func() {
		for _, f := range []nostr.Filter{{Tags: nostr.TagMap{"p": pTags}}, givenZapsFilter(pTags, nil)} {
			if ctx.Err() != nil {
				break
			}
			res := fetchPaged(ctx, importRelays(), f, importLaneMaxPages, keep)
			short = append(short, res.Short...)
		}
	})

	switch {
	case ctx.Err() != nil && errors.Is(context.Cause(ctx), context.DeadlineExceeded):
		log.Println("🚫 Timeout after", timeout, "while importing tagged notes;", fmt.Sprintf("imported %d tagged notes", stored))
	case len(short) > 0:
		log.Printf("⚠️ %d relay(s) stopped partway through your tagged notes; older ones from them may be missing: %v", len(short), short)
		log.Println("📦 imported", stored, "tagged notes")
	default:
		log.Println("📦 imported", stored, "tagged notes")
	}
	if failed > 0 {
		log.Printf("⚠️ Failed to import %d tagged notes", failed)
	}

	log.Println("✅ tagged import complete")
	debug.FreeOSMemory()
}
