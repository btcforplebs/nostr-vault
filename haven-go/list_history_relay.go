package main

import (
	"context"
	"net/http"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/policies"
	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/internal/negsync"
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
	// An accepted version (an older one a moving-in import found on the relays, Lazarus) is filed in the import store
	// (list_history_import.go): never the outbox, so it never becomes the current list, is never blasted and never
	// uploaded; and never the vault's own history, so it can't change what the vault keeps there.
	rl.ReplaceEvent = append(rl.ReplaceEvent, func(ctx context.Context, evt *nostr.Event) error {
		return fileImportedVersion(ctx, evt)
	})
	rl.QueryEvents = append(rl.QueryEvents, func(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		return queryListHistory(ctx, listsDB, f)
	})

	rl.Router().HandleFunc("GET /lists", func(w http.ResponseWriter, r *http.Request) {
		renderFallbackPage(w, rl.Info.Name, rl.Info.Description, getWSScheme(config.RelayURL)+config.RelayURL+"/lists")
	})
	return rl
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
	if _, ok := whitelist()[authed]; !ok {
		return true, "restricted: only this vault's own apps can file list history"
	}
	if _, owner := whitelist()[evt.PubKey]; !owner {
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
		for pk := range whitelist() {
			authors = append(authors, pk)
		}
	}
	kinds := f.Kinds
	if len(kinds) == 0 {
		for k := range protectedListKinds {
			kinds = append(kinds, k)
		}
	}
	// A NEG-OPEN's context carries the vector mark, but the store read below
	// keeps rows by kind and author, which id+created_at stubs lack (Tron,
	// PR 1956): read whole events.
	ctx = negsync.Unmark(ctx)
	var found []*nostr.Event
	for _, author := range authors {
		if _, owner := whitelist()[author]; !owner {
			continue
		}
		for _, kind := range kinds {
			if !isProtectedListKind(kind) {
				continue
			}
			from := store
			// The versions an import filed (list_history_import.go) are served only to a filter that asks for
			// them, and then alone: the wipe alarm the apps run over a plain /lists read judges only versions
			// the vault filed itself, so an old clobber found on the relays is not a new wipe (Tron, PR 1637).
			if store == listsDB && wantsImported(f) {
				from = listsImportDB
			}
			if from == nil {
				continue
			}
			evs, err := allListVersions(ctx, from, author, kind)
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

// listHistoryImportedTag, listHistoryImportedValue: a /lists filter with
// {"#v": ["imported"]} gets the imported versions instead of the vault's own.
const (
	listHistoryImportedTag   = "v"
	listHistoryImportedValue = "imported"
)

func wantsImported(f nostr.Filter) bool {
	for _, v := range f.Tags[listHistoryImportedTag] {
		if v == listHistoryImportedValue {
			return true
		}
	}
	return false
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
