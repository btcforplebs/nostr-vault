//go:build cshared

package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// TestRelayRestartUnderTraffic drives the real exported StartRelayC /
// StopRelayC the way the iOS app does on every return to the foreground,
// while WebSocket clients keep publishing and querying. Run with -race:
//
//	go test -tags cshared -race -run TestRelayRestartUnderTraffic .
//
// Before the fix, khatru's connection goroutines outlived each stop
// (Server.Shutdown ignores hijacked WebSockets) and kept reading Badger
// after CloseDBs and while the next cycle reopened it. On the phone that
// ended in "found pointer to free object" GC aborts.
func TestRelayRestartUnderTraffic(t *testing.T) {
	cycles := 12
	if testing.Short() {
		cycles = 4
	}

	dir := t.TempDir()
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	npub, _ := nip19.EncodePublicKey(pk)
	empty := filepath.Join(dir, "none.json")
	if err := os.WriteFile(empty, []byte("[]"), 0o644); err != nil {
		t.Fatal(err)
	}
	port := freePort(t)
	wd, _ := os.Getwd()
	t.Cleanup(func() { os.Chdir(wd) })
	for k, v := range map[string]string{
		"DATABASE_PATH":           filepath.Join(dir, "db"),
		"DB_ENGINE":               "badger",
		"OWNER_NPUB":              npub,
		"RELAY_PORT":              strconv.Itoa(port),
		"RELAY_BIND_ADDRESS":      "127.0.0.1",
		"IMPORT_SEED_RELAYS_FILE": empty,
		"BLASTR_RELAYS_FILE":      empty,
		"DM_RELAYS_FILE":          empty,
		"FEED_SYNC_RELAYS_FILE":   empty,
		"WOT_CACHE_PATH":          filepath.Join(dir, "wot_cache.json"),
	} {
		t.Setenv(k, v)
	}

	url := fmt.Sprintf("ws://127.0.0.1:%d", port)
	var published, queried atomic.Int64
	stop := make(chan struct{})
	var clients sync.WaitGroup
	for w := 0; w < 4; w++ {
		clients.Add(1)
		go func(w int) {
			defer clients.Done()
			trafficLoop(stop, url, sk, pk, w, &published, &queried)
		}(w)
	}

	for i := 0; i < cycles; i++ {
		StartRelayC(false)
		if relayLC.current.Load() == nil {
			buf := make([]byte, 1<<20)
			t.Fatalf("cycle %d: relay did not start; goroutines:\n%s", i, buf[:runtime.Stack(buf, true)])
		}
		waitForPort(t, port)
		before := published.Load()
		deadline := time.Now().Add(5 * time.Second)
		for published.Load()-before < 8 && time.Now().Before(deadline) {
			time.Sleep(10 * time.Millisecond) // let traffic land on this cycle
		}
		if published.Load() == before {
			t.Fatalf("cycle %d: no event reached the relay", i)
		}
		StopRelayC() // mid-traffic, as on a return to the foreground

		// Stopped means stopped: no client may still be writing through a
		// WebSocket the stop left open.
		afterStop := published.Load()
		time.Sleep(200 * time.Millisecond)
		if n := published.Load() - afterStop; n > 0 {
			t.Fatalf("cycle %d: %d events accepted after StopRelayC returned", i, n)
		}
	}
	close(stop)
	clients.Wait()

	// The last cycle must drain fully: goroutines gone, stores closed.
	relayLC.mu.Lock()
	ok := relayLC.awaitDrained(15 * time.Second)
	relayLC.mu.Unlock()
	if !ok {
		t.Fatal("last cycle never drained")
	}
	if published.Load() == 0 || queried.Load() == 0 {
		t.Fatalf("no traffic reached the relay (published %d, queried %d)", published.Load(), queried.Load())
	}
	t.Logf("%d cycles, %d events published, %d queries answered", cycles, published.Load(), queried.Load())
}

// trafficLoop keeps one client connected and busy, reconnecting whenever a
// stop drops it: one EVENT then one REQ per round.
func trafficLoop(stop <-chan struct{}, url, sk, pk string, w int, published, queried *atomic.Int64) {
	for n := 0; ; n++ {
		select {
		case <-stop:
			return
		default:
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		r, err := nostr.RelayConnect(ctx, url)
		if err != nil {
			cancel()
			time.Sleep(10 * time.Millisecond)
			continue
		}
		for j := 0; j < 50; j++ {
			ev := nostr.Event{
				PubKey:    pk,
				CreatedAt: nostr.Now(),
				Kind:      1,
				Content:   fmt.Sprintf("restart traffic %d/%d/%d", w, n, j),
			}
			ev.Sign(sk)
			if r.Publish(ctx, ev) == nil {
				published.Add(1)
			}
			if evs, err := r.QuerySync(ctx, nostr.Filter{Authors: []string{pk}, Kinds: []int{1}, Limit: 20}); err == nil && len(evs) > 0 {
				queried.Add(1)
			}
			if ctx.Err() != nil || !r.IsConnected() {
				break
			}
		}
		r.Close()
		cancel()
	}
}

func freePort(t *testing.T) int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func waitForPort(t *testing.T, port int) {
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		c, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
		if err == nil {
			c.Close()
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("relay port %d never opened", port)
}
