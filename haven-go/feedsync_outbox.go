package main

import (
	"context"
	"log"
	"net/netip"
	"net/url"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The feed sync reads each follow where they post (Logen 2026-11-08): the
// follows' own write relays (NIP-65 outbox), not only the owner's relays.
// Same rule as the apps' FeedOutboxPlan (iOS FeedOutboxPlan.swift, Android
// FeedOutboxPlan.kt): a follow already reached by one of the owner's relays
// adds nothing, the rest are covered greedily by at most feedOutboxMaxExtra
// extra relays, and each extra relay is asked only for the follows it was
// picked for. A follow with no relay list is read from the owner's relays
// alone: there is no hidden fallback relay. The follows' relay lists are
// read from the owner's own relays too.

// feedOutboxMaxExtra: extra relays a round may ask on top of the owner's,
// the apps' maxExtraRelays.
const feedOutboxMaxExtra = 8

// feedOutboxListsTTL: how long the follows' relay lists are kept before a
// round asks for them again. They change rarely; a round runs every 15 min+.
const feedOutboxListsTTL = 6 * time.Hour

// feedOutboxListsChunk: authors per relay-list request.
const feedOutboxListsChunk = 500

var feedOutboxLists struct {
	sync.Mutex
	at      time.Time
	follows int
	write   map[string][]string
}

// followWriteRelaysFrom picks each author's write relays from their newest
// kind 10002: "r" tags with no marker or marked "write" (NIP-65).
func followWriteRelaysFrom(events []*nostr.Event) map[string][]string {
	newest := map[string]*nostr.Event{}
	for _, ev := range events {
		if ev == nil || ev.Kind != nostr.KindRelayListMetadata {
			continue
		}
		if cur := newest[ev.PubKey]; cur == nil || ev.CreatedAt > cur.CreatedAt {
			newest[ev.PubKey] = ev
		}
	}
	out := map[string][]string{}
	for pk, ev := range newest {
		var relays []string
		for _, tag := range ev.Tags {
			if len(tag) < 2 || tag[0] != "r" {
				continue
			}
			if len(tag) >= 3 && tag[2] != "" && tag[2] != "write" {
				continue
			}
			relays = append(relays, strings.TrimSpace(tag[1]))
		}
		if len(relays) > 0 {
			out[pk] = relays
		}
	}
	return out
}

// followWriteRelays reads the follows' relay lists from the owner's relays,
// kept for feedOutboxListsTTL (or until the follow count changes).
func followWriteRelays(ctx context.Context, follows []string, relays []string) map[string][]string {
	feedOutboxLists.Lock()
	defer feedOutboxLists.Unlock()
	if feedOutboxLists.write != nil && feedOutboxLists.follows == len(follows) && time.Since(feedOutboxLists.at) < feedOutboxListsTTL {
		return feedOutboxLists.write
	}
	var (
		mu     sync.Mutex
		events []*nostr.Event
	)
	sorted := slices.Sorted(slices.Values(follows))
	for chunk := range slices.Chunk(sorted, feedOutboxListsChunk) {
		if ctx.Err() != nil {
			return nil
		}
		lctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		fetchPaged(lctx, relays, nostr.Filter{Kinds: []int{nostr.KindRelayListMetadata}, Authors: chunk}, 2, func(ev *nostr.Event) {
			mu.Lock()
			events = append(events, ev)
			mu.Unlock()
		})
		cancel()
	}
	write := followWriteRelaysFrom(events)
	feedOutboxLists.at, feedOutboxLists.follows, feedOutboxLists.write = time.Now(), len(follows), write
	log.Printf("📚 feed outbox: relay lists for %d of %d follows", len(write), len(follows))
	return write
}

// feedOutboxPlan is the apps' FeedOutboxPlan.plan without a fallback relay:
// extra relay URL → the follows to ask it for (sorted). Each follow appears
// under one relay only, the first pick that reached them.
func feedOutboxPlan(follows []string, writeRelays map[string][]string, feedRelays []string, maxExtra int) map[string][]string {
	asked := map[string]bool{}
	for _, r := range feedRelays {
		if k, ok := outboxRelayKey(r); ok {
			asked[k] = true
		}
	}
	candidates := map[string]map[string]bool{} // relay key → follows
	urlForKey := map[string]string{}
	for _, author := range follows {
		var usable []string
		for _, raw := range writeRelays[author] {
			k, ok := outboxRelayKey(raw)
			if !ok {
				continue
			}
			if _, seen := urlForKey[k]; !seen {
				urlForKey[k] = strings.TrimSpace(raw)
			}
			usable = append(usable, k)
		}
		if len(usable) == 0 || slices.ContainsFunc(usable, func(k string) bool { return asked[k] }) {
			continue
		}
		for _, k := range usable {
			if candidates[k] == nil {
				candidates[k] = map[string]bool{}
			}
			candidates[k][author] = true
		}
	}
	plan := map[string][]string{}
	covered := map[string]bool{}
	for len(plan) < maxExtra {
		best, bestGain := "", 0
		for k, authors := range candidates {
			gain := 0
			for a := range authors {
				if !covered[a] {
					gain++
				}
			}
			if gain == 0 {
				continue
			}
			if best == "" || gain > bestGain || (gain == bestGain && k < best) {
				best, bestGain = k, gain
			}
		}
		if best == "" {
			break
		}
		var picked []string
		for a := range candidates[best] {
			if !covered[a] {
				covered[a] = true
				picked = append(picked, a)
			}
		}
		delete(candidates, best)
		sort.Strings(picked)
		plan[urlForKey[best]] = picked
	}
	return plan
}

// outboxRelayKey: `wss://Host/` and `wss://host` are one relay. Only public
// wss relays by hostname qualify, as in the apps' normalizedKey: no ws://, no
// IP literal of any kind (v4, v6, or the short and hex forms a resolver may
// still read as an address, like 127.1 or 0x7f.1), no dotless name, and no
// localhost, .local, .onion or other private-use name. A follow's relay list
// must not make the vault dial an address its author picks: the LAN, CGNAT
// (100.64/10, Tailscale), link-local (169.254/16, fe80::/10) or the box
// itself (health audit Tron §5, 2026-11-08). A hostname that resolves to a
// private address is not caught here.
func outboxRelayKey(raw string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || strings.ToLower(u.Scheme) != "wss" {
		return "", false
	}
	host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	if !publicRelayHost(host) {
		return "", false
	}
	port := ""
	if p := u.Port(); p != "" {
		port = ":" + p
	}
	return "wss://" + host + port + strings.TrimSuffix(u.Path, "/"), true
}

// privateUseSuffixes are names that never reach the public internet.
var privateUseSuffixes = []string{".localhost", ".local", ".onion", ".internal", ".lan", ".home", ".home.arpa", ".corp", ".intranet", ".private", ".test", ".invalid", ".arpa"}

func publicRelayHost(host string) bool {
	if host == "" || !strings.Contains(host, ".") || strings.ContainsAny(host, ":%[]") {
		return false // dotless names, and IPv6 literals (url.Hostname strips the brackets)
	}
	if _, err := netip.ParseAddr(host); err == nil {
		return false
	}
	for _, s := range privateUseSuffixes {
		if strings.HasSuffix(host, s) {
			return false
		}
	}
	// A public top-level domain is never numeric: "127.1", "10.0.0.010", "0x7f.1"
	// and "1.2.3.4" all end in one and some resolvers read them as addresses.
	tld := host[strings.LastIndex(host, ".")+1:]
	if tld == "" || strings.Trim(tld, "0123456789") == "" || strings.HasPrefix(tld, "0x") {
		return false
	}
	return true
}

// pullFeedOutbox asks each extra relay of the plan for its own follows only:
// the rare kinds since rareSince, then the common kinds since commonSince
// (paged, as the owner's relays' fallback pull). True unless one of them
// stopped partway and may still hold the watermark (stepShortStreaks, the
// same #1721 escape as the owner's relays, in its own shortRounds).
//
// A follow's relay that never answers is skipped, not counted against the
// round: dead relays in follows' lists are common, and one of them used to
// keep every round incomplete, so each hourly round re-read the whole
// window from every relay (#1843 regression, health audit B1 2026-11-08).
func pullFeedOutbox(ctx context.Context, plan map[string][]string, rareSince, commonSince nostr.Timestamp, publish func(*nostr.Event), shortRounds map[string]int) bool {
	urls := slices.Sorted(func(yield func(string) bool) {
		for u := range plan {
			if !yield(u) {
				return
			}
		}
	})
	held := false
	asked := map[string]bool{}
	for _, u := range urls {
		if ctx.Err() != nil {
			return false
		}
		if relayBanned(u) {
			continue
		}
		asked[nostr.NormalizeURL(u)] = true
		authors := plan[u]
		rctx, cancel := context.WithTimeout(ctx, 90*time.Second)
		fetchPaged(rctx, []string{u}, feedRareFilter(authors, rareSince), 1, publish)
		cancel()
		res := fetchPaged(ctx, []string{u}, feedCommonFilter(authors, commonSince), importMaxPages, publish)
		if ctx.Err() != nil {
			return false
		}
		if slices.Contains(res.Silent, u) {
			delete(shortRounds, nostr.NormalizeURL(u))
			log.Println("📚 feed outbox: relay did not answer, skipped this round:", u)
			continue
		}
		if stepShortStreaks([]string{u}, res.Short, shortRounds) {
			held = true
		}
	}
	for key := range shortRounds {
		if !asked[key] {
			delete(shortRounds, key)
		}
	}
	return !held
}
