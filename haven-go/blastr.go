package main

import (
	"context"
	"errors"
	"log/slog"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

func blast(ctx context.Context, ev *nostr.Event) {
	var successCount atomic.Int32
	var wg sync.WaitGroup
	timeout := time.Second * time.Duration(config.BlastrTimeoutSeconds)
	const maxRetries = 2

	for _, url := range config.BlastrRelays {
		wg.Add(1)
		go func(relayURL string) {
			defer wg.Done()
			if publishWithRetry(ctx, relayURL, ev, timeout, maxRetries) {
				successCount.Add(1)
			}
		}(url)
	}

	wg.Wait()
	slog.Info("🔫 blasted event", "id", ev.ID, "relays", successCount.Load())
}

func publishWithRetry(ctx context.Context, relayURL string, ev *nostr.Event, timeout time.Duration, maxRetries int) bool {
	for attempt := 0; attempt <= maxRetries; attempt++ {
		pubCtx, cancel := context.WithTimeout(ctx, timeout)
		relay, err := pool.EnsureRelay(relayURL)
		if err != nil {
			cancel()
			if attempt < maxRetries {
				backoff := time.Duration(math.Pow(2, float64(attempt))) * time.Second
				time.Sleep(backoff)
				continue
			}
			slog.Error("⛓️‍💥 error connecting to relay", "relay", relayURL, "error", err)
			return false
		}

		if err := relay.Publish(pubCtx, *ev); err != nil {
			cancel()
			if attempt < maxRetries {
				if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
					backoff := time.Duration(math.Pow(2, float64(attempt))) * time.Second
					time.Sleep(backoff)
					continue
				}
			}
			if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
				slog.Error("🚫 timeout publishing to relay", "relay", relayURL, "timeout", timeout, "attempt", attempt+1)
			} else {
				slog.Error("🚫 error publishing to relay", "relay", relayURL, "error", err, "attempt", attempt+1)
			}
			continue
		}
		cancel()
		return true
	}
	return false
}
