// Package negsync implements client-side NIP-77 negentropy reconciliation
// against a remote relay, adapted from the vendored nip77.NegentropySync.
//
// Differences from the vendored implementation:
//   - the websocket connection is closed on return (the vendored version only
//     sends NEG-CLOSE and leaks the connection — fatal when called hourly per
//     relay on mobile);
//   - a relay that never answers the NEG-OPEN (it sends only a NOTICE, which
//     go-nostr swallows) is reported as ErrUnsupported so callers can cache
//     the capability and fall back to plain REQ catch-up;
//   - transfer statistics are returned for logging and notification batching;
//   - Reconcile runs on a dedicated goroutine, never on the relay's websocket
//     read loop, and every worker is unblocked on return — the vendored
//     version leaks the read loop (and the whole ID vector it pins) whenever
//     the sync ends early, which is the common path against flaky relays;
//   - the local ID vector can be built once per round and reused across
//     relays via BuildVector/SyncWithVector instead of re-querying the whole
//     windowed store per relay.
package negsync

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip77"
	"github.com/nbd-wtf/go-nostr/nip77/negentropy"
	"github.com/nbd-wtf/go-nostr/nip77/negentropy/storage/vector"
)

// ErrUnsupported means the relay did not respond to the NEG-OPEN within the
// handshake window — it (almost certainly) does not speak NIP-77. Callers may
// cache this per relay. A NEG-ERR response is NOT this error: a relay that
// answers with NEG-ERR does speak the protocol.
var ErrUnsupported = errors.New("relay does not support NIP-77 negentropy")

// ErrRefused means the relay answered with a NEG-ERR — it speaks NIP-77 but
// refused this reconciliation (e.g. strfry's "blocked: too many query
// results"). The refusal is deterministic for a given filter and local set,
// so retrying every round just hammers the relay (and earns 503s); callers
// should cache it like ErrUnsupported and fall back to plain catch-up.
var ErrRefused = errors.New("relay refused negentropy reconciliation")

type Direction int

const (
	Up   Direction = iota // push local-only events to the relay
	Down                  // fetch relay-only events into the local store
	Both
)

// Stats reports what a Sync transferred.
type Stats struct {
	LocalHave  int // events (incl. tombstones) in the local vector
	Downloaded int // events fetched from the relay and published locally
	Uploaded   int // events pushed from the local store to the relay
	RemoteOnly int // distinct IDs the relay has that the local vector lacked (Down/Both)
}

// openTimeout is how long to wait for the relay's first NEG-MSG/NEG-ERR after
// NEG-OPEN. Supporting relays (khatru, strfry) answer in one round-trip;
// non-supporting ones reply only with a NOTICE that go-nostr swallows, so
// silence is the "unsupported" signal.
const openTimeout = 15 * time.Second

const batchSize = 50

type direction struct {
	label  string
	items  chan string
	source nostr.RelayStore
	target nostr.RelayStore
	count  *atomic.Int64
	skip   func(id string) bool // drop this ID before querying/publishing
	record func(id string)      // called after a successful publish
}

// Option configures a Sync/SyncWithVector call.
type Option func(*options)

type options struct {
	skipUpload func(id string) bool
	onUploaded func(id string)
}

// WithUploadMemo skips uploading events skip() reports as already sent and
// records each successfully-published upload via record. It breaks the
// re-upload treadmill against relays that acknowledge EVENT writes with OK
// but never serve the events back (silent policy drops, retention pruning):
// their vector lists the same events as missing on every round, so without a
// memo a Both/Up sync re-sends the identical set forever.
func WithUploadMemo(skip func(id string) bool, record func(id string)) Option {
	return func(o *options) { o.skipUpload = skip; o.onUploaded = record }
}

// LocalVector is a sealed local ID vector, safe to reuse across sequential
// SyncWithVector calls: reconciliation only reads it. Reuse means events
// downloaded from an earlier relay in the same round aren't in the vector for
// later relays — they get re-offered and deduped by the store, which is far
// cheaper than re-materializing the whole windowed set per relay.
type LocalVector struct {
	vec  *vector.Vector
	size int
}

// BuildVector materializes the windowed local set once and seals it into a
// reusable reconciliation vector.
func BuildVector(ctx context.Context, store nostr.RelayStore, filter nostr.Filter) (*LocalVector, error) {
	data, err := store.QuerySync(ctx, filter)
	if err != nil {
		return nil, fmt.Errorf("failed to query our local store: %w", err)
	}
	vec := vector.New()
	for _, evt := range data {
		vec.Insert(evt.CreatedAt, evt.ID)
	}
	vec.Seal()
	return &LocalVector{vec: vec, size: len(data)}, nil
}

// Sync reconciles the events matching filter between store and the relay at
// url, building the local vector from scratch. Prefer BuildVector +
// SyncWithVector when syncing the same filter against several relays.
func Sync(ctx context.Context, store nostr.RelayStore, url string, filter nostr.Filter, dir Direction, opts ...Option) (Stats, error) {
	lv, err := BuildVector(ctx, store, filter)
	if err != nil {
		return Stats{}, err
	}
	return SyncWithVector(ctx, store, lv, url, filter, dir, opts...)
}

// SyncWithVector reconciles against the relay at url using a prebuilt local
// vector. In the Down direction missing events are fetched in ID batches and
// handed to store.Publish (which is expected to do its own accept/reject
// filtering); in the Up direction events the relay lacks are read via
// store.QueryEvents and published to it.
func SyncWithVector(ctx context.Context, store nostr.RelayStore, lv *LocalVector, url string, filter nostr.Filter, dir Direction, opts ...Option) (Stats, error) {
	var o options
	for _, opt := range opts {
		opt(&o)
	}
	stats := Stats{LocalHave: lv.size}
	id := "haven-negsync"

	neg := negentropy.New(lv.vec, 1024*1024)

	// Everything below runs under sctx so any return path (unsupported,
	// NEG-ERR, ctx timeout) unblocks the workers instead of leaking them on
	// open channels.
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()

	result := make(chan error, 8)
	firstRespOnce := sync.Once{}
	firstResp := make(chan struct{})

	// report never blocks past cancellation: after Sync returns nobody reads
	// result, and a blocked send from the websocket read loop would pin the
	// connection (and this whole sync's state) forever.
	report := func(err error) {
		select {
		case result <- err:
		case <-sctx.Done():
		}
	}

	// Reconcile must NOT run on the relay's websocket read loop: it blocks
	// sending IDs into neg.Haves/neg.HaveNots, and once Sync returns those
	// channels have no consumers — the read loop would hang mid-send forever,
	// leaking the goroutine, the connection, and the entire ID vector. The
	// handler only enqueues; a goroutine we own (and can unblock, see the
	// drain below) does the reconciliation.
	msgs := make(chan string, 8)
	reconcileDone := make(chan struct{})

	var r *nostr.Relay
	r, err := nostr.RelayConnect(ctx, url, nostr.WithCustomHandler(func(data string) {
		envelope := nip77.ParseNegMessage(data)
		if envelope == nil {
			return
		}
		firstRespOnce.Do(func() { close(firstResp) })
		switch env := envelope.(type) {
		case *nip77.OpenEnvelope, *nip77.CloseEnvelope:
			report(fmt.Errorf("unexpected %s received from relay", env.Label()))
		case *nip77.ErrorEnvelope:
			report(fmt.Errorf("%w: %s", ErrRefused, env.Reason))
		case *nip77.MessageEnvelope:
			select {
			case msgs <- env.Message:
			case <-sctx.Done():
			}
		}
	}))
	if err != nil {
		return stats, err
	}
	defer r.Close()

	go func() {
		defer close(reconcileDone)
		for {
			var msg string
			select {
			case msg = <-msgs:
			case <-sctx.Done():
				return
			}
			nextmsg, err := neg.Reconcile(msg)
			if err != nil {
				report(fmt.Errorf("failed to reconcile: %w", err))
				return
			}
			if nextmsg != "" {
				msgb, _ := nip77.MessageEnvelope{SubscriptionID: id, Message: nextmsg}.MarshalJSON()
				r.Write(msgb)
			}
		}
	}()

	// On return, guarantee the reconcile goroutine exits: cancel sctx, then
	// keep draining Haves/HaveNots (whose regular consumers have exited)
	// until it signals done — it may be blocked mid-send inside Reconcile.
	// Registered after `defer r.Close()` so it runs first; Relay.Write never
	// wedges it (go-nostr's Write selects on the connection context).
	defer func() {
		cancel()
		haves, havenots := neg.Haves, neg.HaveNots
		for {
			select {
			case <-reconcileDone:
				return
			case _, ok := <-haves:
				if !ok {
					haves = nil
				}
			case _, ok := <-havenots:
				if !ok {
					havenots = nil
				}
			}
		}
	}()

	var downloaded, uploaded, remoteOnly atomic.Int64

	directions := make([]direction, 0, 2)
	if dir == Up || dir == Both {
		directions = append(directions, direction{"up", neg.Haves, store, r, &uploaded, o.skipUpload, o.onUploaded})
	}
	if dir == Down || dir == Both {
		directions = append(directions, direction{"down", neg.HaveNots, r, store, &downloaded, nil, nil})
	}
	// The unused side of the reconciliation still fills its channel; drain it
	// so Reconcile can't stall on it mid-sync. Escapes on sctx.Done() (the
	// deferred drain above covers everything after that).
	drain := func(ch chan string) {
		for {
			select {
			case _, ok := <-ch:
				if !ok {
					return
				}
			case <-sctx.Done():
				return
			}
		}
	}
	if dir == Up {
		go drain(neg.HaveNots)
	}
	if dir == Down {
		go drain(neg.Haves)
	}

	wg := sync.WaitGroup{}
	for _, d := range directions {
		wg.Add(1)
		go func(d direction) {
			defer wg.Done()

			seen := make(map[string]struct{})
			var innerWg sync.WaitGroup

			doSync := func(ids []string) {
				defer innerWg.Done()
				if len(ids) == 0 {
					return
				}
				evtch, err := d.source.QueryEvents(sctx, nostr.Filter{IDs: ids})
				if err != nil {
					report(fmt.Errorf("error querying source on %s: %w", d.label, err))
					return
				}
				for evt := range evtch {
					if err := d.target.Publish(sctx, *evt); err == nil {
						d.count.Add(1)
						if d.record != nil {
							d.record(evt.ID)
						}
					}
				}
			}

			ids := make([]string, 0, batchSize)
			flush := func() {
				batch := ids
				ids = make([]string, 0, batchSize)
				innerWg.Add(1)
				go doSync(batch)
			}

		loop:
			for {
				select {
				case item, ok := <-d.items:
					if !ok {
						break loop
					}
					if _, dup := seen[item]; dup {
						continue
					}
					seen[item] = struct{}{}
					if d.skip != nil && d.skip(item) {
						continue
					}
					ids = append(ids, item)
					if len(ids) == batchSize {
						flush()
					}
				case <-sctx.Done():
					break loop
				}
			}
			flush()
			innerWg.Wait()
			if d.label == "down" {
				remoteOnly.Store(int64(len(seen)))
			}
		}(d)
	}

	msg := neg.Start()
	open, _ := nip77.OpenEnvelope{SubscriptionID: id, Filter: filter, Message: msg}.MarshalJSON()
	if err := <-r.Write(open); err != nil {
		return stats, fmt.Errorf("failed to write to relay: %w", err)
	}
	defer func() {
		clse, _ := nip77.CloseEnvelope{SubscriptionID: id}.MarshalJSON()
		r.Write(clse)
	}()

	// Handshake: wait for the relay's first NEG response.
	select {
	case <-ctx.Done():
		return stats, ctx.Err()
	case err := <-result:
		stats.Downloaded = int(downloaded.Load())
		stats.Uploaded = int(uploaded.Load())
		return stats, err
	case <-firstResp:
	case <-time.After(openTimeout):
		return stats, ErrUnsupported
	}

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	var werr error
	select {
	case <-ctx.Done():
		werr = ctx.Err()
	case werr = <-result:
	case <-done:
	}
	stats.Downloaded = int(downloaded.Load())
	stats.Uploaded = int(uploaded.Load())
	stats.RemoteOnly = int(remoteOnly.Load())
	return stats, werr
}
