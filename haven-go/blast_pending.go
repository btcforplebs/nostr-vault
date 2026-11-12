package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/barrydeen/haven/pkg/runsafe"
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
	// The outbox hands stored notes to a fixed pool: blastPoolWorkers blasts
	// at a time (each one goes to every blastr relay, so that many sends per
	// relay), and at most blastPoolQueue waiting. One goroutine per note let a
	// burst of 38,808 notes on .99 park 185,349 sends in go-nostr's
	// Relay.Write with a 2-3 GB heap (RESEARCH/NV_MAC_RELAY_PROFILE_2026_11_12.md).
	blastPoolWorkers = 4
	blastPoolQueue   = 512
	// A queue longer than blastPendingMax (only the vault's accounts' notes go past it) is
	// saved at most this often, not on every change: rewriting a file of
	// thousands of notes per note is quadratic.
	blastBatchedSaveEvery = time.Second

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
	ids   map[string]struct{} // the queued ids, so a long queue checks a note in O(1)
	local eventQuerier        // the outbox store: a queued list it holds a newer copy of is dropped

	dirty     bool        // a change not yet on disk (long queues only, see persistLocked)
	saveTimer *time.Timer // a batched save is scheduled
	dropped   int         // notes not kept since the queue was last below blastPendingMax
}

// isVaultAccountNote: a note from the owner or any of the vault's other
// accounts (the whitelist) is never dropped for space. The blast is how it
// leaves this device, and a note the pool could not take has had no try yet.
func isVaultAccountNote(ev *nostr.Event) bool {
	_, ok := whitelist()[ev.PubKey]
	return ok
}

func openBlastQueue(file string) *blastQueue {
	path, err := filepath.Abs(file)
	if err != nil {
		path = file
	}
	q := &blastQueue{path: path, ids: map[string]struct{}{}}
	data, err := os.ReadFile(path)
	if err != nil {
		return q
	}
	if err := json.Unmarshal(data, &q.items); err != nil {
		slog.Warn("⚠️ unreadable blast queue, starting empty", "error", err)
		q.items = nil
	}
	for _, p := range q.items {
		q.ids[p.Event.ID] = struct{}{}
	}
	return q
}

// persistLocked saves the queue: at once while it is short (as it always
// was), batched to once per blastBatchedSaveEvery while it is long.
func (q *blastQueue) persistLocked() {
	if q.dropped > 0 && len(q.items) < blastPendingMax {
		slog.Warn("⚠️ blast queue has room again", "notes_not_kept", q.dropped)
		q.dropped = 0
	}
	if len(q.items) <= blastPendingMax {
		q.saveLocked()
		return
	}
	q.dirty = true
	if q.saveTimer == nil {
		q.saveTimer = time.AfterFunc(blastBatchedSaveEvery, q.flush)
	}
}

// flush writes any batched change now.
func (q *blastQueue) flush() {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.saveTimer != nil {
		q.saveTimer.Stop()
		q.saveTimer = nil
	}
	if q.dirty {
		q.saveLocked()
	}
}

func (q *blastQueue) saveLocked() {
	q.dirty = false
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

// add keeps ev after a blast no relay took (one failed try).
func (q *blastQueue) add(ev *nostr.Event) {
	now := blastClock()
	q.keep(ev, pendingBlast{Event: *ev, QueuedAt: now.Unix(), Attempts: 1, NextAt: now.Add(blastBackoff(1)).Unix()})
}

// keepUntried keeps ev for the next retry round without a try: the pool was
// full, or the relay stopped before a worker reached it.
func (q *blastQueue) keepUntried(ev *nostr.Event) {
	now := blastClock()
	q.keep(ev, pendingBlast{Event: *ev, QueuedAt: now.Unix(), NextAt: now.Unix()})
}

// idsLocked is the queued-id index, rebuilt if items was set without it.
func (q *blastQueue) idsLocked() map[string]struct{} {
	if q.ids == nil || len(q.ids) != len(q.items) {
		q.ids = make(map[string]struct{}, len(q.items))
		for _, p := range q.items {
			q.ids[p.Event.ID] = struct{}{}
		}
	}
	return q.ids
}

func (q *blastQueue) keep(ev *nostr.Event, p pendingBlast) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if _, ok := q.idsLocked()[ev.ID]; ok {
		return
	}
	if len(q.items) >= blastPendingMax && !isVaultAccountNote(ev) {
		// Keep the ones already waiting: they have waited longest to get out.
		// The vault's own accounts' notes are always kept (isVaultAccountNote);
		// this is for a key that is no longer one of them. One line for the
		// first, one count when there is room again.
		if q.dropped == 0 {
			slog.Warn("⚠️ blast queue full, not keeping other accounts' notes for now", "id", ev.ID)
		}
		q.dropped++
		return
	}
	q.items = append(q.items, p)
	q.ids[ev.ID] = struct{}{}
	q.persistLocked()
	if len(q.items) <= blastPendingMax {
		slog.Info("📮 note kept for a later blast", "id", ev.ID, "pending", len(q.items))
	}
}

func (q *blastQueue) remove(id string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if _, ok := q.idsLocked()[id]; !ok {
		return
	}
	for i, p := range q.items {
		if p.Event.ID == id {
			q.items = append(q.items[:i], q.items[i+1:]...)
			delete(q.ids, id)
			q.persistLocked()
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
			q.persistLocked()
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

// newBlastSender is how the outbox hands a stored note to the blastr: a
// fixed pool of blastPoolWorkers, with at most blastPoolQueue notes waiting.
// It never blocks the caller (the relay is answering a client).
//
//   - Queue full: the note goes to the blast queue (blast_queue.json), due
//     at the next retry round (at most a minute). Notes from the vault's
//     accounts (owner and whitelist) are always kept there; a note from a
//     key that is no longer one of them is kept up to blastPendingMax.
//   - Relay stopping (ctx done): the notes still waiting go to the blast
//     queue too, and are sent on the next start.
//
// done closes once every worker has stopped.
func newBlastSender(ctx context.Context, q *blastQueue) (send func(*nostr.Event), done <-chan struct{}) {
	work := make(chan *nostr.Event, blastPoolQueue)
	var wg sync.WaitGroup
	stopped := make(chan struct{})
	for range blastPoolWorkers {
		wg.Add(1)
		runsafe.Go("blast-worker", func() {
			defer wg.Done()
			for {
				select {
				case <-ctx.Done():
					keepWaitingBlasts(work, q)
					return
				case ev := <-work:
					if ctx.Err() != nil {
						q.keepUntried(ev)
						continue
					}
					blastOrKeep(ctx, q, ev)
				}
			}
		})
	}
	go func() { wg.Wait(); close(stopped) }()
	return func(ev *nostr.Event) {
		if ctx.Err() != nil {
			q.keepUntried(ev)
			q.flush()
			return
		}
		select {
		case work <- ev:
			// Stopped meanwhile: the workers may have drained and gone.
			if ctx.Err() != nil {
				keepWaitingBlasts(work, q)
			}
		default:
			q.keepUntried(ev)
		}
	}, stopped
}

// keepWaitingBlasts moves the notes still in the pool's queue to the blast
// queue and writes it.
func keepWaitingBlasts(work chan *nostr.Event, q *blastQueue) {
	for {
		select {
		case ev := <-work:
			q.keepUntried(ev)
		default:
			q.flush()
			return
		}
	}
}

// retryPendingBlasts runs for the relay's lifetime, re-blasting queued notes.
func retryPendingBlasts(ctx context.Context, q *blastQueue) {
	wait := blastRetryFirstWait
	for {
		select {
		case <-ctx.Done():
			q.flush()
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
		_, whitelisted := whitelist()[ev.PubKey]
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
