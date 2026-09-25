//go:build integration

package main

// Live gate for the Mac relay copy: a real Mac relay, the real macBackfiller,
// fresh local stores. Unit tests prove the logic against an in-process relay;
// this proves it against the relay a phone actually points at.
//
//	MAC_LIVE_URL=wss://mac.example.com MAC_LIVE_OWNER=<hex> \
//	  go test ./ -tags integration -run TestLiveMacBackfill -v -timeout 20m

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"

	"github.com/barrydeen/haven/pkg/wot"
)

func TestLiveMacBackfill(t *testing.T) {
	url, owner := os.Getenv("MAC_LIVE_URL"), os.Getenv("MAC_LIVE_OWNER")
	if url == "" || owner == "" {
		t.Skip("set MAC_LIVE_URL and MAC_LIVE_OWNER")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 18*time.Minute)
	defer cancel()

	setupSyncConfig(owner)
	config.MacRelayURL = url
	fs = afero.NewMemMapFs()
	pool = nostr.NewSimplePool(ctx)
	// Accept every author: this measures the copy, not the WoT.
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})

	outbox, inbox, chat := newTestStore(t), newTestStore(t), newTestStore(t)
	tombs := newTestTombs(t)
	notifier := &batchNotifier{}
	rejects := &tempRejects{}
	fill := &macBackfiller{
		pTags:      []string{owner},
		inboxNeg:   &inboxNegStore{inbox: inbox, chat: chat, tombs: tombs, rejects: rejects, notifier: notifier},
		outboxNeg:  &outboxNegStore{outbox: outbox, tombs: tombs},
		wdbInbox:   inbox,
		wdbChat:    chat,
		wdbOutbox:  outbox,
		notifier:   notifier,
		rejects:    rejects,
		now:        time.Now,
		negEnabled: true,
	}

	start := time.Now()
	fill.runIfNeeded(ctx, false)
	st := loadMacSyncStatus()
	t.Logf("first run in %s: %+v", time.Since(start).Round(time.Second), st)

	count := func(s interface {
		QuerySync(context.Context, nostr.Filter) ([]*nostr.Event, error)
	}) int {
		evs, _ := s.QuerySync(eventstore.SetNegentropy(ctx), nostr.Filter{}) // uncapped
		return len(evs)
	}
	t.Logf("local now holds: outbox %d, inbox %d, chat %d", count(outbox), count(inbox), count(chat))
	if evs, _ := outbox.QuerySync(eventstore.SetNegentropy(ctx), nostr.Filter{Kinds: []int{nostr.KindTextNote}}); len(evs) > 0 {
		first := evs[0]
		for _, ev := range evs {
			if ev.CreatedAt < first.CreatedAt {
				first = ev
			}
		}
		t.Logf("oldest owner note: %s id=%s %q", first.CreatedAt.Time().UTC().Format(time.RFC3339), first.ID, first.Content)
	}

	if st.State != "done" || st.Missing != 0 {
		t.Fatalf("want done with 0 missing, got %+v", st)
	}

	start = time.Now()
	fill.runIfNeeded(ctx, true)
	again := loadMacSyncStatus()
	t.Logf("forced re-check in %s: %+v", time.Since(start).Round(time.Second), again)
	// Posts/mentions made during the first run may legitimately be copied now.
	if again.State != "done" || again.Missing != 0 {
		t.Fatalf("re-check should miss nothing, got %+v", again)
	}
}
