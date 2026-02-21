package main

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

func blast(ctx context.Context, ev *nostr.Event) {
	var successCount int
	for _, url := range config.BlastrRelays {
		timeout := time.Second * time.Duration(config.BlastrTimeoutSeconds)
		ctx, cancel := context.WithTimeout(ctx, timeout)
		relay, err := pool.EnsureRelay(url)
		if err != nil {
			cancel()
			slog.Error("⛓️‍💥 error connecting to relay", "relay", url, "error", err)
			continue
		}
		if err := relay.Publish(ctx, *ev); err != nil {
			if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
				slog.Error("🚫 timeout publishing to relay", "relay", url, "timeout", timeout)
			} else {
				slog.Error("🚫 error publishing to relay", "relay", url, "error", err)
			}
		} else {
			successCount++
		}
		cancel()
	}
	slog.Info("🔫 blasted event", "id", ev.ID, "relays", successCount)
}
