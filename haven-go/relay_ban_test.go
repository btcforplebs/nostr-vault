package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/barrydeen/haven/internal/negsync"
	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

func resetRelayBans(t *testing.T) {
	t.Helper()
	clear := func() {
		relayBans.Range(func(k, _ any) bool { relayBans.Delete(k); return true })
	}
	clear()
	t.Cleanup(clear)
}

// A relay that answers the websocket upgrade with 429 is dialled once; after
// that the pool refuses it without touching the network.
func TestPoolSkipsRelayThatRefusedUpgrade(t *testing.T) {
	resetRelayBans(t)
	var hits atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		http.Error(w, "slow down", http.StatusTooManyRequests)
	}))
	defer srv.Close()
	url := "ws" + strings.TrimPrefix(srv.URL, "http")

	p := nostr.NewSimplePool(context.Background(), poolDialGate())
	if _, err := p.EnsureRelay(url); err == nil {
		t.Fatal("dial to a 429 relay succeeded")
	}
	if !relayBanned(url) {
		t.Fatal("429 on upgrade was not cached")
	}
	for i := 0; i < 3; i++ {
		if _, err := p.EnsureRelay(url); err == nil {
			t.Fatal("banned relay dialled")
		}
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("relay hit %d times, want 1", got)
	}
}

// A relay that cannot be reached at all (what an offline phone sees) is not
// banned: the next round must try it again.
func TestPoolDoesNotBanUnreachableRelay(t *testing.T) {
	resetRelayBans(t)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	url := fmt.Sprintf("ws://%s", l.Addr())
	l.Close()

	p := nostr.NewSimplePool(context.Background(), poolDialGate())
	if _, err := p.EnsureRelay(url); err == nil {
		t.Fatal("dial to a closed port succeeded")
	}
	if relayBanned(url) {
		t.Fatal("connection refused was cached as a ban")
	}
}

func TestIsRelayRefusal(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want bool
	}{
		{&nostr.HandshakeStatusError{StatusCode: 429, Err: errors.New("x")}, true},
		{fmt.Errorf("wrap: %w", &nostr.HandshakeStatusError{StatusCode: 403, Err: errors.New("x")}), true},
		{&nostr.HandshakeStatusError{StatusCode: 503, Err: errors.New("x")}, true},
		{&nostr.HandshakeStatusError{StatusCode: 404, Err: errors.New("x")}, false},
		{fmt.Errorf("%w: rate-limited: slow down", negsync.ErrRefused), true},
		{errors.New("closed: you are banned"), true},
		// About the filter, not about us: must not ban the relay.
		{fmt.Errorf("%w: blocked: too many query results", negsync.ErrRefused), false},
		{errors.New("dial tcp: lookup relay.example: no such host"), false},
		{context.DeadlineExceeded, false},
		{nil, false},
	} {
		if got := isRelayRefusal(tc.err); got != tc.want {
			t.Errorf("isRelayRefusal(%v) = %v, want %v", tc.err, got, tc.want)
		}
	}
}

func TestRelayBanExpires(t *testing.T) {
	resetRelayBans(t)
	url := "wss://relay.example.com"
	relayBans.Store(nostr.NormalizeURL(url), time.Now().Add(-relayBanTTL-time.Second))
	if relayBanned(url) {
		t.Fatal("ban older than the TTL still applies")
	}
	noteRelayRefusal(url, &nostr.HandshakeStatusError{StatusCode: 429, Err: errors.New("x")})
	if !relayBanned("wss://relay.example.com/") {
		t.Fatal("fresh ban not seen through a differently written URL")
	}
}

func TestBulkReadsLeaveDamusOut(t *testing.T) {
	in := []string{"wss://relay.damus.io", "wss://Relay.Damus.io/", "wss://nos.lol", "wss://relay.primal.net"}
	got := withoutBulkReadExcluded(in)
	if want := []string{"wss://nos.lol", "wss://relay.primal.net"}; !slices.Equal(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}

	saved := config
	t.Cleanup(func() { config = saved })
	config.FeedSyncRelays = nil
	config.BlastrRelays = []string{"wss://relay.damus.io", "wss://nos.lol"}
	config.ImportSeedRelays = []string{"wss://relay.damus.io/", "wss://relay.primal.net"}
	fs := feedSyncRelays()
	slices.Sort(fs)
	if want := []string{"wss://nos.lol", "wss://relay.primal.net"}; !slices.Equal(fs, want) {
		t.Fatalf("feedSyncRelays() = %v, want %v", fs, want)
	}
}

// The apps pass 900 s; the relay runs its catch-up and feed rounds hourly.
func TestInboxPullIntervalFlooredToAnHour(t *testing.T) {
	dir := t.TempDir()
	empty := filepath.Join(dir, "empty.json")
	if err := os.WriteFile(empty, []byte("[]"), 0o600); err != nil {
		t.Fatal(err)
	}
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	npub, _ := nip19.EncodePublicKey(pk)
	for k, v := range map[string]string{
		"OWNER_NPUB":              npub,
		"IMPORT_SEED_RELAYS_FILE": empty,
		"BLASTR_RELAYS_FILE":      empty,
		"DM_RELAYS_FILE":          empty,
		"FEED_SYNC_RELAYS_FILE":   empty,
	} {
		t.Setenv(k, v)
	}
	for in, want := range map[string]int{"900": 3600, "60": 3600, "7200": 7200} {
		t.Setenv("INBOX_PULL_INTERVAL_SECONDS", in)
		if got := loadConfig().InboxPullIntervalSeconds; got != want {
			t.Errorf("INBOX_PULL_INTERVAL_SECONDS=%s → %d, want %d", in, got, want)
		}
	}
}
