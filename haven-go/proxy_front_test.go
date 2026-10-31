//go:build !(js && wasm)

package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/barrydeen/haven/internal/box"
	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/policies"
	"github.com/nbd-wtf/go-nostr"
)

// The whole path as on the box: a LAN client → havend's front proxy
// (box.EngineProxy, which sets X-Forwarded-For) → the engine's root handler →
// a khatru relay with the private relay's connection limiter. The client is
// placed on the LAN by its peer address at havend's socket.
func TestBoxFrontDoorRateLimitsTheRealClient(t *testing.T) {
	skipWithoutSockets(t)
	prev := behindProxy
	behindProxy = true
	t.Cleanup(func() { behindProxy = prev })

	relay := khatru.NewRelay()
	relay.RejectConnection = append(relay.RejectConnection,
		bypassLocalhostConnectionLimiter(policies.ConnectionRateLimiter(3, 5*time.Minute, 9)))
	engine := httptest.NewServer(proxyAware(relay.ServeHTTP))
	t.Cleanup(engine.Close)
	enginePort := engine.Listener.Addr().(*net.TCPAddr).Port

	front := box.EngineProxy(enginePort)
	peer := "192.168.1.50:51000"
	door := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.RemoteAddr = peer
		front.ServeHTTP(w, r)
	}))
	t.Cleanup(door.Close)
	url := "ws" + strings.TrimPrefix(door.URL, "http")

	dial := func(n int) int {
		ok := 0
		for i := 0; i < n; i++ {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			r, err := nostr.RelayConnect(ctx, url)
			cancel()
			if err == nil {
				ok++
				r.Close()
			}
		}
		return ok
	}
	if got := dial(30); got != 9 {
		t.Fatalf("LAN client through havend: %d/30 connections, want the burst of 9", got)
	}
	// A client spoofing X-Forwarded-For at havend gets nothing for it: havend
	// replaces the header, so the engine still sees the same LAN peer.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := nostr.RelayConnect(ctx, url, nostr.WithRequestHeader{"X-Forwarded-For": []string{"127.0.0.1"}}); err == nil {
		t.Fatal("spoofed X-Forwarded-For got the loopback pass")
	}
	// The box's own loopback client stays unlimited.
	peer = "127.0.0.1:52000"
	if got := dial(15); got != 15 {
		t.Fatalf("loopback through havend: %d/15", got)
	}
}
