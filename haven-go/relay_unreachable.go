package main

import (
	"fmt"
	"net"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// ─── Unreachable-relay holds ─────────────────────────────────────────────────
//
// A relay the device can't reach (no route, DNS, connect timeout) is held for
// a while before anyone in this process dials it again. The pool's penalty
// box did that per pool, but the blast queue re-tried each pending note on
// its own, every pool kept its own count, and the box grows without a cap.
// With the network down the Android app started about one connect a second
// in the background (RESEARCH/NV_LAUNCH_BACKGROUND_PERF_REVIEW_2026_11_28.md
// finding 1).
//
// The hold doubles with each failed dial: 5 s, 10 s, 20 s, ... up to 2 min
// while the app is on screen and 10 min while it is not. A completed dial
// clears it. The cap is read when the hold is checked, so coming back on
// screen shortens a long background hold to the on-screen cap at once.
//
// This device's relay and LAN relays are never held: one of them restarting
// says nothing about the network.

const (
	unreachableFirstHold    = 5 * time.Second
	unreachableMaxHoldFg    = 2 * time.Minute
	unreachableMaxHoldBg    = 10 * time.Minute
	unreachableForgetAfter  = 30 * time.Minute // a failure this old starts the ladder over
	unreachableMaxDoublings = 16
)

type unreachableHold struct {
	failedAt time.Time
	strikes  int
}

type unreachableHolds struct {
	mu    sync.Mutex
	holds map[string]unreachableHold
	now   func() time.Time
	fg    func() bool
}

var relayUnreachable = &unreachableHolds{holds: map[string]unreachableHold{}, now: time.Now, fg: appForeground.isOn}

func (u *unreachableHolds) holdFor(strikes int) time.Duration {
	limit := unreachableMaxHoldBg
	if u.fg() {
		limit = unreachableMaxHoldFg
	}
	d := unreachableFirstHold << min(strikes-1, unreachableMaxDoublings)
	return min(d, limit)
}

// remaining is how long url is still held; 0 when it may be dialled.
func (u *unreachableHolds) remaining(rawURL string) time.Duration {
	key := nostr.NormalizeURL(rawURL)
	u.mu.Lock()
	defer u.mu.Unlock()
	h, ok := u.holds[key]
	if !ok {
		return 0
	}
	left := h.failedAt.Add(u.holdFor(h.strikes)).Sub(u.now())
	return max(left, 0)
}

// failed records a dial to url that never reached the relay.
func (u *unreachableHolds) failed(rawURL string) {
	if isLocalRelayURL(rawURL) {
		return
	}
	key := nostr.NormalizeURL(rawURL)
	now := u.now()
	u.mu.Lock()
	defer u.mu.Unlock()
	h := u.holds[key]
	if now.Sub(h.failedAt) > unreachableForgetAfter {
		h.strikes = 0
	}
	h.strikes++
	h.failedAt = now
	u.holds[key] = h
}

// reached clears url's hold: a dial got through.
func (u *unreachableHolds) reached(rawURL string) {
	key := nostr.NormalizeURL(rawURL)
	u.mu.Lock()
	delete(u.holds, key)
	u.mu.Unlock()
}

// isLocalRelayURL: loopback, a LAN address or .local name. Never held.
func isLocalRelayURL(rawURL string) bool {
	parsed, err := url.Parse(nostr.NormalizeURL(rawURL))
	if err != nil {
		return false
	}
	host := strings.ToLower(parsed.Hostname())
	if host == "localhost" || strings.HasSuffix(host, ".local") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && (ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast())
}

// unreachableGateErr is the dial gate's answer for a held relay.
func unreachableGateErr(rawURL string) error {
	if left := relayUnreachable.remaining(rawURL); left > 0 {
		return fmt.Errorf("%s unreachable lately, next dial in %s", rawURL, left.Round(time.Second))
	}
	return nil
}
