package main

import (
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// ─── Refused-relay cache ────────────────────────────────────────────────────
//
// relay.damus.io bans, and lists in public, IPs that send it too many
// requests in 24 h. Once a relay has refused us (HTTP 403/429/503 on the
// websocket upgrade, or a rate-limited/banned reason), every further
// dial only deepens the ban, so the relay is skipped for relayBanTTL by the
// pool (EnsureRelay) and by the negentropy loops, which dial on their own.
//
// A plain connect failure (no network, DNS, timeout) is not cached here: it
// is what an offline phone sees for every relay, and a 24 h skip would leave
// it unsynced long after it is back. The pool's penalty box backs those off.

const relayBanTTL = 24 * time.Hour

var relayBans sync.Map // normalized relay URL → time.Time (refused at)

// relayBanned reports whether url refused us within relayBanTTL.
func relayBanned(url string) bool {
	key := nostr.NormalizeURL(url)
	v, ok := relayBans.Load(key)
	if !ok {
		return false
	}
	if time.Since(v.(time.Time)) < relayBanTTL {
		return true
	}
	relayBans.Delete(key)
	return false
}

// noteRelayRefusal caches url as refused when err says the relay itself
// turned us away. Other errors are ignored.
func noteRelayRefusal(url string, err error) {
	if !isRelayRefusal(err) {
		return
	}
	key := nostr.NormalizeURL(url)
	if _, loaded := relayBans.Swap(key, time.Now()); !loaded {
		slog.Warn("relay refused us, skipping it for 24 h", "relay", key, "err", err)
	}
}

func isRelayRefusal(err error) bool {
	if err == nil {
		return false
	}
	var hs *nostr.HandshakeStatusError
	if errors.As(err, &hs) {
		switch hs.StatusCode {
		case http.StatusForbidden, http.StatusTooManyRequests, http.StatusServiceUnavailable:
			return true
		}
		return false
	}
	msg := strings.ToLower(err.Error())
	// Not every "blocked:": damus answers a too-broad negentropy filter with
	// "blocked: too many query results", which is about that filter, not us.
	for _, s := range []string{"rate-limited", "banned", "too many requests"} {
		if strings.Contains(msg, s) {
			return true
		}
	}
	return false
}

// poolDialGate is the pool's WithDialGate option for the refused-relay cache.
func poolDialGate() nostr.PoolOption {
	return nostr.WithDialGate(func(url string) error {
		if relayBanned(url) {
			return fmt.Errorf("%s refused us, skipped for 24 h", url)
		}
		return nil
	}, noteRelayRefusal)
}

// ─── Bulk-read exclusions ───────────────────────────────────────────────────
//
// The feed sync (1,000-author REQs every round) and the Popular firehose (an
// author-less REQ for kinds 7/6/9735) are the heaviest reads the relay makes.
// They stay off these hosts; publishes, DMs, import and lookups still use them.

var bulkReadExcludedHosts = []string{"relay.damus.io"}

// withoutBulkReadExcluded returns relays minus the bulkReadExcludedHosts.
func withoutBulkReadExcluded(relays []string) []string {
	out := make([]string, 0, len(relays))
	for _, r := range relays {
		u, err := url.Parse(nostr.NormalizeURL(r))
		excluded := false
		if err == nil {
			for _, h := range bulkReadExcludedHosts {
				if strings.EqualFold(u.Hostname(), h) {
					excluded = true
					break
				}
			}
		}
		if !excluded {
			out = append(out, r)
		}
	}
	return out
}
