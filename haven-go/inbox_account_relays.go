package main

import (
	"context"
	"log"
	"maps"
	"slices"
	"strings"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Each account on the device is also pulled from its own inbox relays: the
// read relays of its kind 10002 (NIP-65) and its kind 10050 DM relays. A
// reply sent only to relays an account lists (and not to the shared seed /
// DM relays) otherwise never reaches that account's notifications.
// Android, iPhone and Mac all run this relay, so all three get it.
const (
	maxInboxRelaysPerAccount = 5
	maxAccountInboxRelays    = 15
	accountRelayListTimeout  = 8 * time.Second
)

var accountRelayListKinds = []int{nostr.KindRelayListMetadata, nostr.KindDMRelayList}

// accountInboxRelays returns the relays to add to shared for accounts: each
// account's newest 10002 read relays, then its 10050 relays, skipping any
// already in shared (after normalising), banned ones and anything but
// public wss://. At most maxInboxRelaysPerAccount per account and
// maxAccountInboxRelays in all. Lists come from the local outbox store
// (the owner catch-up keeps them current); accounts with none stored are
// read once from the seed relays the pool already has open.
func accountInboxRelays(ctx context.Context, accounts, shared []string) []string {
	if len(accounts) == 0 {
		return nil
	}
	accounts = slices.Sorted(slices.Values(accounts))
	lists := newestRelayLists(ctx, outboxDB, accounts)
	var missing []string
	for _, a := range accounts {
		if lists[a] == nil {
			missing = append(missing, a)
		}
	}
	if len(missing) > 0 && pool != nil {
		fctx, cancel := context.WithTimeout(ctx, accountRelayListTimeout)
		filter := nostr.Filter{Kinds: accountRelayListKinds, Authors: missing}
		for ev := range pool.FetchMany(fctx, importRelays(), filter) {
			keepNewestList(lists, ev.Event)
		}
		cancel()
	}
	return pickAccountInboxRelays(accounts, lists, shared)
}

// newestRelayLists reads each account's newest 10002 and 10050 from db.
func newestRelayLists(ctx context.Context, db DBBackend, accounts []string) map[string]map[int]*nostr.Event {
	lists := map[string]map[int]*nostr.Event{}
	if db == nil {
		return lists
	}
	ch, err := db.QueryEvents(ctx, nostr.Filter{Kinds: accountRelayListKinds, Authors: accounts})
	if err != nil {
		return lists
	}
	for ev := range ch {
		keepNewestList(lists, ev)
	}
	return lists
}

func keepNewestList(lists map[string]map[int]*nostr.Event, ev *nostr.Event) {
	if ev == nil || !slices.Contains(accountRelayListKinds, ev.Kind) {
		return
	}
	byKind := lists[ev.PubKey]
	if byKind == nil {
		byKind = map[int]*nostr.Event{}
		lists[ev.PubKey] = byKind
	}
	if cur := byKind[ev.Kind]; cur == nil || ev.CreatedAt > cur.CreatedAt {
		byKind[ev.Kind] = ev
	}
}

// pickAccountInboxRelays applies the order, skips and caps described on
// accountInboxRelays. Pure, for tests.
func pickAccountInboxRelays(accounts []string, lists map[string]map[int]*nostr.Event, shared []string) []string {
	seen := map[string]struct{}{}
	for _, r := range shared {
		seen[nostr.NormalizeURL(r)] = struct{}{}
	}
	var out []string
	for _, a := range accounts {
		added := 0
		for _, r := range inboxRelaysOf(lists[a]) {
			if len(out) >= maxAccountInboxRelays {
				return out
			}
			if added >= maxInboxRelaysPerAccount {
				break
			}
			url := nostr.NormalizeURL(r)
			if _, dup := seen[url]; dup || !accountRelayAllowed(url) || relayBanned(url) {
				continue
			}
			seen[url] = struct{}{}
			out = append(out, url)
			added++
		}
	}
	return out
}

// inboxRelaysOf lists an account's inbox relays: 10002 "r" tags marked read
// or unmarked, then 10050 "relay" tags.
func inboxRelaysOf(byKind map[int]*nostr.Event) []string {
	var out []string
	if ev := byKind[nostr.KindRelayListMetadata]; ev != nil {
		for _, t := range ev.Tags {
			if len(t) >= 2 && t[0] == "r" && (len(t) == 2 || t[2] == "" || t[2] == "read") {
				out = append(out, t[1])
			}
		}
	}
	if ev := byKind[nostr.KindDMRelayList]; ev != nil {
		for _, t := range ev.Tags {
			if len(t) >= 2 && t[0] == "relay" {
				out = append(out, t[1])
			}
		}
	}
	return out
}

// accountRelayAllowed gates an account's listed relay; tests swap it to
// let their loopback ws:// fakes through.
var accountRelayAllowed = publicWSS

func publicWSS(url string) bool {
	host, ok := strings.CutPrefix(url, "wss://")
	if !ok || host == "" {
		return false
	}
	host, _, _ = strings.Cut(host, "/")
	host, _, _ = strings.Cut(host, ":")
	return host != "localhost" && !strings.HasPrefix(host, "127.") && !strings.HasSuffix(host, ".onion")
}

// withAccountInboxRelays adds every on-device account's inbox relays to
// relays and logs how many it added.
func withAccountInboxRelays(ctx context.Context, relays []string) []string {
	extra := accountInboxRelays(ctx, slices.Collect(maps.Keys(config.WhitelistedPubKeys)), relays)
	if len(extra) > 0 {
		log.Println("📢 inbox also pulls", len(extra), "account relays:", strings.Join(extra, " "))
	}
	return append(relays, extra...)
}
