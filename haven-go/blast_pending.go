package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Notes the outbox stored but no blastr relay accepted (the device was
// offline, or the relay stopped mid-blast). They are kept on disk and retried
// until one relay takes them, so a kiosk that loses its internet still sends
// the owner's notes out once it is back.

var (
	blastPendingFile    = "blast_queue.json" // in the relay data root, like wot_cache.json
	blastRetryInterval  = time.Minute
	blastRetryFirstWait = 10 * time.Second
)

const (
	blastPendingMax    = 500
	blastPendingMaxAge = 7 * 24 * time.Hour
)

type pendingBlast struct {
	Event    nostr.Event `json:"event"`
	QueuedAt int64       `json:"queued_at"` // unix seconds; age counts from here, not created_at
}

// blastQueue belongs to one relay start: initRelays opens it with the
// absolute path of the current account's data root, so a blast still in
// flight after an account switch lands in its own account's file.
type blastQueue struct {
	mu    sync.Mutex
	path  string
	items []pendingBlast
}

func openBlastQueue(file string) *blastQueue {
	path, err := filepath.Abs(file)
	if err != nil {
		path = file
	}
	q := &blastQueue{path: path}
	data, err := os.ReadFile(path)
	if err != nil {
		return q
	}
	if err := json.Unmarshal(data, &q.items); err != nil {
		slog.Warn("⚠️ unreadable blast queue, starting empty", "error", err)
		q.items = nil
	}
	return q
}

func (q *blastQueue) saveLocked() {
	data, err := json.Marshal(q.items)
	if err != nil {
		return
	}
	tmp := q.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		slog.Error("🚫 could not save blast queue", "error", err)
		return
	}
	if err := os.Rename(tmp, q.path); err != nil {
		_ = os.Remove(tmp)
		slog.Error("🚫 could not save blast queue", "error", err)
	}
}

func (q *blastQueue) add(ev *nostr.Event) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, p := range q.items {
		if p.Event.ID == ev.ID {
			return
		}
	}
	if len(q.items) >= blastPendingMax {
		// Keep the ones already waiting: they have waited longest to get out.
		slog.Warn("⚠️ blast queue full, not keeping note", "id", ev.ID)
		return
	}
	q.items = append(q.items, pendingBlast{Event: *ev, QueuedAt: time.Now().Unix()})
	q.saveLocked()
	slog.Info("📮 note kept for a later blast", "id", ev.ID, "pending", len(q.items))
}

func (q *blastQueue) remove(id string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for i, p := range q.items {
		if p.Event.ID == id {
			q.items = append(q.items[:i], q.items[i+1:]...)
			q.saveLocked()
			return
		}
	}
}

func (q *blastQueue) snapshot() []pendingBlast {
	q.mu.Lock()
	defer q.mu.Unlock()
	return append([]pendingBlast(nil), q.items...)
}

// blastOrKeep blasts ev and queues it if no relay took it.
func blastOrKeep(ctx context.Context, q *blastQueue, ev *nostr.Event) {
	if len(config.BlastrRelays) == 0 {
		return
	}
	if blast(ctx, ev) == 0 {
		q.add(ev)
	}
}

// retryPendingBlasts runs for the relay's lifetime, re-blasting queued notes.
func retryPendingBlasts(ctx context.Context, q *blastQueue) {
	wait := blastRetryFirstWait
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		wait = blastRetryInterval
		retryPendingOnce(ctx, q)
	}
}

func retryPendingOnce(ctx context.Context, q *blastQueue) {
	if len(config.BlastrRelays) == 0 {
		return
	}
	cutoff := time.Now().Add(-blastPendingMaxAge).Unix()
	for _, p := range q.snapshot() {
		if ctx.Err() != nil {
			return
		}
		ev := p.Event
		// The file is on disk: check it is still a valid note from this
		// account before sending it anywhere.
		_, whitelisted := config.WhitelistedPubKeys[ev.PubKey]
		if ok, _ := ev.CheckSignature(); !ok || !ev.CheckID() || !whitelisted {
			slog.Warn("🗑️ dropping a queued note that is not this account's", "id", ev.ID)
			q.remove(ev.ID)
			continue
		}
		if p.QueuedAt < cutoff {
			slog.Warn("🗑️ dropping a note that never reached a relay", "id", ev.ID)
			q.remove(ev.ID)
			continue
		}
		if blast(ctx, &ev) > 0 {
			q.remove(ev.ID)
		}
	}
}
