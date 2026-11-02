package main

import (
	"context"
	"log/slog"
	"sort"
	"sync"

	"github.com/nbd-wtf/go-nostr"
)

// List history (RESEARCH/NV_LIST_PROTECTION_PLAN.md, Logen 2026-11-02,
// "protect the user"). The outbox keeps only the newest copy of a list, so
// one bad save by any app wipes it for good. Every version of an owner
// account's protected list that reaches the outbox, on any path (the relay,
// imports, feed sync, Mac sync, negentropy), is also kept in the separate
// `lists` store: never served as the current list, never blasted, never
// uploaded. The apps read it through /lists (list_history_relay.go).

// listsDB is the history store, opened with the others (initDBs).
var listsDB DBBackend

const (
	// Versions kept per list (account, kind, d).
	listHistoryKeep = 20
	// Wipes whose lists are kept beyond that, at most, newest first. Each
	// keeps up to three versions: the wipe, the version just before it and
	// the largest list since the wipe before (listHistoryToDrop).
	listHistoryPinnedMax = 5
	// Enough for every version of one list, under every store's MaxLimit.
	listHistoryQueryLimit = 1000
	// Added to a history query's kinds so the store doesn't cap a
	// replaceable kind at one result (nostr.GetTheoreticalLimit). No list
	// store ever holds kind 1.
	listHistoryPadKind = 1
)

// listHistoryMu serialises version writes and trims, so two copies of one
// list arriving together can't trim each other's versions.
var listHistoryMu sync.Mutex

// listHistoryDB is the outbox store with list history on the way in. It
// sits inside the gate (GranularInitDBs), so the gate's close handling is
// unchanged.
type listHistoryDB struct {
	DBBackend
	history func() DBBackend
}

func newListHistoryDB(inner DBBackend, history func() DBBackend) *listHistoryDB {
	return &listHistoryDB{DBBackend: inner, history: history}
}

func (l *listHistoryDB) ReplaceEvent(ctx context.Context, evt *nostr.Event) error {
	l.keep(ctx, evt)
	return l.DBBackend.ReplaceEvent(ctx, evt)
}

func (l *listHistoryDB) SaveEvent(ctx context.Context, evt *nostr.Event) error {
	l.keep(ctx, evt)
	return l.DBBackend.SaveEvent(ctx, evt)
}

// keep files a version before the outbox decides whether it is the newest:
// an older copy arriving late is still a real version.
func (l *listHistoryDB) keep(ctx context.Context, evt *nostr.Event) {
	if !isOwnerList(evt) {
		return
	}
	if err := recordListVersion(ctx, l.history(), evt); err != nil {
		slog.Warn("list history: version not kept", "kind", evt.Kind, "id", evt.ID, "err", err)
	}
}

// isOwnerList: a protected list written by an account this vault serves.
func isOwnerList(evt *nostr.Event) bool {
	if evt == nil || !isProtectedListKind(evt.Kind) {
		return false
	}
	_, owner := config.WhitelistedPubKeys[evt.PubKey]
	return owner
}

// listVersions returns every kept version of the list evt belongs to (same
// author, kind and d), newest first, one per id.
func listVersions(ctx context.Context, store DBBackend, author string, kind int, d string) ([]*nostr.Event, error) {
	f := nostr.Filter{Authors: []string{author}, Kinds: []int{kind, listHistoryPadKind}, Limit: listHistoryQueryLimit}
	if nostr.IsAddressableKind(kind) {
		f.Tags = nostr.TagMap{"d": []string{d}}
	}
	ch, err := store.QueryEvents(ctx, f)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var out []*nostr.Event
	for ev := range ch {
		if ev.Kind != kind || ev.PubKey != author || seen[ev.ID] {
			continue
		}
		if nostr.IsAddressableKind(kind) && ev.Tags.GetD() != d {
			continue
		}
		seen[ev.ID] = true
		out = append(out, ev)
	}
	sortNewestFirst(out)
	return out, nil
}

func sortNewestFirst(evs []*nostr.Event) {
	sort.SliceStable(evs, func(i, j int) bool {
		if evs[i].CreatedAt != evs[j].CreatedAt {
			return evs[i].CreatedAt > evs[j].CreatedAt
		}
		return evs[i].ID < evs[j].ID
	})
}

// recordListVersion keeps evt in the history store (once per id) and trims
// that list.
func recordListVersion(ctx context.Context, store DBBackend, evt *nostr.Event) error {
	if store == nil {
		return errDBClosing
	}
	listHistoryMu.Lock()
	defer listHistoryMu.Unlock()
	versions, err := listVersions(ctx, store, evt.PubKey, evt.Kind, evt.Tags.GetD())
	if err != nil {
		return err
	}
	for _, v := range versions {
		if v.ID == evt.ID {
			return nil
		}
	}
	if err := store.SaveEvent(ctx, evt); err != nil {
		return err
	}
	versions = append(versions, evt)
	sortNewestFirst(versions)
	for _, gone := range listHistoryToDrop(versions) {
		if err := store.DeleteEvent(ctx, gone); err != nil {
			slog.Warn("list history: trim failed", "id", gone.ID, "err", err)
		}
	}
	return nil
}

// listHistoryToDrop picks, from one list's versions newest first, the ones
// retention lets go: everything but the newest listHistoryKeep, except what
// a wipe pins. A wipe is a version that shrank the one just before it
// (listShrank against its neighbour, as the apps see it), so a slow tidy over
// many small edits is not one. Each wipe pins at most two versions, each only
// while no newer version holds all its items (listHolds: restored or rebuilt,
// not merely refilled), together with the wipe itself so it can still be
// seen:
//   - the version just before it;
//   - the largest version since the wipe before it that it shrank. A late,
//     older copy filed between the list and the wipe becomes the neighbour,
//     so without this the list it displaced would be let go.
//
// At most listHistoryPinnedMax wipes, newest first, so repeated wipes can't
// grow the store without end (20 + 15 versions per list at most).
func listHistoryToDrop(versions []*nostr.Event) []*nostr.Event {
	keep := map[string]bool{}
	for i := 0; i < len(versions) && i < listHistoryKeep; i++ {
		keep[versions[i].ID] = true
	}
	items := make([]map[string]struct{}, len(versions))
	for i, v := range versions {
		items[i] = listItems(v)
	}
	unheld := func(i int) bool {
		for k := 0; k < i; k++ {
			if listHolds(versions[k], items[k], items[i], versions[i]) {
				return false
			}
		}
		return true
	}
	var wipes []int
	for w := 0; w+1 < len(versions); w++ {
		if listShrank(versions[w+1], versions[w]) {
			wipes = append(wipes, w)
		}
	}
	pinned := 0
	for n, w := range wipes {
		if pinned >= listHistoryPinnedMax {
			break
		}
		// This wipe's span: back to the wipe before it, not including it.
		end := len(versions)
		if n+1 < len(wipes) {
			end = wipes[n+1]
		}
		var pins []int
		if unheld(w + 1) {
			pins = append(pins, w+1)
		}
		largest := -1
		for i := w + 2; i < end; i++ {
			if listShrank(versions[i], versions[w]) && unheld(i) &&
				(largest < 0 || listItemCount(versions[i]) > listItemCount(versions[largest])) {
				largest = i
			}
		}
		if largest >= 0 {
			pins = append(pins, largest)
		}
		if len(pins) == 0 {
			continue // restored
		}
		keep[versions[w].ID] = true
		for _, i := range pins {
			keep[versions[i].ID] = true
		}
		pinned++
	}
	var drop []*nostr.Event
	for _, v := range versions {
		if !keep[v.ID] {
			drop = append(drop, v)
		}
	}
	return drop
}

// seedListHistory files the current copy of every protected list the outbox
// holds for each account, so history starts with what is there today. Run at
// every start: a version already kept is skipped, so it is idempotent and
// needs no done-marker.
func seedListHistory(ctx context.Context, outbox, history DBBackend) {
	if outbox == nil || history == nil {
		return
	}
	for author := range config.WhitelistedPubKeys {
		for kind := range protectedListKinds {
			ch, err := outbox.QueryEvents(ctx, nostr.Filter{Authors: []string{author}, Kinds: []int{kind}, Limit: listHistoryQueryLimit})
			if err != nil {
				continue
			}
			for ev := range ch {
				if ev.Kind != kind || ev.PubKey != author {
					continue
				}
				if err := recordListVersion(ctx, history, ev); err != nil {
					slog.Warn("list history: seed failed", "kind", kind, "err", err)
				}
			}
		}
	}
}
