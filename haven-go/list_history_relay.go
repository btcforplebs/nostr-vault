package main

import (
	"context"
	"net/http"

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
	rl.QueryEvents = append(rl.QueryEvents, func(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		return queryListHistory(ctx, listsDB, f)
	})

	rl.Router().HandleFunc("GET /lists", func(w http.ResponseWriter, r *http.Request) {
		renderFallbackPage(w, rl.Info.Name, rl.Info.Description, getWSScheme(config.RelayURL)+config.RelayURL+"/lists")
	})
	return rl
}

// rejectListHistoryWrite: history is filed by the vault itself as lists
// arrive at the outbox; nothing is written here.
func rejectListHistoryWrite(context.Context, *nostr.Event) (bool, string) {
	return true, "blocked: list history is read-only; publish lists to the main relay"
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
