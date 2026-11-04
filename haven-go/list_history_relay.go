package main

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/policies"
	"github.com/nbd-wtf/go-nostr"
)

// listsRelay serves list history (list_history.go) at /lists: read-only,
// NIP-42 owner accounts only, like /private, and never over the mesh. A REQ
// for {kinds:[10003], authors:[me]} returns every kept version of that
// list, newest first.
var listsRelay *khatru.Relay

func initListsRelay() *khatru.Relay {
	rl := khatru.NewRelay()
	rl.Info.Name = config.PrivateRelayName + " list history"
	rl.Info.Description = "older versions of your lists, kept by your vault"
	rl.Info.Version = config.RelayVersion
	rl.Info.Software = config.RelaySoftware
	rl.ServiceURL = relayServiceURL("/lists")
	serviceURLFromHost(rl, "/lists")

	rl.OnConnect = append(rl.OnConnect, khatru.RequestAuth)
	rl.RejectFilter = append(rl.RejectFilter, meshNoQueries, policies.MustAuth, MustBeWhitelistedToQuery)
	rl.RejectCountFilter = append(rl.RejectCountFilter, meshNoQueries, policies.MustAuth, MustBeWhitelistedToQuery)
	rl.RejectEvent = append(rl.RejectEvent, rejectListHistoryWrite)
	// An accepted version (an older one a moving-in import found on the relays, Lazarus) is filed in the history
	// store only: never the outbox, so it never becomes the current list, is never blasted and never uploaded.
	rl.ReplaceEvent = append(rl.ReplaceEvent, func(ctx context.Context, evt *nostr.Event) error {
		return fileImportedVersion(ctx, listsDB, evt)
	})
	rl.QueryEvents = append(rl.QueryEvents, func(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		return queryListHistory(ctx, listsDB, f)
	})

	rl.Router().HandleFunc("GET /lists", func(w http.ResponseWriter, r *http.Request) {
		renderFallbackPage(w, rl.Info.Name, rl.Info.Description, getWSScheme(config.RelayURL)+config.RelayURL+"/lists")
	})
	return rl
}

// listHistoryImportMax: an import files versions without trimming (see
// fileImportedVersion) until one list holds this many; then it trims.
const listHistoryImportMax = 500

// fileImportedVersion keeps evt in the history store, once per id, without
// trimming. An import files many versions one at a time, and retention decided
// one at a time lets go the copy from before a wipe before the wipe itself has
// arrived (it is then neither among the newest nor pinned by a drain). The next
// version that reaches the outbox trims the whole list at once
// (recordListVersion); a list that reaches listHistoryImportMax is trimmed now.
func fileImportedVersion(ctx context.Context, store DBBackend, evt *nostr.Event) error {
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
	if len(versions)+1 < listHistoryImportMax {
		return nil
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

// listHistoryImportSkew: a version dated this far ahead of the vault's clock
// is refused, so one bad clock can't pose as the newest version (the apps'
// MAX_SKEW).
const listHistoryImportSkew = 15 * time.Minute

// rejectListHistoryWrite: history is filed by the vault itself as lists
// arrive at the outbox. The one write it takes (Logen 2026-11-04, moving in
// pulls old lists from history relays): one of this vault's own apps (AUTHed
// as a whitelisted key) filing a version of a protected list signed by one of
// this vault's accounts, found on the relays. The signature is checked before this runs (khatru);
// nothing else is written here, and nothing here reaches the outbox.
func rejectListHistoryWrite(ctx context.Context, evt *nostr.Event) (bool, string) {
	if isMeshConn(ctx) {
		return true, "restricted: no list history over the mesh"
	}
	if evt == nil || !isProtectedListKind(evt.Kind) {
		return true, "blocked: list history keeps only lists; publish other events to the main relay"
	}
	// The same gate as reading /lists: an AUTHed whitelisted key (the browser
	// vault AUTHs with its device key, not the user's). The event itself must
	// be signed by one of this vault's accounts.
	authed := khatru.GetAuthed(ctx)
	if authed == "" {
		return true, "auth-required: only this vault's own apps can file list history"
	}
	if _, ok := config.WhitelistedPubKeys[authed]; !ok {
		return true, "restricted: only this vault's own apps can file list history"
	}
	if _, owner := config.WhitelistedPubKeys[evt.PubKey]; !owner {
		return true, "restricted: list history is kept only for this vault's accounts"
	}
	if time.Unix(int64(evt.CreatedAt), 0).After(time.Now().Add(listHistoryImportSkew)) {
		return true, "invalid: dated ahead of this vault's clock"
	}
	return false, ""
}

// queryListHistory answers a REQ from the history store. Only owner
// accounts' protected lists are served; a filter naming no author or kind
// means all of them. Versions come newest first, then since, until, ids, d
// and limit apply.
func queryListHistory(ctx context.Context, store DBBackend, f nostr.Filter) (chan *nostr.Event, error) {
	out := make(chan *nostr.Event)
	if store == nil {
		close(out)
		return out, nil
	}
	authors := f.Authors
	if len(authors) == 0 {
		for pk := range config.WhitelistedPubKeys {
			authors = append(authors, pk)
		}
	}
	kinds := f.Kinds
	if len(kinds) == 0 {
		for k := range protectedListKinds {
			kinds = append(kinds, k)
		}
	}
	var found []*nostr.Event
	for _, author := range authors {
		if _, owner := config.WhitelistedPubKeys[author]; !owner {
			continue
		}
		for _, kind := range kinds {
			if !isProtectedListKind(kind) {
				continue
			}
			evs, err := allListVersions(ctx, store, author, kind)
			if err != nil {
				continue
			}
			for _, ev := range evs {
				if listHistoryMatches(f, ev) {
					found = append(found, ev)
				}
			}
		}
	}
	sortNewestFirst(found)
	if f.Limit > 0 && len(found) > f.Limit {
		found = found[:f.Limit]
	}
	go func() {
		defer close(out)
		for _, ev := range found {
			select {
			case out <- ev:
			case <-ctx.Done():
				return
			}
		}
	}()
	return out, nil
}

// allListVersions is listVersions for every d of an addressable kind.
func allListVersions(ctx context.Context, store DBBackend, author string, kind int) ([]*nostr.Event, error) {
	ch, err := store.QueryEvents(ctx, nostr.Filter{Authors: []string{author}, Kinds: []int{kind, listHistoryPadKind}, Limit: listHistoryQueryLimit})
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var out []*nostr.Event
	for ev := range ch {
		if ev.Kind == kind && ev.PubKey == author && !seen[ev.ID] {
			seen[ev.ID] = true
			out = append(out, ev)
		}
	}
	return out, nil
}

func listHistoryMatches(f nostr.Filter, ev *nostr.Event) bool {
	if f.Since != nil && ev.CreatedAt < *f.Since {
		return false
	}
	if f.Until != nil && ev.CreatedAt > *f.Until {
		return false
	}
	if len(f.IDs) > 0 {
		hit := false
		for _, id := range f.IDs {
			if id == ev.ID {
				hit = true
				break
			}
		}
		if !hit {
			return false
		}
	}
	if ds, ok := f.Tags["d"]; ok && len(ds) > 0 {
		d := ev.Tags.GetD()
		hit := false
		for _, want := range ds {
			if want == d {
				hit = true
				break
			}
		}
		if !hit {
			return false
		}
	}
	return true
}
