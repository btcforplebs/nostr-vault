//go:build !cshared

package main

import (
	"bytes"
	"context"
	"log"
	"strings"
	"testing"
	"time"

	"github.com/barrydeen/haven/internal/tombstones"
	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"

	"github.com/barrydeen/haven/pkg/wot"
)

// stubWot satisfies wot.Model. A single concrete type is required because
// wot's atomic.Value rejects inconsistently-typed stores — every test in this
// package that installs a graph must use this one, which is why it carries
// both shapes: `allow` answers true for everyone (the WOT_DEPTH=0
// configuration), `members` is an actual graph.
type stubWot struct {
	allow   bool
	members map[string]bool
}

func (s stubWot) Has(_ context.Context, pubkey string) bool {
	return s.allow || s.members[pubkey]
}

// Size lets a caller tell an empty graph from an untrusted pubkey; both make
// Has return false. An allow-everyone stub reports 0 and is recognised by its
// answers instead.
func (s stubWot) Size() int { return len(s.members) }

func hexid(c byte) string { return strings.Repeat(string(c), 64) }

func newTestStore(t *testing.T) eventstore.RelayWrapper {
	t.Helper()
	db := newBadgerBackend(t.TempDir() + "/db")
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	return eventstore.RelayWrapper{Store: db}
}

func newTestTombs(t *testing.T) *tombstones.Set {
	t.Helper()
	s, err := tombstones.Open(afero.NewMemMapFs(), "tombstones.jsonl", 30*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func setupSyncConfig(owner string) {
	config = Config{
		WhitelistedPubKeys: map[string]struct{}{owner: {}},
		BlacklistedPubKeys: map[string]struct{}{},
		NotifyBatchLimit:   2,
		NotifyMaxAgeHours:  24,
		SyncWindowDays:     30,
	}
}

func TestInboxNegStorePublish(t *testing.T) {
	owner := hexid('0')
	author := hexid('1')
	setupSyncConfig(owner)
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})

	ctx := context.Background()
	inbox := newTestStore(t)
	chat := newTestStore(t)
	tombs := newTestTombs(t)

	var advanced nostr.Timestamp
	s := &inboxNegStore{
		inbox:    inbox,
		chat:     chat,
		tombs:    tombs,
		notifier: &batchNotifier{},
		advance:  func(ts nostr.Timestamp) { advanced = ts },
	}

	now := nostr.Now()

	// 1. Accepted mention → stored in inbox, watermark advanced.
	mention := nostr.Event{
		ID: hexid('a'), PubKey: author, Kind: nostr.KindTextNote,
		CreatedAt: now, Tags: nostr.Tags{{"p", owner}},
	}
	if err := s.Publish(ctx, mention); err != nil {
		t.Fatal(err)
	}
	if got, _ := inbox.QuerySync(ctx, nostr.Filter{IDs: []string{mention.ID}}); len(got) != 1 {
		t.Fatal("accepted mention not stored in inbox")
	}
	if advanced != now {
		t.Fatalf("watermark not advanced: %d", advanced)
	}

	// 2. Gift wrap from unknown author (WoT bypass) → routed to chat DB.
	wrap := nostr.Event{
		ID: hexid('b'), PubKey: hexid('2'), Kind: nostr.KindGiftWrap,
		CreatedAt: now, Tags: nostr.Tags{{"p", owner}},
	}
	if err := s.Publish(ctx, wrap); err != nil {
		t.Fatal(err)
	}
	if got, _ := chat.QuerySync(ctx, nostr.Filter{IDs: []string{wrap.ID}}); len(got) != 1 {
		t.Fatal("gift wrap not routed to chat store")
	}
	if got, _ := inbox.QuerySync(ctx, nostr.Filter{IDs: []string{wrap.ID}}); len(got) != 0 {
		t.Fatal("gift wrap wrongly stored in inbox")
	}

	// 3. Event without a whitelisted p-tag → rejected + tombstoned, not stored.
	stranger := nostr.Event{
		ID: hexid('c'), PubKey: author, Kind: nostr.KindTextNote,
		CreatedAt: now, Tags: nostr.Tags{{"p", hexid('3')}},
	}
	if err := s.Publish(ctx, stranger); err != nil {
		t.Fatal(err)
	}
	if !tombs.Has(stranger.ID) {
		t.Fatal("rejected event not tombstoned")
	}
	if got, _ := inbox.QuerySync(ctx, nostr.Filter{IDs: []string{stranger.ID}}); len(got) != 0 {
		t.Fatal("rejected event was stored")
	}

	// 4. Outside the web of trust (non-giftwrap) → skipped but NOT tombstoned:
	// WoT membership changes, so the event must stay re-fetchable (a fresh
	// instance's half-built WoT must not permanently hide replies).
	wot.MarkReady(wot.NewCycle(), stubWot{allow: false})
	unknown := nostr.Event{
		ID: hexid('d'), PubKey: hexid('4'), Kind: nostr.KindTextNote,
		CreatedAt: now, Tags: nostr.Tags{{"p", owner}},
	}
	if err := s.Publish(ctx, unknown); err != nil {
		t.Fatal(err)
	}
	if tombs.Has(unknown.ID) {
		t.Fatal("non-WoT rejection must not be tombstoned (transient)")
	}
	if got, _ := inbox.QuerySync(ctx, nostr.Filter{IDs: []string{unknown.ID}}); len(got) != 0 {
		t.Fatal("non-WoT event was stored")
	}

	// 4b. Once the author enters the WoT, a re-sync of the same event imports it.
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})
	if err := s.Publish(ctx, unknown); err != nil {
		t.Fatal(err)
	}
	if got, _ := inbox.QuerySync(ctx, nostr.Filter{IDs: []string{unknown.ID}}); len(got) != 1 {
		t.Fatal("event not imported after WoT admitted its author")
	}

	// 5. QuerySync folds stored events AND tombstone stubs into the vector set.
	evs, err := s.QuerySync(ctx, nostr.Filter{})
	if err != nil {
		t.Fatal(err)
	}
	ids := make(map[string]bool, len(evs))
	for _, ev := range evs {
		ids[ev.ID] = true
	}
	for _, want := range []string{mention.ID, wrap.ID, stranger.ID, unknown.ID} {
		if !ids[want] {
			t.Fatalf("QuerySync missing %s", want[:8])
		}
	}
}

// TestInboxNegStoreTempRejectStubs verifies the in-memory temp-reject cache:
// a WoT-rejected event is not tombstoned (stays re-fetchable across restarts)
// but IS folded into the negentropy vector as a stub for this process run, so
// the remote stops re-offering it — the fix for the per-minute 100% CPU loop.
func TestInboxNegStoreTempRejectStubs(t *testing.T) {
	owner := hexid('0')
	setupSyncConfig(owner)
	wot.MarkReady(wot.NewCycle(), stubWot{allow: false}) // reject everything

	ctx := context.Background()
	inbox := newTestStore(t)
	chat := newTestStore(t)
	tombs := newTestTombs(t)
	rejects := &tempRejects{}
	s := &inboxNegStore{
		inbox: inbox, chat: chat, tombs: tombs, rejects: rejects,
		notifier: &batchNotifier{},
		advance:  func(nostr.Timestamp) {},
	}

	now := nostr.Now()
	reply := nostr.Event{
		ID: hexid('a'), PubKey: hexid('1'), Kind: nostr.KindTextNote,
		CreatedAt: now, Tags: nostr.Tags{{"p", owner}},
	}
	if err := s.Publish(ctx, reply); err != nil {
		t.Fatal(err)
	}
	// Not tombstoned (WoT membership can change) and not stored.
	if tombs.Has(reply.ID) {
		t.Fatal("WoT reject must not be tombstoned")
	}
	if got, _ := inbox.QuerySync(ctx, nostr.Filter{IDs: []string{reply.ID}}); len(got) != 0 {
		t.Fatal("WoT-rejected event was stored")
	}

	// But QuerySync now lists it as a vector stub so it isn't re-offered.
	stubbed := func() bool {
		evs, err := s.QuerySync(ctx, nostr.Filter{})
		if err != nil {
			t.Fatal(err)
		}
		for _, ev := range evs {
			if ev.ID == reply.ID {
				return true
			}
		}
		return false
	}
	if !stubbed() {
		t.Fatal("temp-rejected event missing from negentropy vector")
	}

	// A time-bounded query excludes stubs outside the window.
	old := now - nostr.Timestamp(3600)
	future := now - nostr.Timestamp(1800)
	if evs, _ := s.QuerySync(ctx, nostr.Filter{Since: &old, Until: &future}); func() bool {
		for _, ev := range evs {
			if ev.ID == reply.ID {
				return true
			}
		}
		return false
	}() {
		t.Fatal("stub leaked outside the filter's time bounds")
	}

	// Once the WoT admits the author and the event is accepted for real, the
	// stub is dropped so QuerySync doesn't double-list it (DB + stub).
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})
	if err := s.Publish(ctx, reply); err != nil {
		t.Fatal(err)
	}
	if got, _ := inbox.QuerySync(ctx, nostr.Filter{IDs: []string{reply.ID}}); len(got) != 1 {
		t.Fatal("event not imported after WoT admitted its author")
	}
	if _, ok := rejects.m.Load(reply.ID); ok {
		t.Fatal("temp-reject stub not cleared after acceptance")
	}
}

// TestTempRejectsPrune verifies the cache is bounded: entries older than the
// prune cutoff are dropped so the map can't grow without limit over the
// process lifetime, while in-window entries survive.
func TestTempRejectsPrune(t *testing.T) {
	r := &tempRejects{}
	now := nostr.Now()
	stale := hexid('1')
	fresh := hexid('2')
	r.add(stale, now-nostr.Timestamp(100), hexid('9'))
	r.add(fresh, now, hexid('9'))

	r.prune(now - nostr.Timestamp(50)) // cutoff between the two

	if _, ok := r.m.Load(stale); ok {
		t.Fatal("stale entry survived prune")
	}
	if _, ok := r.m.Load(fresh); !ok {
		t.Fatal("fresh entry wrongly pruned")
	}

	// nil receiver is a no-op, not a panic.
	var nilR *tempRejects
	nilR.prune(now)
	nilR.add(stale, now, hexid('9'))
	nilR.reevaluate(func(string) bool { return true })
	if evs := nilR.appendStubs(nil, nostr.Filter{}); len(evs) != 0 {
		t.Fatal("nil tempRejects should yield no stubs")
	}
}

// TestTempRejectsReevaluate verifies a cached reject is re-offered (stub
// dropped) once its author passes the admit predicate, and kept otherwise —
// the mechanism that self-heals a WoT admit without a per-round re-download.
func TestTempRejectsReevaluate(t *testing.T) {
	r := &tempRejects{}
	now := nostr.Now()
	admitted := hexid('1')
	stillOut := hexid('2')
	r.add(hexid('a'), now, admitted)
	r.add(hexid('b'), now, stillOut)

	r.reevaluate(func(pk string) bool { return pk == admitted })

	if _, ok := r.m.Load(hexid('a')); ok {
		t.Fatal("admitted author's stub not dropped")
	}
	if _, ok := r.m.Load(hexid('b')); !ok {
		t.Fatal("still-rejected author's stub wrongly dropped")
	}
}

func TestOutboxNegStoreUpFilter(t *testing.T) {
	owner := hexid('0')
	setupSyncConfig(owner)

	ctx := context.Background()
	outbox := newTestStore(t)
	s := &outboxNegStore{outbox: outbox, tombs: newTestTombs(t)}

	now := nostr.Now()
	public := nostr.Event{ID: hexid('a'), PubKey: owner, Kind: nostr.KindTextNote, CreatedAt: now}
	protected := nostr.Event{
		ID: hexid('b'), PubKey: owner, Kind: nostr.KindTextNote, CreatedAt: now,
		Tags: nostr.Tags{{"-"}},
	}
	wrap := nostr.Event{ID: hexid('c'), PubKey: owner, Kind: nostr.KindGiftWrap, CreatedAt: now}

	for _, ev := range []nostr.Event{public, protected, wrap} {
		if err := s.Publish(ctx, ev); err != nil {
			t.Fatal(err)
		}
	}

	// The up-direction source must yield only the public note.
	ch, err := s.QueryEvents(ctx, nostr.Filter{IDs: []string{public.ID, protected.ID, wrap.ID}})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for ev := range ch {
		got = append(got, ev.ID)
	}
	if len(got) != 1 || got[0] != public.ID {
		t.Fatalf("up filter yielded %v, want only the public note", got)
	}

	// Non-owner event on the down path → skipped (not stored, not tombstoned —
	// whitelist membership can change, so it must stay re-fetchable).
	foreign := nostr.Event{ID: hexid('e'), PubKey: hexid('9'), Kind: nostr.KindTextNote, CreatedAt: now}
	if err := s.Publish(ctx, foreign); err != nil {
		t.Fatal(err)
	}
	if s.tombs.Has(foreign.ID) {
		t.Fatal("foreign-event rejection must not be tombstoned")
	}
	if got, _ := outbox.QuerySync(ctx, nostr.Filter{IDs: []string{foreign.ID}}); len(got) != 0 {
		t.Fatal("foreign event stored in outbox")
	}
}

func TestFeedNegStorePublishGates(t *testing.T) {
	owner := hexid('0')
	follow := hexid('1')
	setupSyncConfig(owner)

	ctx := context.Background()
	feed := newTestStore(t)
	s := &feedNegStore{feed: feed, follows: map[string]struct{}{follow: {}}}

	now := nostr.Now()
	ok := nostr.Event{ID: hexid('a'), PubKey: follow, Kind: nostr.KindTextNote, CreatedAt: now}
	wrongKind := nostr.Event{ID: hexid('b'), PubKey: follow, Kind: nostr.KindReaction, CreatedAt: now}
	nonFollow := nostr.Event{ID: hexid('c'), PubKey: hexid('9'), Kind: nostr.KindTextNote, CreatedAt: now}

	for _, ev := range []nostr.Event{ok, wrongKind, nonFollow} {
		if err := s.Publish(ctx, ev); err != nil {
			t.Fatal(err)
		}
	}
	if got, _ := feed.QuerySync(ctx, nostr.Filter{IDs: []string{ok.ID}}); len(got) != 1 {
		t.Fatal("follow's note not cached")
	}
	for _, id := range []string{wrongKind.ID, nonFollow.ID} {
		if got, _ := feed.QuerySync(ctx, nostr.Filter{IDs: []string{id}}); len(got) != 0 {
			t.Fatalf("gated event %s was cached", id[:8])
		}
	}
}

func TestBatchNotifierSuppression(t *testing.T) {
	owner := hexid('0')
	setupSyncConfig(owner) // NotifyBatchLimit=2, NotifyMaxAgeHours=24

	n := &batchNotifier{}
	now := nostr.Now()
	fresh := func(id byte) *nostr.Event {
		return &nostr.Event{ID: hexid(id), PubKey: hexid('1'), Kind: nostr.KindTextNote, CreatedAt: now}
	}

	// Two fresh events notify, the rest are suppressed.
	n.maybeNotify(fresh('a'), owner)
	n.maybeNotify(fresh('b'), owner)
	n.maybeNotify(fresh('c'), owner)
	n.maybeNotify(fresh('d'), owner)
	if n.emitted != 2 || n.suppressed != 2 {
		t.Fatalf("emitted=%d suppressed=%d, want 2/2", n.emitted, n.suppressed)
	}

	// Stale events (older than NotifyMaxAgeHours) never notify or count.
	old := &nostr.Event{
		ID: hexid('e'), PubKey: hexid('1'), Kind: nostr.KindTextNote,
		CreatedAt: now - nostr.Timestamp(48*3600),
	}
	n.maybeNotify(old, owner)
	if n.emitted != 2 || n.suppressed != 2 {
		t.Fatal("stale event affected notifier counters")
	}

	// flush resets for the next catch-up batch.
	n.flush(true)
	if n.emitted != 0 || n.suppressed != 0 {
		t.Fatal("flush did not reset counters")
	}
}

// A summary marker claims the user was away. Rounds the user triggered by
// refreshing must not emit one, or an open app announces "while you were away"
// as often as once a minute — the bug this gate exists to stop.
func TestBatchNotifierSummaryOnlyWhenAway(t *testing.T) {
	owner := hexid('0')
	setupSyncConfig(owner) // NotifyBatchLimit=2, NotifyMaxAgeHours=24

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	now := nostr.Now()
	fresh := func(id byte) *nostr.Event {
		return &nostr.Event{ID: hexid(id), PubKey: hexid('1'), Kind: nostr.KindTextNote, CreatedAt: now}
	}
	suppressThree := func(n *batchNotifier) {
		for _, id := range []byte{'a', 'b', 'c', 'd', 'e'} {
			n.maybeNotify(fresh(id), owner)
		}
		if n.suppressed != 3 {
			t.Fatalf("suppressed=%d, want 3 — test no longer exercises the summary path", n.suppressed)
		}
	}

	// User-triggered round: the overflow stays silent.
	n := &batchNotifier{}
	suppressThree(n)
	n.flush(false)
	if strings.Contains(buf.String(), "type=summary") {
		t.Fatalf("summary emitted for a user-triggered round: %q", buf.String())
	}

	// Timer-driven round after an absence: the summary is exactly what the user
	// wants, so the gate must not have silenced it everywhere.
	buf.Reset()
	n = &batchNotifier{}
	suppressThree(n)
	n.flush(true)
	if !strings.Contains(buf.String(), "type=summary") {
		t.Fatalf("no summary emitted for an away round: %q", buf.String())
	}
	if !strings.Contains(buf.String(), "3 more new items") {
		t.Fatalf("summary lost its count: %q", buf.String())
	}
}
