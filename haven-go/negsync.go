package main

import (
	"context"
	"log"
	"log/slog"
	"sync"
	"time"

	"github.com/barrydeen/haven/internal/negsync"
	"github.com/barrydeen/haven/internal/tombstones"
	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip11"
	"github.com/nbd-wtf/go-nostr/nip70"
)

// ─── Per-relay NIP-77 capability cache ──────────────────────────────────────
//
// NIP-11 documents are only trusted positively (they're often stale or
// missing); ground truth is attempt-based: a sync that times out on the
// NEG-OPEN handshake marks the relay unsupported for negCapRetryTTL, a
// successful sync marks it supported for the process lifetime. Transient
// errors (connect failures, mid-session timeouts) are never cached.

type negCap struct {
	supported bool
	checkedAt time.Time
}

var negCaps sync.Map // normalized relay URL → negCap

const negCapRetryTTL = 24 * time.Hour

// relaySupportsNegentropy reports whether a NIP-77 sync attempt against url
// is worthwhile. Unknown relays return true — the attempt itself is the
// probe. A NIP-11 document advertising NIP 77 short-circuits to a cached yes.
func relaySupportsNegentropy(ctx context.Context, url string) bool {
	key := nostr.NormalizeURL(url)
	if v, ok := negCaps.Load(key); ok {
		c := v.(negCap)
		if c.supported {
			return true
		}
		if time.Since(c.checkedAt) < negCapRetryTTL {
			return false
		}
		negCaps.Delete(key) // TTL expired — re-probe
	}

	// Positive fast-path hint only.
	ictx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if info, err := nip11.Fetch(ictx, url); err == nil {
		for _, n := range info.SupportedNIPs {
			// JSON numbers decode as float64; tolerate ints from odd relays.
			if f, ok := n.(float64); ok && int(f) == 77 {
				markNegentropySupported(url)
				return true
			}
			if i, ok := n.(int); ok && i == 77 {
				markNegentropySupported(url)
				return true
			}
		}
	}
	return true // unknown: attempt the sync, its outcome decides
}

func markNegentropySupported(url string) {
	negCaps.Store(nostr.NormalizeURL(url), negCap{supported: true, checkedAt: time.Now()})
}

func markNegentropyUnsupported(url string) {
	negCaps.Store(nostr.NormalizeURL(url), negCap{supported: false, checkedAt: time.Now()})
}

// ─── Per-relay upload memo ──────────────────────────────────────────────────
//
// Some relays acknowledge an EVENT with OK but never serve it back (silent
// policy drops, retention pruning), so their negentropy vector reports the
// same events missing on every round and a Both-direction sync re-uploads the
// identical set forever — 233 events/round to relay.nos.social in the field.
// Remember successful publishes per relay for the process lifetime and never
// re-send them. Growth is bounded by the sync window's event count per relay.

var negUploaded sync.Map // normalized relay URL → *sync.Map (event ID → struct{})

// uploadMemoFor returns the Sync option wiring url's upload memo.
func uploadMemoFor(url string) negsync.Option {
	v, _ := negUploaded.LoadOrStore(nostr.NormalizeURL(url), &sync.Map{})
	m := v.(*sync.Map)
	return negsync.WithUploadMemo(
		func(id string) bool { _, sent := m.Load(id); return sent },
		func(id string) { m.Store(id, struct{}{}) },
	)
}

// ─── Catch-up notification batching ─────────────────────────────────────────

// batchNotifier throttles 🔔NOTIFY markers during catch-up sync so a backlog
// import (first sync after being offline) doesn't fire hundreds of system
// notifications. Events older than NOTIFY_MAX_AGE_HOURS never notify; the
// first NOTIFY_BATCH_LIMIT qualifying events notify normally; the remainder
// collapse into one type=summary marker emitted by flush(announce=true). The
// live subscription path bypasses this entirely — real-time events always
// notify.
type batchNotifier struct {
	mu         sync.Mutex
	emitted    int
	suppressed int
}

func (n *batchNotifier) maybeNotify(ev *nostr.Event, recipient string) {
	if ev == nil {
		return
	}
	if !isNotifyableAge(ev) {
		return // old backlog, not news
	}
	if !isNotifyableKind(ev.Kind) {
		return // a kind the app has notifications switched off for
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.emitted < config.NotifyBatchLimit {
		n.emitted++
		emitInboxNotify(ev, recipient)
		return
	}
	n.suppressed++
}

// flush ends the batch, emitting a single summary marker for anything
// suppressed this round, and resets the counters for the next one. Clients that
// don't know type=summary ignore the line. No single recipient applies to a
// suppressed batch (it may span multiple whitelisted accounts), so the field is
// empty — clients already treat type=summary as account-agnostic.
//
// announce is false for rounds the user asked for (pull-to-refresh, vault
// refresh). Those are not a return from absence, and because every feed refresh
// requests one, announcing them fired "N more new items while you were away"
// as often as once a minute all day — while the app was open and the same
// events were already scrolling past. Suppression still applies on those
// rounds: the first NOTIFY_BATCH_LIMIT items notify, the rest stay silent
// rather than becoming a summary nobody was away for.
func (n *batchNotifier) flush(announce bool) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if announce && n.suppressed > 0 {
		log.Printf("🔔NOTIFY|type=summary|kind=0|author=|id=|recipient=|preview=%d more new items while you were away", n.suppressed)
	}
	n.emitted = 0
	n.suppressed = 0
}

// ─── Tombstone-aware RelayStore adapters ────────────────────────────────────
//
// negsync.Sync sees the local side through nostr.RelayStore. These adapters
// (a) widen QuerySync with eventstore.SetNegentropy so the backends don't
// truncate the ID vector at MaxLimit, (b) fold the tombstone set into the
// local vector as haves so intentionally-rejected events are never
// re-downloaded, and (c) route Publish through the same accept/reject rules
// as the live subscription, recording rejects as new tombstones.

// ─── In-memory temporary-rejection stub cache ──────────────────────────────
//
// WoT / blacklist rejections are deliberately NOT tombstoned: membership
// changes, so a reply rejected by a fresh instance's half-built WoT must stay
// re-fetchable. But if such a reject is simply dropped, the negentropy vector
// never lists it as a have, so every reconciliation round re-downloads the
// same non-WoT backlog and re-rejects it — a per-minute 100% CPU / bandwidth
// loop. tempRejects folds those IDs into the local vector like tombstones, but
// only in memory. Each entry also records the author so reevaluate() can drop
// stubs when the WoT/blacklist admits that author mid-process (the WoT is
// re-computed on a 24h ticker, not just at restart), restoring the
// "transient rejects stay re-fetchable when membership changes" guarantee.
// Stubs never leave the vector (QueryEvents can't find them), so cached IDs
// are never uploaded.
type rejectEntry struct {
	ts     nostr.Timestamp // event created_at — vector key and prune bound
	pubkey string          // author — re-checked against the WoT each round
}

type tempRejects struct {
	m sync.Map // event ID → rejectEntry
}

func (t *tempRejects) add(id string, ts nostr.Timestamp, pubkey string) {
	if t == nil {
		return
	}
	t.m.Store(id, rejectEntry{ts: ts, pubkey: pubkey})
}

// reevaluate drops the stub for any cached reject whose author now passes the
// author-level accept gates (in WoT and not blacklisted), so the next
// negentropy round re-offers and re-imports it. Called once per catch-up round
// with the live WoT/blacklist state. Without this a reply from an author who
// entered the WoT after the reject stayed hidden until process restart — the
// negentropy stub made it a permanent "have" that nothing ever re-fetched.
func (t *tempRejects) reevaluate(admit func(pubkey string) bool) {
	if t == nil {
		return
	}
	t.m.Range(func(k, v any) bool {
		if admit(v.(rejectEntry).pubkey) {
			t.m.Delete(k)
		}
		return true
	})
}

// remove drops an ID once it has been accepted for real (e.g. after the WoT
// admitted its author within the same process run) so QuerySync doesn't list
// the same event both from the DB and as a stub.
func (t *tempRejects) remove(id string) {
	if t == nil {
		return
	}
	t.m.Delete(id)
}

// prune drops cached rejections older than cutoff. Called once per sync round
// with the negentropy window's lower bound: an event older than the window is
// never offered by the remote, so its stub can never be needed. Without this
// the map grows without bound for the process's lifetime — a slow memory leak
// and, since appendStubs ranges the whole map per QuerySync, a creeping CPU
// cost in the very path this cache exists to keep cheap. sync.Map permits
// Delete during Range.
func (t *tempRejects) prune(cutoff nostr.Timestamp) {
	if t == nil {
		return
	}
	t.m.Range(func(k, v any) bool {
		if v.(rejectEntry).ts < cutoff {
			t.m.Delete(k)
		}
		return true
	})
}

// appendStubs adds a minimal {ID, CreatedAt} stub for each cached rejection
// inside the filter's time bounds, mirroring appendTombstoneStubs.
func (t *tempRejects) appendStubs(evs []*nostr.Event, f nostr.Filter) []*nostr.Event {
	if t == nil {
		return evs
	}
	var since, until nostr.Timestamp
	if f.Since != nil {
		since = *f.Since
	}
	if f.Until != nil {
		until = *f.Until
	}
	t.m.Range(func(k, v any) bool {
		ts := v.(rejectEntry).ts
		if since != 0 && ts < since {
			return true
		}
		if until != 0 && ts > until {
			return true
		}
		evs = append(evs, &nostr.Event{ID: k.(string), CreatedAt: ts})
		return true
	})
	return evs
}

// inboxNegStore adapts the inbox+chat DBs for Down-direction tagged-event sync.
type inboxNegStore struct {
	inbox    eventstore.RelayWrapper
	chat     eventstore.RelayWrapper
	tombs    *tombstones.Set
	rejects  *tempRejects
	notifier *batchNotifier
	advance  func(nostr.Timestamp)
}

func (s *inboxNegStore) QuerySync(ctx context.Context, f nostr.Filter) ([]*nostr.Event, error) {
	ctx = eventstore.SetNegentropy(ctx)
	evs, err := s.inbox.QuerySync(ctx, f)
	if err != nil {
		return nil, err
	}
	chatEvs, err := s.chat.QuerySync(ctx, f)
	if err != nil {
		return nil, err
	}
	evs = append(evs, chatEvs...)
	evs = appendTombstoneStubs(evs, s.tombs, f)
	evs = s.rejects.appendStubs(evs, f)
	return evs, nil
}

func (s *inboxNegStore) QueryEvents(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
	// Only exercised by the up direction (unused for Down sync). Tombstone
	// IDs resolve to nothing here, so vector stubs can never be published.
	return fanInQueryEvents(ctx, f, s.inbox, s.chat)
}

func (s *inboxNegStore) Publish(ctx context.Context, ev nostr.Event) error {
	c := classifyInboxEvent(ctx, &ev)
	if !c.accept {
		// Only rejections based on immutable event content are tombstoned.
		// WoT/blacklist rejections stay re-fetchable: a half-built WoT on a
		// fresh instance must not permanently hide replies and mentions.
		if c.reason.permanent() {
			return s.tombs.Add(ev.ID, ev.CreatedAt)
		}
		// Transient reject: don't persist it, but remember it (with the author)
		// in memory for this process run so the negentropy vector lists it as a
		// have and the remote stops re-offering it every round (the 100% CPU
		// loop). reevaluate() drops it again if the author is later admitted.
		s.rejects.add(ev.ID, ev.CreatedAt, ev.PubKey)
		return nil
	}
	dst := s.inbox
	if c.chat {
		dst = s.chat
	}
	if isDuplicate(ctx, dst, &ev) {
		s.rejects.remove(ev.ID) // already stored; clear any stale stub
		return nil
	}
	if err := dst.Publish(ctx, ev); err != nil {
		log.Println("🚫 error importing synced note", ev.ID, ":", err)
		return err // keep the stub (if any): a failed store must not re-loop
	}
	// Stored for real — now safe to drop the stub so QuerySync doesn't list this
	// event both from the DB and from the cache (a duplicate vector entry).
	s.rejects.remove(ev.ID)
	if s.advance != nil {
		s.advance(ev.CreatedAt)
	}
	// logInboxImport gated on c.notify so self-tagged events don't light up
	// the relay-activity red dot — same reasoning as processInboxEvent. Also
	// gated on isNotifyableAge: this is the negentropy catch-up path, exactly
	// where a large stuck backlog (e.g. one that just started succeeding after
	// an unrelated bug fix) would otherwise light up the dot for every old
	// item — maybeNotify already skipped the actual notification for these,
	// but previously still let logInboxImport through unconditionally.
	if c.notify && isNotifyableAge(&ev) {
		logInboxImport(&ev)
		if s.notifier != nil {
			s.notifier.maybeNotify(&ev, c.recipient)
		}
	}
	return nil
}

// outboxNegStore adapts the outbox DB for Both-direction owner-event sync.
type outboxNegStore struct {
	outbox  eventstore.RelayWrapper
	tombs   *tombstones.Set
	advance func(nostr.Timestamp)
}

func (s *outboxNegStore) QuerySync(ctx context.Context, f nostr.Filter) ([]*nostr.Event, error) {
	ctx = eventstore.SetNegentropy(ctx)
	evs, err := s.outbox.QuerySync(ctx, f)
	if err != nil {
		return nil, err
	}
	evs = appendTombstoneStubs(evs, s.tombs, f)
	return evs, nil
}

// QueryEvents is the up-direction source: only broadcastable events may leave
// the device. Gift wraps, ephemeral kinds, and NIP-70 protected events are
// dropped — they may be listed as haves in the vector, but they are never
// yielded for upload.
func (s *outboxNegStore) QueryEvents(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
	ch, err := s.outbox.QueryEvents(ctx, f)
	if err != nil {
		return nil, err
	}
	out := make(chan *nostr.Event)
	go func() {
		defer close(out)
		for ev := range ch {
			if ev.Kind == nostr.KindGiftWrap || nostr.IsEphemeralKind(ev.Kind) || nip70.IsProtected(*ev) {
				continue
			}
			select {
			case out <- ev:
			case <-ctx.Done():
				return
			}
		}
	}()
	return out, nil
}

func (s *outboxNegStore) Publish(ctx context.Context, ev nostr.Event) error {
	// No tombstones here: the sync filter is authors=owner, so rejects are
	// either relay misbehavior or whitelist/blacklist state that can change —
	// both must stay re-fetchable rather than be permanently suppressed.
	if _, ok := config.WhitelistedPubKeys[ev.PubKey]; !ok {
		return nil // relay returned a non-owner event
	}
	if isBlacklisted(ev.PubKey) {
		return nil
	}
	if isDuplicate(ctx, s.outbox, &ev) {
		return nil
	}
	if err := s.outbox.Publish(ctx, ev); err != nil {
		log.Println("🚫 error importing synced owner event", ev.ID, ":", err)
		return err
	}
	slog.Debug("📤 imported owner event (negentropy)", "kind", ev.Kind, "id", ev.ID)
	if s.advance != nil {
		s.advance(ev.CreatedAt)
	}
	return nil
}

// appendTombstoneStubs adds a minimal {ID, CreatedAt} stub per tombstone
// within the filter's time bounds — the only fields the negentropy vector
// reads. Stubs never leave the vector: QueryEvents can't find them.
func appendTombstoneStubs(evs []*nostr.Event, tombs *tombstones.Set, f nostr.Filter) []*nostr.Event {
	if tombs == nil {
		return evs
	}
	var since, until nostr.Timestamp
	if f.Since != nil {
		since = *f.Since
	}
	if f.Until != nil {
		until = *f.Until
	}
	tombs.Range(since, until, func(id string, ts nostr.Timestamp) bool {
		evs = append(evs, &nostr.Event{ID: id, CreatedAt: ts})
		return true
	})
	return evs
}

// fanInQueryEvents merges QueryEvents streams from multiple stores.
func fanInQueryEvents(ctx context.Context, f nostr.Filter, stores ...eventstore.RelayWrapper) (chan *nostr.Event, error) {
	out := make(chan *nostr.Event)
	var wg sync.WaitGroup
	for _, st := range stores {
		ch, err := st.QueryEvents(ctx, f)
		if err != nil {
			continue
		}
		wg.Add(1)
		go func(ch chan *nostr.Event) {
			defer wg.Done()
			for ev := range ch {
				select {
				case out <- ev:
				case <-ctx.Done():
					return
				}
			}
		}(ch)
	}
	go func() {
		wg.Wait()
		close(out)
	}()
	return out, nil
}
