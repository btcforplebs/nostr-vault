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
//
// Each note waits longer after every failed try (1 min, 2 min, 4 min, ... up
// to 6 h), and the wait is saved with it. A note that every relay refused is
// dropped: the old fixed one-minute retry re-sent a refused note to every
// relay 1,440 times a day for seven days.

var (
	blastPendingFile    = "blast_queue.json" // in the relay data root, like wot_cache.json
	blastRetryInterval  = time.Minute        // how often the queue is checked for notes that are due
	blastRetryFirstWait = 10 * time.Second
	blastClock          = time.Now // tests move it forward
)

const (
	blastPendingMax    = 500
	blastPendingMaxAge = 7 * 24 * time.Hour
	blastBackoffFirst  = time.Minute
	blastBackoffMax    = 6 * time.Hour
)

type pendingBlast struct {
	Event    nostr.Event `json:"event"`
	QueuedAt int64       `json:"queued_at"` // unix seconds; age counts from here, not created_at
	Attempts int         `json:"attempts,omitempty"`
	NextAt   int64       `json:"next_at,omitempty"` // unix seconds; not tried again before this
}

// blastBackoff is the wait after the attempts-th failed try (1-based).
func blastBackoff(attempts int) time.Duration {
	wait := blastBackoffFirst
	for i := 1; i < attempts && wait < blastBackoffMax; i++ {
		wait *= 2
	}
	return min(wait, blastBackoffMax)
}

// blastQueue belongs to one relay start: initRelays opens it with the
// absolute path of the current account's data root, so a blast still in
// flight after an account switch lands in its own account's file.
type blastQueue struct {
	mu    sync.Mutex
	path  string
	items []pendingBlast
	local eventQuerier // the outbox store: a queued list it holds a newer copy of is dropped
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
	now := blastClock()
	q.items = append(q.items, pendingBlast{Event: *ev, QueuedAt: now.Unix(), Attempts: 1,
		NextAt: now.Add(blastBackoff(1)).Unix()})
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

// failed records one more failed try for id and pushes its next try back.
func (q *blastQueue) failed(id string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for i := range q.items {
		if q.items[i].Event.ID == id {
			q.items[i].Attempts++
			q.items[i].NextAt = blastClock().Add(blastBackoff(q.items[i].Attempts)).Unix()
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

// blastOrKeep blasts ev and queues it if no relay took it and at least one
// could not be reached. A note every relay refused is not queued.
func blastOrKeep(ctx context.Context, q *blastQueue, ev *nostr.Event) {
	if len(config.BlastrRelays) == 0 {
		return
	}
	res := blast(ctx, ev)
	if res.accepted == 0 && res.failed > 0 {
		q.add(ev)
	} else if res.accepted == 0 {
		slog.Warn("🗑️ every relay refused the note, not keeping it", "id", ev.ID)
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
	now := blastClock().Unix()
	cutoff := blastClock().Add(-blastPendingMaxAge).Unix()
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
		if p.NextAt > now {
			continue
		}
		// A list (kind 3, 10002, ...) may have been edited since it was
		// queued, here or on another device. Sending the old copy again would
		// undo that edit, so look for a newer one first.
		switch checkListResend(ctx, q.local, config.BlastrRelays, &ev) {
		case listDrop:
			slog.Warn("🗑️ a newer copy of a queued list exists, dropping ours", "id", ev.ID, "kind", ev.Kind)
			q.remove(ev.ID)
			continue
		case listNoCheck:
			if ctx.Err() == nil {
				q.failed(ev.ID) // no relay answered the check: not sent, tried again later
			}
			continue
		}
		switch res := blast(ctx, &ev); {
		case res.accepted > 0:
			q.remove(ev.ID)
		case res.failed == 0:
			slog.Warn("🗑️ every relay refused a queued note, dropping it", "id", ev.ID)
			q.remove(ev.ID)
		case ctx.Err() == nil:
			q.failed(ev.ID)
		}
	}
}
