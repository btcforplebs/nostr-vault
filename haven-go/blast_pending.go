package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Notes the outbox stored but no blastr relay accepted (the device was
// offline, or the relay stopped mid-blast). They are kept on disk and retried
// until one relay takes them, so a kiosk that loses its internet still sends
// the owner's notes out once it is back.

var (
	blastPendingPath    = "blast_pending.json" // relative to the relay data root, like wot_cache.json
	blastRetryInterval  = time.Minute
	blastRetryFirstWait = 10 * time.Second
)

const (
	blastPendingMax    = 500
	blastPendingMaxAge = 7 * 24 * time.Hour
)

type blastQueue struct {
	mu     sync.Mutex
	loaded bool
	events []nostr.Event
}

var pendingBlasts blastQueue

// loadLocked reads the queue from disk once per process.
func (q *blastQueue) loadLocked() {
	if q.loaded {
		return
	}
	q.loaded = true
	data, err := os.ReadFile(blastPendingPath)
	if err != nil {
		return
	}
	var events []nostr.Event
	if err := json.Unmarshal(data, &events); err != nil {
		slog.Warn("⚠️ unreadable blast queue, starting empty", "error", err)
		return
	}
	q.events = events
}

func (q *blastQueue) saveLocked() {
	data, err := json.Marshal(q.events)
	if err != nil {
		return
	}
	tmp := blastPendingPath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		slog.Error("🚫 could not save blast queue", "error", err)
		return
	}
	if err := os.Rename(tmp, blastPendingPath); err != nil {
		_ = os.Remove(tmp)
		slog.Error("🚫 could not save blast queue", "error", err)
	}
}

func (q *blastQueue) add(ev *nostr.Event) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.loadLocked()
	for _, e := range q.events {
		if e.ID == ev.ID {
			return
		}
	}
	q.events = append(q.events, *ev)
	if len(q.events) > blastPendingMax {
		q.events = q.events[len(q.events)-blastPendingMax:]
	}
	q.saveLocked()
	slog.Info("📮 note kept for a later blast", "id", ev.ID, "pending", len(q.events))
}

func (q *blastQueue) remove(id string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for i, e := range q.events {
		if e.ID == id {
			q.events = append(q.events[:i], q.events[i+1:]...)
			q.saveLocked()
			return
		}
	}
}

func (q *blastQueue) snapshot() []nostr.Event {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.loadLocked()
	return append([]nostr.Event(nil), q.events...)
}

// blastOrKeep blasts ev and queues it if no relay took it.
func blastOrKeep(ctx context.Context, ev *nostr.Event) {
	if len(config.BlastrRelays) == 0 {
		return
	}
	if blast(ctx, ev) == 0 {
		pendingBlasts.add(ev)
	}
}

// retryPendingBlasts runs for the relay's lifetime, re-blasting queued notes.
func retryPendingBlasts(ctx context.Context) {
	wait := blastRetryFirstWait
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		wait = blastRetryInterval
		retryPendingOnce(ctx)
	}
}

func retryPendingOnce(ctx context.Context) {
	if len(config.BlastrRelays) == 0 {
		return
	}
	cutoff := nostr.Timestamp(time.Now().Add(-blastPendingMaxAge).Unix())
	for _, ev := range pendingBlasts.snapshot() {
		if ctx.Err() != nil {
			return
		}
		if ev.CreatedAt < cutoff {
			slog.Warn("🗑️ dropping a note that never reached a relay", "id", ev.ID)
			pendingBlasts.remove(ev.ID)
			continue
		}
		if blast(ctx, &ev) > 0 {
			pendingBlasts.remove(ev.ID)
		}
	}
}
