//go:build !cshared

package main

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"

	"github.com/barrydeen/haven/pkg/wot"
)

// fakeMac is an in-process khatru relay standing in for the owner's Mac. One
// store serves both the base URL and /inbox, which is enough here: the two
// copies use disjoint filters (authors=owner vs #p=owner).
type fakeMac struct {
	url   string
	store eventstore.RelayWrapper
}

func newFakeMac(t *testing.T, negentropy bool, capLimit int, reject ...func(context.Context, nostr.Filter) (bool, string)) *fakeMac {
	t.Helper()
	store := newTestStore(t)
	rl := khatru.NewRelay()
	rl.Negentropy = negentropy
	rl.StoreEvent = append(rl.StoreEvent, store.Store.SaveEvent)
	rl.QueryEvents = append(rl.QueryEvents, store.Store.QueryEvents)
	if capLimit > 0 {
		// Mimic a relay that silently caps every REQ, the failure mode the
		// old single-request import hit.
		rl.OverwriteFilter = append(rl.OverwriteFilter, func(_ context.Context, f *nostr.Filter) {
			if f.Limit == 0 || f.Limit > capLimit {
				f.Limit = capLimit
			}
		})
	}
	rl.RejectFilter = append(rl.RejectFilter, reject...)
	srv := httptest.NewServer(rl)
	t.Cleanup(srv.Close)
	return &fakeMac{url: "ws" + strings.TrimPrefix(srv.URL, "http"), store: store}
}

// seed signs and stores n events on the fake Mac, spread evenly over
// [from, to), and returns their IDs.
func (m *fakeMac) seed(t *testing.T, sk string, n int, from, to time.Time, tags nostr.Tags) map[string]bool {
	t.Helper()
	ids := make(map[string]bool, n)
	span := to.Sub(from)
	for i := 0; i < n; i++ {
		ev := nostr.Event{
			Kind:      nostr.KindTextNote,
			CreatedAt: nostr.Timestamp(from.Add(span * time.Duration(i) / time.Duration(n)).Unix()),
			Tags:      tags,
			Content:   "note",
		}
		if err := ev.Sign(sk); err != nil {
			t.Fatal(err)
		}
		if err := m.store.Store.SaveEvent(context.Background(), &ev); err != nil {
			t.Fatal(err)
		}
		ids[ev.ID] = true
	}
	return ids
}

type macFixture struct {
	fill                 *macBackfiller
	outbox, inbox, chat  eventstore.RelayWrapper
	ownerIDs, mentionIDs map[string]bool
}

func setupMacFixture(t *testing.T, mac *fakeMac) *macFixture {
	t.Helper()
	ownerSK, authorSK := nostr.GeneratePrivateKey(), nostr.GeneratePrivateKey()
	owner, _ := nostr.GetPublicKey(ownerSK)

	prevCfg, prevFs, prevPool := config, fs, pool
	t.Cleanup(func() { config, fs, pool = prevCfg, prevFs, prevPool })
	setupSyncConfig(owner)
	config.MacRelayURL = mac.url
	fs = afero.NewMemMapFs()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	pool = nostr.NewSimplePool(ctx)
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})

	// Years of history, well past the 30-day catch-up window, plus a burst of
	// 700 in one quarter so a single slice/page exceeds a relay's cap.
	now := time.Now()
	start := now.AddDate(-4, 0, 0)
	burst := now.AddDate(0, -6, 0)
	f := &macFixture{
		ownerIDs:   mac.seed(t, ownerSK, 900, start, now, nil),
		mentionIDs: mac.seed(t, authorSK, 1200, start, now, nostr.Tags{{"p", owner}}),
	}
	for id := range mac.seed(t, authorSK, 700, burst, burst.Add(30*24*time.Hour), nostr.Tags{{"p", owner}}) {
		f.mentionIDs[id] = true
	}
	f.outbox, f.inbox, f.chat = newTestStore(t), newTestStore(t), newTestStore(t)
	tombs := newTestTombs(t)
	notifier := &batchNotifier{}
	rejects := &tempRejects{}
	f.fill = &macBackfiller{
		pTags:      []string{owner},
		inboxNeg:   &inboxNegStore{inbox: f.inbox, chat: f.chat, tombs: tombs, rejects: rejects, notifier: notifier},
		outboxNeg:  &outboxNegStore{outbox: f.outbox, tombs: tombs},
		wdbInbox:   f.inbox,
		wdbChat:    f.chat,
		wdbOutbox:  f.outbox,
		notifier:   notifier,
		rejects:    rejects,
		now:        time.Now,
		negEnabled: true,
	}
	return f
}

func assertHasAll(t *testing.T, label string, store eventstore.RelayWrapper, want map[string]bool) {
	t.Helper()
	ctx := eventstore.SetNegentropy(context.Background())
	got, err := store.QuerySync(ctx, nostr.Filter{})
	if err != nil {
		t.Fatal(err)
	}
	have := make(map[string]bool, len(got))
	for _, ev := range got {
		have[ev.ID] = true
	}
	missing := 0
	for id := range want {
		if !have[id] {
			missing++
		}
	}
	if missing > 0 {
		t.Fatalf("%s: %d of %d events missing locally", label, missing, len(want))
	}
}

func TestMacBackfillNegentropyCopiesEverything(t *testing.T) {
	mac := newFakeMac(t, true, 0)
	f := setupMacFixture(t, mac)

	f.fill.runIfNeeded(context.Background(), false)

	st := loadMacSyncStatus()
	if st.State != "done" || st.Method != "negentropy" || st.Missing != 0 {
		t.Fatalf("status = %+v, want done/negentropy/0 missing", st)
	}
	if st.Posts != len(f.ownerIDs) || st.Mentions != len(f.mentionIDs) {
		t.Fatalf("copied %d posts / %d mentions, want %d / %d", st.Posts, st.Mentions, len(f.ownerIDs), len(f.mentionIDs))
	}
	assertHasAll(t, "posts", f.outbox, f.ownerIDs)
	assertHasAll(t, "mentions", f.inbox, f.mentionIDs)

	// A finished copy is not repeated for the same Mac...
	st.Posts = -7
	saveMacSyncStatus(st)
	f.fill.runIfNeeded(context.Background(), false)
	if loadMacSyncStatus().Posts != -7 {
		t.Fatal("completed backfill re-ran without force")
	}
	// ...but a forced check re-runs and finds nothing new and nothing missing.
	f.fill.runIfNeeded(context.Background(), true)
	if st := loadMacSyncStatus(); st.State != "done" || st.Posts != 0 || st.Mentions != 0 || st.Missing != 0 {
		t.Fatalf("forced re-check status = %+v, want done with 0 copied / 0 missing", st)
	}
}

func TestMacBackfillCheckReportsMissing(t *testing.T) {
	mac := newFakeMac(t, true, 0)
	f := setupMacFixture(t, mac)
	// A store that accepts nothing: every event stays missing, and the check
	// pass has to say so instead of reporting success.
	f.fill.outboxNeg = &refusingStore{inner: f.fill.outboxNeg}

	f.fill.runIfNeeded(context.Background(), false)

	st := loadMacSyncStatus()
	if st.State != "incomplete" || st.Missing != len(f.ownerIDs) {
		t.Fatalf("status = %+v, want incomplete with %d missing", st, len(f.ownerIDs))
	}
}

func TestMacBackfillSupersededReplaceableIsNotMissing(t *testing.T) {
	mac := newFakeMac(t, true, 0)
	f := setupMacFixture(t, mac)
	// The Mac kept two versions of someone's follow list (both tag the owner);
	// the phone keeps only the newer one, so the older can never be stored.
	sk := nostr.GeneratePrivateKey()
	for _, age := range []time.Duration{48 * time.Hour, time.Hour} {
		ev := nostr.Event{Kind: nostr.KindFollowList, CreatedAt: nostr.Timestamp(time.Now().Add(-age).Unix()), Tags: nostr.Tags{{"p", f.fill.pTags[0]}}}
		if err := ev.Sign(sk); err != nil {
			t.Fatal(err)
		}
		if err := mac.store.Store.SaveEvent(context.Background(), &ev); err != nil {
			t.Fatal(err)
		}
	}

	f.fill.runIfNeeded(context.Background(), false)

	if st := loadMacSyncStatus(); st.State != "done" || st.Missing != 0 {
		t.Fatalf("status = %+v, want done with 0 missing", st)
	}
}

func TestMacBackfillPagedFallbackPassesRelayCap(t *testing.T) {
	mac := newFakeMac(t, false, 100)
	f := setupMacFixture(t, mac)
	// NIP-77 stays enabled: the copy must find out on its own (NEG-OPEN
	// timeout on the first slice) and fall back.

	f.fill.runIfNeeded(context.Background(), false)

	st := loadMacSyncStatus()
	if st.State != "done" || st.Method != "paged" || st.Missing != -1 {
		t.Fatalf("status = %+v, want done/paged/-1", st)
	}
	assertHasAll(t, "posts", f.outbox, f.ownerIDs)
	assertHasAll(t, "mentions", f.inbox, f.mentionIDs)
}

func TestMacRelayURLs(t *testing.T) {
	prev := config
	t.Cleanup(func() { config = prev })
	config.MacRelayURL = " wss://mac.example.com/ "
	if b, i := macRelayURLs(); b != "wss://mac.example.com" || i != "wss://mac.example.com/inbox" {
		t.Fatalf("got %q %q", b, i)
	}
	config.MacRelayURL = ""
	if b, i := macRelayURLs(); b != "" || i != "" {
		t.Fatalf("unset Mac relay gave %q %q", b, i)
	}
}

// refusingStore lists its inner store's events but never stores new ones.
type refusingStore struct{ inner nostr.RelayStore }

func (s *refusingStore) QuerySync(ctx context.Context, f nostr.Filter) ([]*nostr.Event, error) {
	return s.inner.QuerySync(ctx, f)
}
func (s *refusingStore) QueryEvents(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
	return s.inner.QueryEvents(ctx, f)
}
func (s *refusingStore) Publish(context.Context, nostr.Event) error {
	return context.DeadlineExceeded
}

func TestMacBackfillPagedWalkCutShortIsNotDone(t *testing.T) {
	// A Mac that answers the first page and then refuses every older one: the
	// walk must not be recorded as a finished copy.
	mac := newFakeMac(t, false, 100, func(_ context.Context, f nostr.Filter) (bool, string) {
		return f.Until != nil, "blocked: try later"
	})
	f := setupMacFixture(t, mac)
	f.fill.negEnabled = false

	f.fill.runIfNeeded(context.Background(), false)

	st := loadMacSyncStatus()
	if st.State == "done" || st.Error == "" {
		t.Fatalf("status = %+v, want incomplete with an error", st)
	}
	if st.Posts != 100 {
		t.Fatalf("copied %d posts, want the first page (100)", st.Posts)
	}
}

func TestMacBackfillRejectsAreNotCountedAsCopied(t *testing.T) {
	mac := newFakeMac(t, true, 0)
	f := setupMacFixture(t, mac)
	// Nobody is in the WoT: every mention is rejected (a cached stub), none stored.
	wot.MarkReady(wot.NewCycle(), stubWot{members: map[string]bool{}})

	f.fill.runIfNeeded(context.Background(), false)
	st := loadMacSyncStatus()
	if st.State != "done" || st.Missing != 0 || st.Mentions != 0 {
		t.Fatalf("status = %+v, want done, 0 missing, 0 mentions copied", st)
	}

	// The catch-up loop prunes the reject stubs; a later check re-downloads
	// those rejects and must still not report them as copied.
	f.fill.rejects.prune(nostr.Timestamp(time.Now().Add(time.Hour).Unix()))
	f.fill.runIfNeeded(context.Background(), true)
	if st := loadMacSyncStatus(); st.State != "done" || st.Mentions != 0 || st.Posts != 0 {
		t.Fatalf("re-check status = %+v, want done with nothing copied", st)
	}
}

func TestMacBackfillIncompleteRetriesDaily(t *testing.T) {
	mac := newFakeMac(t, true, 0)
	f := setupMacFixture(t, mac)
	base, _ := macRelayURLs()
	prev := macSyncStatus{MacURL: base, State: "incomplete", Missing: 1, FinishedAt: time.Now().Add(-time.Hour).Unix()}
	saveMacSyncStatus(prev)
	f.fill.runIfNeeded(context.Background(), false)
	if st := loadMacSyncStatus(); st.StartedAt != 0 {
		t.Fatalf("clean incomplete copy from an hour ago re-ran: %+v", st)
	}
	prev.FinishedAt = time.Now().Add(-25 * time.Hour).Unix()
	saveMacSyncStatus(prev)
	f.fill.runIfNeeded(context.Background(), false)
	if st := loadMacSyncStatus(); st.State != "done" {
		t.Fatalf("day-old incomplete copy did not re-run: %+v", st)
	}
}
