package main

import (
	"context"
	"errors"
	"log/slog"
	"math"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/runsafe"
)

// blastResult counts how each blastr relay answered one publish.
type blastResult struct {
	accepted int
	rejected int // answered OK false: sending the same note again gets the same answer
	failed   int // no answer (offline, timeout, dropped socket): worth retrying later
}

type publishOutcome int

const (
	publishFailed publishOutcome = iota
	publishAccepted
	publishRejected
)

// isRejection reports whether a publish error is the relay's own OK false.
// go-nostr reports those as "msg: <reason>". A rate limit is the one answer
// that changes with time, so it counts as a failure to retry later.
func isRejection(err error) bool {
	msg := err.Error()
	return strings.HasPrefix(msg, "msg: ") && !strings.Contains(msg, "rate-limited")
}

// blast publishes ev to every blastr relay and reports how they answered.
func blast(ctx context.Context, ev *nostr.Event) blastResult {
	var accepted, rejected, failed atomic.Int32
	var wg sync.WaitGroup
	timeout := time.Second * time.Duration(config.BlastrTimeoutSeconds)
	const maxRetries = 2

	for _, url := range config.BlastrRelays {
		wg.Add(1)
		go func(relayURL string) {
			// wg.Done must run even if publishing panics, otherwise
			// wg.Wait() below blocks this goroutine's parent forever.
			defer wg.Done()
			outcome := publishFailed
			runsafe.Run("blastr.publish", func() {
				outcome = publishWithRetry(ctx, relayURL, ev, timeout, maxRetries)
			})
			switch outcome {
			case publishAccepted:
				accepted.Add(1)
			case publishRejected:
				rejected.Add(1)
			default:
				failed.Add(1)
			}
		}(url)
	}

	wg.Wait()
	res := blastResult{accepted: int(accepted.Load()), rejected: int(rejected.Load()), failed: int(failed.Load())}
	slog.Info("🔫 blasted event", "id", ev.ID, "kind", ev.Kind, "relays", res.accepted, "rejected", res.rejected, "failed", res.failed)
	return res
}

// publishWithRetry tries one relay up to maxRetries+1 times, backing off
// between tries. A rejection ends it at once: the relay has read the note and
// said no, and the old back-to-back retries sent the same bytes three times
// for the same answer.
func publishWithRetry(ctx context.Context, relayURL string, ev *nostr.Event, timeout time.Duration, maxRetries int) publishOutcome {
	sleep := func(attempt int) bool {
		select {
		case <-ctx.Done():
			return false
		case <-time.After(time.Duration(math.Pow(2, float64(attempt))) * time.Second):
			return true
		}
	}
	for attempt := 0; attempt <= maxRetries; attempt++ {
		pubCtx, cancel := context.WithTimeout(ctx, timeout)
		relay, err := pool.EnsureRelay(relayURL)
		if err != nil {
			cancel()
			if attempt < maxRetries && sleep(attempt) {
				continue
			}
			slog.Error("⛓️‍💥 error connecting to relay", "relay", relayURL, "error", err)
			return publishFailed
		}

		err = relay.Publish(pubCtx, *ev)
		cancel()
		if err == nil {
			return publishAccepted
		}
		if isRejection(err) {
			slog.Warn("🚫 relay rejected event, not retrying", "relay", relayURL, "id", ev.ID, "reason", err)
			return publishRejected
		}
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
			slog.Error("🚫 timeout publishing to relay", "relay", relayURL, "timeout", timeout, "attempt", attempt+1)
		} else {
			slog.Error("🚫 error publishing to relay", "relay", relayURL, "error", err, "attempt", attempt+1)
		}
		if attempt < maxRetries && !sleep(attempt) {
			break
		}
	}
	return publishFailed
}
