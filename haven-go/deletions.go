package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"

	"github.com/nbd-wtf/go-nostr"
)

// isDeleted reports whether db holds a NIP-09 delete request covering the event.
//
// khatru runs this check itself before storing an event, but its filters ask for
// the tag keys "#e" and "#a" where go-nostr expects "e" and "a", so they never
// match anything and a deleted event comes straight back on the next publish.
// The import paths write to the databases directly and don't check at all.
// eventQuerier is the read half of both DBBackend and eventstore.Store, so the
// relay policies (which hold a DBBackend) and the import/sync paths (which hold
// an eventstore.RelayWrapper) can share one check.
type eventQuerier interface {
	QueryEvents(ctx context.Context, filter nostr.Filter) (chan *nostr.Event, error)
}

func isDeleted(ctx context.Context, db eventQuerier, event *nostr.Event) bool {
	// only the author of an event and the relay owner can delete it, so a delete
	// request from anybody else doesn't count
	authors := []string{event.PubKey, config.OwnerPubKey}

	filters := []nostr.Filter{{
		Kinds:   []int{nostr.KindDeletion},
		Authors: authors,
		Tags:    nostr.TagMap{"e": []string{event.ID}},
		Limit:   1,
	}}

	// replaceable and addressable events are also deleted by address, and such a
	// request only covers the versions that existed when it was made
	if !nostr.IsRegularKind(event.Kind) {
		address := fmt.Sprintf("%d:%s:%s", event.Kind, event.PubKey, event.Tags.GetD())
		filters = append(filters, nostr.Filter{
			Kinds:   []int{nostr.KindDeletion},
			Authors: authors,
			Tags:    nostr.TagMap{"a": []string{address}},
			Since:   &event.CreatedAt,
			Limit:   1,
		})
	}

	for _, filter := range filters {
		ch, err := db.QueryEvents(ctx, filter)
		if err != nil {
			slog.Error("🚫 error looking for delete requests", "event", event.ID, "error", err)
			continue
		}

		deleted := false
		for range ch {
			deleted = true
		}
		if deleted {
			return true
		}
	}

	return false
}

// eventDeleter is the read-and-delete half shared by DBBackend and
// eventstore.Store, so the import paths (RelayWrapper.Store) and the startup
// sweep (a DBBackend) run the same code.
type eventDeleter interface {
	eventQuerier
	DeleteEvent(ctx context.Context, evt *nostr.Event) error
}

// applyDeletion carries out a NIP-09 delete request that reached db outside
// khatru's websocket pipeline: owner catch-up, outbox negentropy and the
// startup import all write straight to the store. khatru only runs its
// handleDeleteRequest for a kind 5 received over a websocket, so a kind 5
// written directly is kept (and isDeleted then blocks a re-import) but the
// events it targets stay. That is how a post deleted on the phone survived
// in the Mac and Android vaults, which went on serving it.
//
// The query per "e"/"a" tag mirrors khatru's handleDeleteRequest, and the
// decision is delegated to OwnerCanDeleteAnyEvent — the same outcome function
// wired into every relay — so the two paths cannot disagree on who may delete
// what. A target that is not stored is not an error: isDeleted keeps it out if
// it arrives later. Returns how many events were removed.
func applyDeletion(ctx context.Context, db eventDeleter, del *nostr.Event) (int, error) {
	if del.Kind != nostr.KindDeletion {
		return 0, nil
	}
	removed := 0
	var errs []error
	for _, tag := range del.Tags {
		if len(tag) < 2 {
			continue
		}
		var f nostr.Filter
		switch tag[0] {
		case "e":
			f = nostr.Filter{IDs: []string{tag[1]}}
		case "a":
			spl := strings.SplitN(tag[1], ":", 3)
			if len(spl) != 3 {
				continue
			}
			kind, err := strconv.Atoi(spl[0])
			if err != nil {
				continue
			}
			// Only the versions that existed when the request was made.
			f = nostr.Filter{
				Kinds:   []int{kind},
				Authors: []string{spl[1]},
				Tags:    nostr.TagMap{"d": []string{spl[2]}},
				Until:   &del.CreatedAt,
			}
		default:
			continue
		}

		ch, err := db.QueryEvents(ctx, f)
		if err != nil {
			errs = append(errs, fmt.Errorf("query %s=%s: %w", tag[0], tag[1], err))
			continue
		}
		// Drain the channel fully so the store's query goroutine can finish.
		for target := range ch {
			accept, msg := OwnerCanDeleteAnyEvent(ctx, target, del)
			if !accept {
				slog.Debug("🚫 imported delete request refused", "request", del.ID, "target", target.ID, "reason", msg)
				continue
			}
			if err := db.DeleteEvent(ctx, target); err != nil {
				errs = append(errs, fmt.Errorf("delete %s: %w", target.ID, err))
				continue
			}
			removed++
		}
	}
	return removed, errors.Join(errs...)
}

// applyImportedDeletion is applyDeletion for the import paths: a kind 5 is
// applied to db and the outcome logged; anything else is a no-op. Errors are
// logged, not returned — the request itself must still be stored so isDeleted
// keeps the target out, and the next sync round gets another go.
func applyImportedDeletion(ctx context.Context, db eventDeleter, ev *nostr.Event) {
	if ev.Kind != nostr.KindDeletion {
		return
	}
	n, err := applyDeletion(ctx, db, ev)
	if err != nil {
		slog.Error("🚫 error applying imported delete request", "request", ev.ID, "error", err)
	}
	if n > 0 {
		slog.Info("🗑️ imported delete request removed events", "request", ev.ID, "author", ev.PubKey, "removed", n)
	}
}

// sweepDeleteRequests applies every delete request the whitelisted keys have
// stored in db. Vaults filled before imports applied deletions hold kind 5s
// whose targets were never removed; those requests are already stored, so no
// sync round offers them again. Runs once at startup; applyDeletion is
// idempotent, so the sweep is cheap when there is nothing left to remove.
func sweepDeleteRequests(ctx context.Context, db eventDeleter) {
	authors := make([]string, 0, len(config.WhitelistedPubKeys))
	for pk := range config.WhitelistedPubKeys {
		authors = append(authors, pk)
	}
	if len(authors) == 0 {
		return
	}
	ch, err := db.QueryEvents(ctx, nostr.Filter{Kinds: []int{nostr.KindDeletion}, Authors: authors})
	if err != nil {
		slog.Error("🚫 error listing stored delete requests", "error", err)
		return
	}
	// Collect first: deleting while the query cursor is open would mutate the
	// store underneath it.
	var requests []*nostr.Event
	for ev := range ch {
		requests = append(requests, ev)
	}
	removed := 0
	for _, del := range requests {
		if ctx.Err() != nil {
			return
		}
		n, err := applyDeletion(ctx, db, del)
		if err != nil {
			slog.Error("🚫 error applying stored delete request", "request", del.ID, "error", err)
		}
		removed += n
	}
	if removed > 0 {
		slog.Info("🗑️ stored delete requests applied at startup", "requests", len(requests), "removed", removed)
	}
}
