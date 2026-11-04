package main

import (
	"context"
	"log/slog"

	"github.com/nbd-wtf/go-nostr"
)

// Moving in pulls the user's older list versions from history relays
// (Lazarus; Logen 2026-11-04) and files them through /lists
// (list_history_relay.go). They are kept apart from the vault's own history,
// in the `listsimport` store, so an import can only add to what the vault
// keeps, never take from it (Tron, PR 1637): the vault's own history is
// trimmed by its own rule over its own versions, exactly as before any
// import. /lists serves both stores together.
//
// Imported versions are trimmed against everything (the vault's own and the
// imported), and only imported ones are ever deleted here: one is kept when
// the whole list's retention keeps it (among the newest, or a drain's pin), so
// an imported copy from before a wipe stays. They are not trimmed one at a
// time as they arrive (that would let a pre-wipe copy go before the wipe
// itself arrived): the next version the vault files trims them
// (recordListVersion), and a list that reaches listHistoryImportMax imported
// versions is trimmed then.

// listsImportDB holds the versions an import filed (initDBs, "listsimport").
var listsImportDB DBBackend

// listHistoryImportMax: imported versions of one list before an import trims.
const listHistoryImportMax = 500

// fileImportedVersion keeps evt in the import store, once per id: not when the
// vault's own history already holds it.
func fileImportedVersion(ctx context.Context, evt *nostr.Event) error {
	if listsImportDB == nil || listsDB == nil {
		return errDBClosing
	}
	listHistoryMu.Lock()
	defer listHistoryMu.Unlock()
	d := evt.Tags.GetD()
	own, err := listVersions(ctx, listsDB, evt.PubKey, evt.Kind, d)
	if err != nil {
		return err
	}
	imported, err := listVersions(ctx, listsImportDB, evt.PubKey, evt.Kind, d)
	if err != nil {
		return err
	}
	for _, v := range append(own, imported...) {
		if v.ID == evt.ID {
			return nil
		}
	}
	if err := listsImportDB.SaveEvent(ctx, evt); err != nil {
		return err
	}
	if len(imported)+1 >= listHistoryImportMax {
		trimImportedLocked(ctx, evt.PubKey, evt.Kind, d)
	}
	return nil
}

// trimImportedLocked deletes the imported versions of one list that the
// whole list's retention lets go. Never a version of the vault's own history.
// Callers hold listHistoryMu.
func trimImportedLocked(ctx context.Context, author string, kind int, d string) {
	if listsImportDB == nil || listsDB == nil {
		return
	}
	imported, err := listVersions(ctx, listsImportDB, author, kind, d)
	if err != nil || len(imported) == 0 {
		return
	}
	own, err := listVersions(ctx, listsDB, author, kind, d)
	if err != nil {
		return
	}
	isImported := make(map[string]bool, len(imported))
	for _, v := range imported {
		isImported[v.ID] = true
	}
	all := mergeVersions(own, imported)
	for _, gone := range listHistoryToDrop(all) {
		if !isImported[gone.ID] {
			continue
		}
		if err := listsImportDB.DeleteEvent(ctx, gone); err != nil {
			slog.Warn("list history: imported trim failed", "id", gone.ID, "err", err)
		}
	}
}

// mergeVersions: both sets, one per id, newest first.
func mergeVersions(a, b []*nostr.Event) []*nostr.Event {
	seen := make(map[string]bool, len(a)+len(b))
	out := make([]*nostr.Event, 0, len(a)+len(b))
	for _, set := range [][]*nostr.Event{a, b} {
		for _, ev := range set {
			if !seen[ev.ID] {
				seen[ev.ID] = true
				out = append(out, ev)
			}
		}
	}
	sortNewestFirst(out)
	return out
}
