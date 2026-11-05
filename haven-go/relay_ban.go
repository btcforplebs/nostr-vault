package main

import (
	"context"
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
		slog.Warn("relay refused us, skipping it for 24 h", "relay", seedHost(key), "err", withoutSeedPath(err.Error(), key))
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

// ─── One retry inside an import ─────────────────────────────────────────────
//
// One rate-limit answer used to drop a relay's whole history from an import:
// the 24 h ban made every later dial fail, the lane came back silent and the
// window walk dropped it in under a second (Tidy import audit, item 7). Inside
// an import, a relay that refused us during that import is given one more
// try after a back-off. A second refusal stands.

// importRefusalBackoff: the wait before that one retry. Shorter in tests.
// 35 s: past the pool's first penalty-box wait (30 s + 2 s) after a failed dial.
var importRefusalBackoff = 35 * time.Second

// importRetryWindow: how long one import's retry budget lasts, longer than a
// whole import (lanes, walk and tagged step, 15 min each at most). An import
// that starts while one is still in it shares that budget: it used to wipe
// the list of spent retries, so a relay got a second retry, and a second
// 35 s pause, for every import started on top (Tron, PR 1721).
const importRetryWindow = time.Hour

var (
	importRetryMu      sync.Mutex
	importRetryStarted time.Time                // when the current budget began
	importRetried      = map[string]time.Time{} // normalized URL → when its retry was spent
)

// beginImportRefusalRetries starts an import's retry budget, or joins the one
// still running: spent retries stay spent within importRetryWindow.
func beginImportRefusalRetries() {
	importRetryMu.Lock()
	defer importRetryMu.Unlock()
	now := time.Now()
	if !importRetryStarted.IsZero() && now.Sub(importRetryStarted) < importRetryWindow {
		return
	}
	importRetryStarted = now
	for key, at := range importRetried {
		if now.Sub(at) >= importRetryWindow {
			delete(importRetried, key)
		}
	}
}

// importRetryAfterRefusal: when url is banned by a refusal it gave during the
// current import and its retry isn't spent, wait importRefusalBackoff, lift
// the ban and report true (ask it again). False otherwise, or if ctx ends.
func importRetryAfterRefusal(ctx context.Context, url string) bool {
	key := nostr.NormalizeURL(url)
	v, ok := relayBans.Load(key)
	if !ok {
		return false
	}
	importRetryMu.Lock()
	at := v.(time.Time)
	if spent, ok := importRetried[key]; importRetryStarted.IsZero() || at.Before(importRetryStarted) || (ok && time.Since(spent) < importRetryWindow) {
		importRetryMu.Unlock()
		return false
	}
	importRetried[key] = time.Now()
	importRetryMu.Unlock()
	slog.Warn("relay refused us during the import; trying it once more after a pause", "relay", seedHost(key), "wait", importRefusalBackoff)
	select {
	case <-time.After(importRefusalBackoff):
	case <-ctx.Done():
		return false
	}
	relayBans.Delete(key)
	return true
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
